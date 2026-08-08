-- ============================================================================
-- SaucedCarts/CartStateHandler.lua
-- ============================================================================
-- PURPOSE: Orchestrates cart equip state, animations, restrictions, and visuals.
--          This is the main coordinator that owns player-keyed state and
--          delegates specialized functionality to extracted modules.
--
-- CONTEXT: CLIENT ONLY
--          Animation variables and movement restrictions are client-side.
--
-- MODULES:
--   CartState/FlashlightHook.lua       - F-key flashlight toggle
--   CartState/HighlightDisable.lua     - World item highlight suppression
--   CartState/HolderRegistry.lua       - Event-fed cart-holder registry (authoritative for the early exit)
--   CartState/InstantDrop.lua          - SP/MP instant drop logic
--   CartState/VisualUpdateQueue.lua    - Pending cart visual updates
--   CartState/AnimationSync/Throttle.lua       - Animation sync throttling
--   CartState/AnimationSync/RemotePlayer.lua   - Remote player animation maintenance
--   CartState/AnimationSync/LateJoiner.lua     - Late-joiner sync request/response
--   CartState/AnimationSync/Notifications.lua  - cartBroke/cartDamaged handlers
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/CartVisuals"
require "SaucedCarts/Notifications"
require "SaucedCarts/Durability"
require "SaucedCarts/Upgrades"
require "SaucedCarts/UpgradeSync"
-- Load extracted modules (they self-initialize on require)
local FlashlightHook = require "SaucedCarts/CartState/FlashlightHook"
local HighlightDisable = require "SaucedCarts/CartState/HighlightDisable"
local HolderRegistry = require "SaucedCarts/CartState/HolderRegistry"
local InstantDrop = require "SaucedCarts/CartState/InstantDrop"
local VisualUpdateQueue = require "SaucedCarts/CartState/VisualUpdateQueue"
local Throttle = require "SaucedCarts/CartState/AnimationSync/Throttle"
local RemotePlayer = require "SaucedCarts/CartState/AnimationSync/RemotePlayer"
local LateJoiner = require "SaucedCarts/CartState/AnimationSync/LateJoiner"
local Notifications = require "SaucedCarts/CartState/AnimationSync/Notifications"

-- Load hotkey module (self-initializes on OnGameStart)
require "SaucedCarts/Hotkeys"

---@class SaucedCartsStateHandler
local CartStateHandler = {}

-- =============================================================================
-- PLAYER STATE TRACKING
-- =============================================================================
-- Core state owned by the orchestrator (player-keyed tables)

-- Track cart state per player (by onlineID in MP, playerNum in SP)
-- Stores whether player had a cart equipped last frame
local playerCartState = {}

-- Frame counter for throttled self-correction (per player)
local playerFrameCounter = {}
local SELF_CORRECTION_INTERVAL = SaucedCarts.Config.SELF_CORRECTION_INTERVAL
local MAX_DISTANCE_PER_FRAME = SaucedCarts.Config.MAX_DISTANCE_PER_FRAME

-- Frame counter for upgrade state recovery (per player)
local upgradeRecoveryCounter = {}
local UPGRADE_RECOVERY_INTERVAL = SaucedCarts.Config.UPGRADE_RECOVERY_INTERVAL

-- Distance tracking for durability system (per player)
-- Stores last known position {x, y} while holding cart
local playerLastPos = {}

-- Distance sync tracking for MP (per player)
-- Stores last distancePushed value that was synced to server
local playerLastSyncedDistance = {}
local DISTANCE_SYNC_THRESHOLD = SaucedCarts.Config.DISTANCE_SYNC_THRESHOLD or 10

-- Timed-action tracking for pose restore (per player). True while the player
-- had a timed action running last frame; the action-finished EDGE triggers the
-- full pose restore (see SaucedCarts.maintainCartPose).
local playerWasInAction = {}

-- One-shot hand seed (per player). Hands are authoritative the FIRST frame we
-- see a player: join/load writes the hand field directly (IsoPlayer.java:1264,
-- no OnEquipPrimary), and in MP the hands aren't populated yet when
-- OnCreatePlayer fires — shadow-phase divergence #1 was exactly this path.
local playerSeeded = {}

