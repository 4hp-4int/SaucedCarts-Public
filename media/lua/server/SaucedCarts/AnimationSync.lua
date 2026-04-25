-- ============================================================================
-- SaucedCarts/AnimationSync.lua
-- ============================================================================
-- PURPOSE: Server-authoritative tracking of cart animation state for MP sync.
--          Handles late-joiner synchronization and cleanup on disconnect.
--
-- CONTEXT: SERVER ONLY
--          Animation state must be tracked server-side to handle late joiners.
--
-- DESIGN NOTES:
--          - Uses onlineID (stable for session) not playerNum (can change)
--          - State is true/nil (not true/false) for clean iteration
--          - Event-driven cleanup: OnPlayerDisconnect + EveryHours fallback
--          - No persistent ModData - animation state is transient
-- ============================================================================

-- Context guard: server-only (including self-hosted)
if isClient() and not isServer() then return end

-- Cache Lua builtins at load time (some get cleared from global scope on dedicated servers)
local pairs = pairs
local ipairs = ipairs

-- Kahlua on dedicated servers clears `next` from global scope
-- Implement our own table empty check using pairs
---@param t table The table to check
---@return boolean True if table has no entries
local function tableIsEmpty(t)
    for _ in pairs(t) do
        return false
    end
    return true
end

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/Durability"
require "SaucedCarts/CartVisuals"
require "SaucedCarts/Upgrades"
SaucedCarts.debug(function() return string.format(
    "AnimationSync: Loading (isClient=%s, isServer=%s)",
    tostring(isClient()), tostring(isServer())
) end)

-- ============================================================================
-- STATE
-- ============================================================================

local AnimationSync = {}

-- Authoritative state: onlineID -> true (has cart) or nil (no cart)
-- Using nil instead of false allows clean iteration with pairs()
local equippedState = {}

-- (Cleanup is event-driven via OnPlayerDisconnect, with EveryHours fallback)

-- ============================================================================
-- NETWORK HANDLERS
-- ============================================================================

