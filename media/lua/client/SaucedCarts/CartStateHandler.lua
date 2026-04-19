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

    -- Skip if pending drop (waiting for server to process)
    local isPending = InstantDrop.isPending(player)
    if isPending then
        return
    end

    local primary = player:getPrimaryHandItem()
    local hasCart = primary and SaucedCarts.isCart(primary)
    local hadCart = playerCartState[playerKey]

    -- Early exit for players who have never interacted with a cart
    -- Reduces ~90% of calls from ~8 ops to ~6 ops
    if not hasCart and not hadCart then
        return
    end

    -- State transition: just equipped a cart
    if hasCart and not hadCart then
        -- Set animation variables
        player:setVariable("Weapon", "cart")               -- Body animations (idle, walk, run, sprint)
        player:setVariable("RightHandMask", "holdingcartright")  -- Right arm masking
        player:setVariable("LeftHandMask", "holdingcartleft")    -- Left arm masking

        -- Apply restrictions
        player:setIgnoreContextKey(true)   -- Block E key / context menu climbing
        player:setIgnoreAutoVault(true)    -- Block sprint-vault through fences

        playerCartState[playerKey] = true
        SaucedCarts.debug("Cart equipped - set animations and restrictions")
        -- Note: MP animation sync handled by onCartEquip event listener

    -- State transition: just unequipped a cart
    elseif not hasCart and hadCart then
        -- Clear animation variables
        player:setVariable("Weapon", "")                   -- Clear body animations
        player:setVariable("RightHandMask", "")            -- Clear right arm masking
        player:setVariable("LeftHandMask", "")             -- Clear left arm masking

        -- Remove restrictions
        player:setIgnoreContextKey(false)   -- Re-enable E key / context menu climbing
        player:setIgnoreAutoVault(false)    -- Re-enable sprint-vault

        -- Clear distance tracking (position no longer relevant)
        playerLastPos[playerKey] = nil
        playerLastSyncedDistance[playerKey] = nil

        playerCartState[playerKey] = nil  -- Use nil for consistency (both nil and false are falsy)
        SaucedCarts.debug("Cart unequipped - cleared animations and restrictions")
        -- Note: MP animation sync handled by onCartDrop/onCartBroke event listeners
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
        SaucedCarts.debug(function() return "CartStateHandler: cart " .. args.cartId .. " not found for visual update" end)
        return
    end

    -- Update local model
    cart:setStaticModel(args.modelName)
    cart:setWorldStaticModel(args.modelName)

    -- Update ModData to match
    local modData = cart:getModData()
    if args.fillState then
        modData.SaucedCarts_fillState = args.fillState
    end

    -- Invalidate atlas cache to force 3D model refresh
    -- Toggle worldScale between two imperceptibly different values (1.0 and 1.0001)
    -- Use ModData tracking since direct field access may not work from Lua
    if worldObj then
        local lastScale = modData.SaucedCarts_lastWorldScale or 1.0
        local newScale = (lastScale < 1.0001) and 1.0001 or 1.0
        cart:setWorldScale(newScale)
        modData.SaucedCarts_lastWorldScale = newScale

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

    -- Cleanup extracted modules
    Throttle.cleanup(playerKey)
    InstantDrop.cleanup(player)

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