-- =============================================================================
-- PLAYER KEY HELPER
-- =============================================================================
-- Use onlineID in MP (stable for session), fallback to playerNum in SP.
-- onlineID is stable for the session; playerNum can change if another player disconnects.

---@param player IsoPlayer
---@return number key The player key (onlineID or playerNum)
local function getPlayerKey(player)
    local onlineId = player:getOnlineID()
    if onlineId then return onlineId end
    return player:getPlayerNum()
end

--- Is the player currently running a timed action (anything in their queue)?
--- Used to defer the equipped-model refresh until an action has finished, so
--- we don't fight an action's own hand-model overrides mid-run.
---@param player IsoPlayer
---@return boolean
local function hasActiveTimedAction(player)
    local q = ISTimedActionQueue.getTimedActionQueue(player)
    return q ~= nil and q.queue ~= nil and #q.queue > 0
end

-- =============================================================================
-- MAIN PLAYER UPDATE HANDLER
-- =============================================================================
-- Called every frame to manage cart state, animations, and restrictions.

---@param player IsoPlayer
local function onPlayerUpdate(player)
    -- Early exit for invalid/dead players
    if not player or player:isDead() then return end
    -- Additional safety: verify player has a valid square (catches edge cases)
    if not player:getCurrentSquare() then return end

    local playerKey = getPlayerKey(player)

    -- One-shot seed: hands are authoritative the first frame (see
    -- playerSeeded above for why events can't cover join/load).
    if not playerSeeded[playerKey] then
        playerSeeded[playerKey] = true
        local seedPrimary = player:getPrimaryHandItem()
        if seedPrimary and SaucedCarts.isCart(seedPrimary) then
            HolderRegistry.registerKey(playerKey)
        end
    end

    -- Registry-driven early exit (phase 2). Events (OnEquipPrimary + our own)
    -- maintain the registry, the seed covers join, and the registry's slow
    -- reconciler audits for missed equips. Non-holders exit on two table
    -- lookups — no per-frame hand poll.
    local isHolder = HolderRegistry.isHolderKey(playerKey)
    local hadCart = playerCartState[playerKey]
    if not isHolder and not hadCart then
        return
    end

    -- Skip if pending drop (waiting for server to process)
    if InstantDrop.isPending(player) then
        return
    end

    -- For holders the hand stays authoritative, checked every frame: we must
    -- NEVER keep restrictions/pose on a cartless player, holders are few, and
    -- the check is cheap. A disagreement here is a missed unequip event —
    -- count it on the registry's divergence meter and resync; the normal
    -- hasCart/hadCart transition below then actuates the unequip.
    local primary = player:getPrimaryHandItem()
    local hasCart = (primary and SaucedCarts.isCart(primary)) or false
    if isHolder ~= hasCart then
        HolderRegistry.reportObserved(playerKey, hasCart)
    end

    -- State transition: just equipped a cart
    if hasCart and not hadCart then
        -- Set the cart-push pose animation variables (canonical helper)
        SaucedCarts.applyCartPose(player)

        -- Apply restrictions. The E key (context key) stays ENABLED so doors
        -- still open — Restrictions/ContextActionRestrictions.lua gates every
        -- non-door contextual action at the Lua dispatch layer instead.
        -- setIgnoreAutoVault also suppresses the Java-direct ClimbOverWall
        -- contextual action (doContextClimbOverWall bails on the flag), so
        -- no climb path survives with the context key live.
        player:setIgnoreAutoVault(true)    -- Block sprint-vault + E-key wall climb

        playerCartState[playerKey] = true

        -- MP: announce the new hand state to the server so observers get the
        -- push pose. Driven from THIS transition (hands are the truth), not
        -- from SaucedCarts.Events.onCartEquip alone — that event fires only
        -- from our own ISCartEquipAction / ISCartPickupAction. The cart script
        -- sets RequiresEquippedBothHands, so vanilla also offers "Equip in
        -- Both Hands" (ISInventoryPaneContextMenu.lua:428); equipping that way
        -- — or via hotbar / keybind / another mod — produced the same hand
        -- state but fired no event, so the server never broadcast
        -- updateCartAnimation and observers never added the player to
        -- RemotePlayer's re-application loop. The engine's Weapon=UNARMED
        -- overwrite then stuck and the cart rendered as a held weapon clipping
        -- the ground. Throttle.send is level-triggered, so for our own flow
        -- (event listener already fired) this is a no-op.
        Throttle.send(player, true)

        SaucedCarts.debug("Cart equipped - set animations and restrictions")

    -- State transition: just unequipped a cart
    elseif not hasCart and hadCart then
        -- Clear the cart-push pose animation variables (canonical helper)
        SaucedCarts.clearCartPose(player)

        -- Remove restrictions. setIgnoreContextKey(false) is a defensive
        -- clear only: current code never sets it true (E stays enabled while
        -- pushing; see ContextActionRestrictions), but pre-v2.1.13 sessions
        -- did — healing here costs nothing and covers mixed states.
        player:setIgnoreContextKey(false)
        player:setIgnoreAutoVault(false)    -- Re-enable sprint-vault

        -- Clear distance tracking (position no longer relevant)
        playerLastPos[playerKey] = nil
        playerLastSyncedDistance[playerKey] = nil
        playerWasInAction[playerKey] = nil

        playerCartState[playerKey] = nil  -- Use nil for consistency (both nil and false are falsy)

        -- MP: announce the cleared hand state (see the equip branch above for
        -- why this is transition-driven and not event-driven). Covers every
        -- unequip path our onCartDrop/onCartBroke events don't reach.
        Throttle.send(player, false)

        SaucedCarts.debug("Cart unequipped - cleared animations and restrictions")
    end

    -- Continuous enforcement while holding cart
    if hasCart then
        -- Prevent sneaking
        if player:isSneaking() then
            player:setSneaking(false)
        end

        -- Drop cart instantly when player tries to aim (for combat reactivity)
        if player:isAiming() then
            InstantDrop.handle(player, primary)
            return  -- Exit early, cart state will update next frame
        end

        -- Pose maintenance. Vanilla timed actions (smoking, barricading,
        -- eating, transferring, …) drive their own animation and hand-model
        -- overrides while a container stays equipped, and don't restore ours
        -- when they end — leaving the cart hanging at the player's side.
        -- maintainCartPose (Core.lua) leaves a running action alone, then does
        -- a full restore (pose vars + equipped-model rebind) on the frame the
        -- action finishes; outside actions it heals variable drift from any
        -- other clobber source.
        local inAction, restored = SaucedCarts.maintainCartPose(
            player, playerWasInAction[playerKey], hasActiveTimedAction(player))
        playerWasInAction[playerKey] = inAction or nil
        if restored then
            SaucedCarts.debug("Cart pose restored (action finished / drift)")
        end

        -- Distance tracking for durability system
        -- Accumulates in ModData, applied server-side on next pickup
        local x, y = player:getX(), player:getY()
        local lastPos = playerLastPos[playerKey]

        if not lastPos then
            -- Initialize tracking on first frame with cart
            playerLastPos[playerKey] = {x = x, y = y}
        else
            -- Calculate distance moved (manhattan - no sqrt, performant)
            local dx = x - lastPos.x
            local dy = y - lastPos.y
            local distance = math.abs(dx) + math.abs(dy)

            -- Cap per-frame distance to reject teleport/chunk-load spikes
            if distance > MAX_DISTANCE_PER_FRAME then
                distance = 0
            end

            -- Only accumulate if actually moved (threshold filters noise)
            if distance > 0.01 then
                local modData = primary:getModData()
                local accum = modData.SaucedCarts_distancePushed or 0
                modData.SaucedCarts_distancePushed = accum + distance

                -- Fire movement event (throttled to ~1 tile)
                local moveEventCounter = modData.SaucedCarts_moveEventCounter or 0
                moveEventCounter = moveEventCounter + distance
                if moveEventCounter >= 1.0 then
                    if SaucedCarts._fireEvent then
                        SaucedCarts._fireEvent(SaucedCarts.Events.onCartMove, player, primary, moveEventCounter)
                    end
                    modData.SaucedCarts_moveEventCounter = 0
                else
                    modData.SaucedCarts_moveEventCounter = moveEventCounter
                end

                -- Periodic distance sync to server (MP only)
                if isClient() then
                    local currentDistance = modData.SaucedCarts_distancePushed or 0
                    local lastSynced = playerLastSyncedDistance[playerKey] or 0
                    if currentDistance - lastSynced >= DISTANCE_SYNC_THRESHOLD then
                        SaucedCarts.Network.sendToServer(player, "syncCartDistance", {
                            cartId = primary:getID(),
                            distancePushed = currentDistance,
                        })
                        playerLastSyncedDistance[playerKey] = currentDistance
                    end
                end
            end

            -- Update last position (reuse existing table to avoid allocation)
            lastPos.x = x
            lastPos.y = y
        end

        -- Throttled self-correction for visual state drift (defensive)
        playerFrameCounter[playerKey] = (playerFrameCounter[playerKey] or 0) + 1

        if playerFrameCounter[playerKey] >= SELF_CORRECTION_INTERVAL then
            playerFrameCounter[playerKey] = 0

            -- Check if debug mode has paused self-correction
            if SaucedCarts._debugPauseSelfCorrection then
                if getTimestampMs() >= SaucedCarts._debugPauseExpiry then
                    -- Pause expired, re-enable
                    SaucedCarts._debugPauseSelfCorrection = false
                    SaucedCarts.debug("Self-correction resumed after debug pause")
                else
                    -- Still paused, skip correction
                    return
                end
            end

            -- Wrapped in pcall - never breaks player update loop
            pcall(function()
                local expected = SaucedCarts.calculateFillState(primary, player)
                local actual = primary:getModData().SaucedCarts_fillState or "empty"

                if expected ~= actual then
                    SaucedCarts.updateCartVisual(primary, player)
                    SaucedCarts.debug(function() return "Self-corrected visual drift: " .. actual .. " -> " .. expected end)
                end
            end)
        end

        -- Upgrade state recovery (flashlight light source sync after area transitions)
        -- Throttled to reduce per-frame overhead - only needs to run periodically
        upgradeRecoveryCounter[playerKey] = (upgradeRecoveryCounter[playerKey] or 0) + 1
        if upgradeRecoveryCounter[playerKey] >= UPGRADE_RECOVERY_INTERVAL then
            upgradeRecoveryCounter[playerKey] = 0
            if SaucedCarts.Upgrades and SaucedCarts.Upgrades.updatePlayer then
                SaucedCarts.Upgrades.updatePlayer(player)
            end
        end
    end
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- =============================================================================
-- MP VISUAL SYNC RECEIVER
-- =============================================================================
-- Receives visual update broadcasts from server for ground carts.
-- This allows all clients to see when another player changes a cart's contents.

SaucedCarts.Network.registerClientHandler("updateGroundCartVisual", function(args)
    -- Validate args
    if not args or not args.squareX or not args.cartId or not args.modelName then
        SaucedCarts.debug("CartStateHandler: invalid updateGroundCartVisual args")
        return
    end

    -- Find the cart using standard helper
    local cart, worldObj = SaucedCarts.Network.findGroundCart(
        args.squareX, args.squareY, args.squareZ, args.cartId)

    if not cart then
        -- .log: field-visible -- triaging "ground mesh didn't update" needs
        -- receive-side evidence in normal (non-debug) client logs.
        SaucedCarts.log("GroundCartVisual: cart " .. tostring(args.cartId) .. " NOT FOUND at "
            .. tostring(args.squareX) .. "," .. tostring(args.squareY) .. "," .. tostring(args.squareZ))
        return
    end

    -- Update local model
    cart:setStaticModel(args.modelName)
    cart:setWorldStaticModel(args.modelName)
    SaucedCarts.log("GroundCartVisual: applied " .. tostring(args.modelName)
        .. " to cart " .. tostring(args.cartId) .. " (worldObj=" .. tostring(worldObj ~= nil) .. ")")

    -- Update ModData to match
    local modData = cart:getModData()
    if args.fillState then
        modData.SaucedCarts_fillState = args.fillState
    end

    -- Invalidate atlas cache to force 3D model refresh
    -- Toggle worldScale between two imperceptibly different values (1.0 and 1.0001)
    -- Use ModData tracking since direct field access may not work from Lua
    if worldObj then
        -- Monotonic: see SaucedCarts.nudgeCartWorldScale (paired repaints
        -- with a two-value toggle net zero and leave the atlas cache valid).
        if SaucedCarts.nudgeCartWorldScale then
            SaucedCarts.nudgeCartWorldScale(cart)
        end

        -- Call updateSprite to refresh the 2D texture/icon
        worldObj:updateSprite()

        -- Invalidate render chunk - flag 256 = DIRTY_OBJECT_MODIFY
        local square = worldObj:getSquare()
        if square then
            pcall(function() square:invalidateRenderChunkLevel(256) end)
        end
    end

    SaucedCarts.debug(function() return "CartStateHandler: received visual update for cart " ..
        args.cartId .. " (model: " .. args.modelName .. ")" end)
end)

-- =============================================================================
-- CLEANUP ON PLAYER DEATH
-- =============================================================================
-- Clear tracking state for dead players to prevent memory leaks.

local function onPlayerDeath(player)
    if not player then return end
    local playerKey = getPlayerKey(player)

    -- Clear orchestrator state
    playerCartState[playerKey] = nil
    playerLastPos[playerKey] = nil
    playerLastSyncedDistance[playerKey] = nil
    playerFrameCounter[playerKey] = nil
    upgradeRecoveryCounter[playerKey] = nil
    playerWasInAction[playerKey] = nil

    -- Cleanup extracted modules
    Throttle.cleanup(playerKey)
    InstantDrop.cleanup(player)
    HolderRegistry.unregisterKey(playerKey)

    SaucedCarts.debug("CartStateHandler: cleaned up tracking for dead player")
end

Events.OnPlayerDeath.Add(onPlayerDeath)

-- =============================================================================
-- CLEANUP ON GAME END
-- =============================================================================
-- Clear all state tables when exiting game to prevent stale state on save switch.

local function onGameEnd()
    -- Clear orchestrator state
    playerCartState = {}
    playerFrameCounter = {}
    upgradeRecoveryCounter = {}
    playerLastPos = {}
    playerLastSyncedDistance = {}
    playerWasInAction = {}
    playerSeeded = {}

    -- Reset extracted modules
    Throttle.reset()
    InstantDrop.reset()
    VisualUpdateQueue.reset()

    SaucedCarts.debug("CartStateHandler: cleared all state on game end")
end

if Events and Events.OnGameEnd then
    Events.OnGameEnd.Add(onGameEnd)
end

-- =============================================================================
-- EVENT-DRIVEN ANIMATION SYNC
-- =============================================================================
-- Centralized sync: events automatically trigger network sync for animations.
-- This ensures sync happens regardless of how equip/drop occurred.

-- Cart equipped → sync animation state to server
if SaucedCarts.Events and SaucedCarts.Events.onCartEquip then
    SaucedCarts.Events.onCartEquip:Add(function(player, cart, source)
        if not isClient() then return end
        if not player then return end
        Throttle.send(player, true)
        SaucedCarts.debug(function() return "EventSync: onCartEquip → animation sync (hasCart=true)" end)
    end)
end

-- Cart dropped → sync animation state to server
if SaucedCarts.Events and SaucedCarts.Events.onCartDrop then
    SaucedCarts.Events.onCartDrop:Add(function(player, cart, square)
        if not isClient() then return end
        if not player then return end
        Throttle.send(player, false)
        SaucedCarts.debug(function() return "EventSync: onCartDrop → animation sync (hasCart=false)" end)
    end)
end

-- Cart broke → sync animation state to server (no longer equipped)
if SaucedCarts.Events and SaucedCarts.Events.onCartBroke then
    SaucedCarts.Events.onCartBroke:Add(function(player, cart, square)
        if not isClient() then return end
        if not player then return end
        Throttle.send(player, false)
        SaucedCarts.debug(function() return "EventSync: onCartBroke → animation sync (hasCart=false)" end)
    end)
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

--- Get cart from container (exposed from VisualUpdateQueue)
---@param container ItemContainer
---@param player IsoPlayer|nil
---@return InventoryItem|nil
function CartStateHandler.getCartFromContainer(container, player)
    return VisualUpdateQueue.getCartFromContainer(container, player)
end

--- Queue a cart for visual update
---@param cart InventoryItem
---@param player IsoPlayer
function CartStateHandler.queueCartVisualUpdate(cart, player)
    VisualUpdateQueue.queueUpdate(cart, player)
end

SaucedCarts.debug("CartStateHandler loaded (orchestrator)")

return CartStateHandler