--- Handler: Client reports equip/unequip state change
--- Updates authoritative equippedState and broadcasts to all clients
---@param player IsoPlayer The player sending the request
---@param args table { playerOnlineId: number, hasCart: boolean }
SaucedCarts.Network.registerServerHandler("syncCartAnimation", function(player, args)
    -- Validate args
    if not args or args.playerOnlineId == nil or args.hasCart == nil then
        SaucedCarts.debug("AnimationSync: invalid syncCartAnimation args")
        return
    end

    local onlineId = args.playerOnlineId
    local hasCart = args.hasCart

    -- Validate that the reporting player matches the onlineId
    -- (prevents spoofing another player's animation state)
    if player:getOnlineID() ~= onlineId then
        SaucedCarts.debug("AnimationSync: onlineId mismatch, ignoring")
        return
    end

    -- Update authoritative state
    if hasCart then
        equippedState[onlineId] = true
    else
        equippedState[onlineId] = nil  -- Remove entry, don't set false
    end

    -- Broadcast to all clients
    SaucedCarts.Network.broadcast("updateCartAnimation", {
        playerOnlineId = onlineId,
        hasCart = hasCart,
    })

    SaucedCarts.debug(function() return "AnimationSync: player " .. tostring(onlineId) ..
        " hasCart=" .. tostring(hasCart) .. " (broadcasted)" end)
end)

--- Handler: Debug query for animation state (used by debug commands)
--- Sends full equipped state to requesting player for debugging
---@param player IsoPlayer The player requesting debug state
---@param args table|nil (unused)
SaucedCarts.Network.registerServerHandler("requestDebugAnimState", function(player, args)
    local states = {}
    for onlineId, hasCart in pairs(equippedState) do
        local targetPlayer = getPlayerByOnlineID(onlineId)
        table.insert(states, {
            onlineId = onlineId,
            username = targetPlayer and targetPlayer:getUsername() or "unknown",
            hasCart = hasCart,
        })
    end

    SaucedCarts.Network.sendToClient(player, "debugAnimStateResponse", {
        states = states,
        equippedCount = AnimationSync.getEquippedCount(),
    })

    SaucedCarts.debug(function() return "AnimationSync: sent debug state to " .. tostring(player:getUsername()) end)
end)

--- Handler: Late-joiner requests full animation state
--- Sends complete equipped state to newly connected player
---@param player IsoPlayer The player requesting sync (late joiner)
---@param args table|nil (unused)
SaucedCarts.Network.registerServerHandler("requestAnimationSync", function(player, args)
    -- Build list of all players with carts equipped
    local states = {}
    for onlineId, hasCart in pairs(equippedState) do
        if hasCart then
            table.insert(states, { id = onlineId, hasCart = true })
        end
    end

    -- Send to requesting player only
    SaucedCarts.Network.sendToClient(player, "fullAnimationSync", {
        states = states,
    })

    SaucedCarts.debug(function() return "AnimationSync: sent full state to " ..
        tostring(player:getUsername()) .. " (" .. #states .. " equipped players)" end)
end)

-- ============================================================================
-- INSTANT DROP (SERVER-AUTHORITATIVE)
-- ============================================================================
-- Client requests instant drop when aiming while holding cart.
-- Server performs all inventory/world operations to prevent ghost carts.

--- Handler: Client requests instant cart drop (triggered by aiming)
--- Server-authoritative to prevent ghost carts and race conditions.
--- Applies durability damage, handles cart breaking, creates world item.
---@param player IsoPlayer The player requesting the drop
---@param args table { cartId: number }
SaucedCarts.Network.registerServerHandler("requestInstantDrop", function(player, args)
    -- Validate args
    if not args or not args.cartId then
        SaucedCarts.debug("AnimationSync: invalid requestInstantDrop args")
        return
    end

    -- Note: previously we cleared the server-side action queue here. That
    -- caused "ISTimedActionQueue:tick: bugged action" crashes because the
    -- force-drop-triggering action (ISGrabCorpseAction etc.) is in the
    -- queue mid-tick — clearing it leaves the tick holding a null action.
    -- Cart-dependent actions self-invalidate via :isValid() once the cart
    -- enters the world, so no explicit clear is needed.

    -- Find cart in player inventory by ID
    local cart = player:getInventory():getItemById(args.cartId)
    if not cart or not SaucedCarts.isCart(cart) then
        SaucedCarts.debug(function() return "AnimationSync: cart not found for instant drop (ID: " .. tostring(args.cartId) .. ")" end)
        return
    end

    -- CRITICAL: Race condition guards against vanilla forceDropHeavyItems()
    -- Cart has heavyitem tag, so many vanilla actions call forceDropHeavyItems():
    -- ISEquipWeaponAction, ISEnterVehicle, ISEquipHeavyItem, ISGrabCorpseAction, etc.
    --
    -- Guard 1: Check if cart is still in player's hands
    local primary = player:getPrimaryHandItem()
    if primary ~= cart then
        SaucedCarts.debug("AnimationSync: cart not in hands, skipping drop (vanilla may have cleared hands)")
        return
    end

    -- Guard 2: Check if cart was already dropped to world by vanilla
    -- This catches the interleaved race where both handlers pass initial checks
    if cart:getWorldItem() then
        SaucedCarts.debug("AnimationSync: cart already on ground, skipping drop (vanilla already dropped)")
        return
    end

    local square = player:getCurrentSquare()
    if not square then
        SaucedCarts.debug("AnimationSync: no square for instant drop")
        return
    end

    local inventory = player:getInventory()

    -- Project damage to decide broke vs survived (don't apply yet)
    local modData = cart:getModData()
    -- Use client-provided distancePushed (exact), fall back to server ModData (old clients)
    local distancePushed = args.distancePushed
    if distancePushed == nil then
        distancePushed = modData.SaucedCarts_distancePushed or 0
    end
    -- Anti-cheat clamp
    local maxDistance = SaucedCarts.Config.DISTANCE_SYNC_MAX or 10000
    if type(distancePushed) ~= "number" or distancePushed < 0 then distancePushed = 0 end
    if distancePushed > maxDistance then distancePushed = maxDistance end
    -- Write to ModData so applyAccumulatedDamage() reads it
    modData.SaucedCarts_distancePushed = distancePushed
    local projectedDamage = math.floor(distancePushed / SaucedCarts.Durability.getTilesPerDamage())
    local projectedCondition = math.max(0, cart:getCondition() - projectedDamage)

    if projectedCondition <= 0 then
        -- Apply damage now (cart is being destroyed)
        SaucedCarts.Durability.applyAccumulatedDamage(cart)
        -- Cart broke - drop contents and destroy
        SaucedCarts.Durability.dropContentsAndDestroy(cart, player, square)

        -- Remove from hands and inventory
        player:setPrimaryHandItem(nil)
        player:setSecondaryHandItem(nil)
        inventory:Remove(cart)
        sendRemoveItemFromContainer(inventory, cart)
        sendEquip(player)

        -- Update animation state (player no longer has cart)
        local onlineId = player:getOnlineID()
        if onlineId then
            equippedState[onlineId] = nil
            SaucedCarts.Network.broadcast("updateCartAnimation", {
                playerOnlineId = onlineId,
                hasCart = false,
            })
        end

        -- Notify client to show notification
        SaucedCarts.Network.sendToClient(player, "cartBroke", {})

        -- Fire broke event (server-side for MP consistency)
        if SaucedCarts._fireEvent then
            SaucedCarts._fireEvent(SaucedCarts.Events.onCartBroke, player, cart, square)
        end

        SaucedCarts.debug("AnimationSync: instant drop - cart broke")
        return
    end

    -- Update visual state before drop
    SaucedCarts.updateCartVisual(cart, player)

    -- Remove from hands
    player:setPrimaryHandItem(nil)
    player:setSecondaryHandItem(nil)

    -- Remove from inventory
    inventory:Remove(cart)
    sendRemoveItemFromContainer(inventory, cart)

    -- Sync equip state (works on server)
    sendEquip(player)

    -- Update animation state (player no longer has cart)
    local onlineId = player:getOnlineID()
    if onlineId then
        equippedState[onlineId] = nil
        SaucedCarts.Network.broadcast("updateCartAnimation", {
            playerOnlineId = onlineId,
            hasCart = false,
        })
    end

    -- Add to world - server creates, syncs to all clients
    local dropX = player:getX() - math.floor(player:getX())
    local dropY = player:getY() - math.floor(player:getY())
    local worldItem = square:AddWorldInventoryItem(cart, dropX, dropY, 0, true)

    -- Apply damage now that cart is safely on the ground
    local newCondition = SaucedCarts.Durability.applyAccumulatedDamage(cart)

    -- Fire drop event (server-side for MP consistency)
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onCartDrop, player, cart, square)
    end

    -- Notify client of low condition if applicable (25% threshold)
    local conditionMax = cart:getConditionMax()
    if conditionMax > 0 and newCondition <= math.floor(conditionMax * 0.25) then
        SaucedCarts.Network.sendToClient(player, "cartDamaged", {})
    end

    SaucedCarts.debug(function() return "AnimationSync: instant drop completed (condition: " .. newCondition .. ")" end)
end)

-- ============================================================================
-- PERIODIC DISTANCE SYNC (CLIENT -> SERVER)
-- ============================================================================
-- Client periodically sends accumulated distancePushed so server ModData
-- stays current for right-click drop and unequip durability checks.

--- Handler: Client sends accumulated distance for server-side durability
---@param player IsoPlayer The player sending the sync
---@param args table { cartId: number, distancePushed: number }
SaucedCarts.Network.registerServerHandler("syncCartDistance", function(player, args)
    if not args or not args.cartId or not args.distancePushed then return end
    local distancePushed = args.distancePushed
    if type(distancePushed) ~= "number" then return end
    local maxDistance = SaucedCarts.Config.DISTANCE_SYNC_MAX or 10000
    if distancePushed < 0 then distancePushed = 0 end
    if distancePushed > maxDistance then distancePushed = maxDistance end
    local cart = player:getInventory():getItemById(args.cartId)
    if not cart or not SaucedCarts.isCart(cart) then return end
    cart:getModData().SaucedCarts_distancePushed = distancePushed
end)

-- ============================================================================
-- CLEANUP: Detect disconnected players
-- ============================================================================

--- Event handler: Clean up animation state when player disconnects
--- Removes player from equippedState and broadcasts update to remaining clients.
--- Zero CPU overhead when idle (event-driven, not polled).
---@param player IsoPlayer The disconnecting player
local function onPlayerDisconnect(player)
    if not player then return end

    local onlineId = player:getOnlineID()
    if not equippedState[onlineId] then return end

    -- Clear state and broadcast
    equippedState[onlineId] = nil
    SaucedCarts.Network.broadcast("updateCartAnimation", {
        playerOnlineId = onlineId,
        hasCart = false,
    })

    SaucedCarts.debug(function() return "AnimationSync: cleaned up disconnected player " .. tostring(onlineId) end)
end

-- MP-only events (don't exist in singleplayer)
if Events.OnPlayerDisconnect then
    Events.OnPlayerDisconnect.Add(onPlayerDisconnect)
end

--- Hourly cleanup: Defensive sweep for stale animation state
--- Catches edge cases where OnPlayerDisconnect may have missed cleanup.
--- Only performs work when equippedState is non-empty (early exit otherwise).
local function onEveryHour()
    if tableIsEmpty(equippedState) then return end

    -- Collect stale entries first (don't modify during iteration)
    local toRemove = {}
    for onlineId in pairs(equippedState) do
        if not getPlayerByOnlineID(onlineId) then
            table.insert(toRemove, onlineId)
        end
    end

    -- Remove collected entries
    for _, onlineId in ipairs(toRemove) do
        equippedState[onlineId] = nil
    end

    if #toRemove > 0 then
        SaucedCarts.debug(function() return "AnimationSync: hourly cleanup removed " .. #toRemove .. " stale entries" end)
    end
end

if Events.EveryHours then
    Events.EveryHours.Add(onEveryHour)
end

-- ============================================================================
-- DEBUG API
-- ============================================================================

--- Get current animation sync state (for debugging)
---@return table State table mapping onlineID to equipped status
function AnimationSync.getState()
    local copy = {}
    for k, v in pairs(equippedState) do
        copy[k] = v
    end
    return copy
end

--- Get count of players with carts equipped
---@return number
function AnimationSync.getEquippedCount()
    local count = 0
    for _ in pairs(equippedState) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- EVENT-DRIVEN ANIMATION SYNC (Server-side)
-- ============================================================================
-- In MP, timed actions run on server. Events fire here, so we need server-side
-- listeners to update equippedState and broadcast animation changes.

-- Cart equipped → update state and broadcast
if SaucedCarts.Events and SaucedCarts.Events.onCartEquip then
    SaucedCarts.Events.onCartEquip:Add(function(player, cart, source)
        if not player then return end
        local onlineId = player:getOnlineID()
        if not onlineId then return end  -- SP has no onlineId

        -- Update authoritative state
        equippedState[onlineId] = true

        -- Broadcast to all clients
        SaucedCarts.Network.broadcast("updateCartAnimation", {
            playerOnlineId = onlineId,
            hasCart = true,
        })

        SaucedCarts.debug(function() return "AnimationSync: onCartEquip event → broadcast hasCart=true for " .. onlineId end)
    end)
    SaucedCarts.debug("AnimationSync: Registered onCartEquip event listener")
else
    SaucedCarts.error("AnimationSync: SaucedCarts.Events.onCartEquip not available!")
end

-- Cart dropped → update state and broadcast
if SaucedCarts.Events and SaucedCarts.Events.onCartDrop then
    SaucedCarts.Events.onCartDrop:Add(function(player, cart, square)
        if not player then return end
        local onlineId = player:getOnlineID()
        if not onlineId then return end

        -- Update authoritative state
        equippedState[onlineId] = nil

        -- Broadcast to all clients
        SaucedCarts.Network.broadcast("updateCartAnimation", {
            playerOnlineId = onlineId,
            hasCart = false,
        })

        SaucedCarts.debug(function() return "AnimationSync: onCartDrop event → broadcast hasCart=false for " .. onlineId end)
    end)
    SaucedCarts.debug("AnimationSync: Registered onCartDrop event listener")
end

-- Cart broke → update state and broadcast
if SaucedCarts.Events and SaucedCarts.Events.onCartBroke then
    SaucedCarts.Events.onCartBroke:Add(function(player, cart, square)
        if not player then return end
        local onlineId = player:getOnlineID()
        if not onlineId then return end

        -- Update authoritative state
        equippedState[onlineId] = nil

        -- Broadcast to all clients
        SaucedCarts.Network.broadcast("updateCartAnimation", {
            playerOnlineId = onlineId,
            hasCart = false,
        })

        SaucedCarts.debug(function() return "AnimationSync: onCartBroke event → broadcast hasCart=false for " .. onlineId end)
    end)
    SaucedCarts.debug("AnimationSync: Registered onCartBroke event listener")
end

-- Export for debug commands
SaucedCarts.AnimationSync = AnimationSync

SaucedCarts.debug("AnimationSync loaded")

return AnimationSync
