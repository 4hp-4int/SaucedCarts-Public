-- ============================================================================
-- SaucedCarts/CartState/InstantDrop.lua
-- ============================================================================
-- PURPOSE: Handle instant cart drop for combat/aim reactivity.
--          When player aims while holding cart, drop it immediately so they
--          can defend themselves.
--
-- CONTEXT: CLIENT ONLY
--          In MP: sends request to server for authoritative execution
--          In SP: drops directly via local function
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Durability"
require "SaucedCarts/Network"

---@class SaucedCartsInstantDrop
local InstantDrop = {}

-- =============================================================================
-- STATE
-- =============================================================================

-- Track pending drops to prevent animation re-apply during server processing
local pendingDropTime = {}  -- playerKey -> timestamp when drop was requested
local PENDING_DROP_TIMEOUT_MS = 1000  -- Ignore animation updates for 1 second after drop request

-- =============================================================================
-- UTILITIES
-- =============================================================================

--- Get a stable key for tracking player state
--- In MP: uses onlineID (stable for session)
--- In SP: uses playerNum
---@param player IsoPlayer
---@return number key
local function getPlayerKey(player)
    local onlineId = player:getOnlineID()
    if onlineId then return onlineId end
    return player:getPlayerNum()
end

-- =============================================================================
-- SINGLEPLAYER DROP
-- =============================================================================

--- Singleplayer instant drop (direct execution)
--- Only called in SP - MP uses server handler via handleInstantDrop
---@param player IsoPlayer
---@param cartItem InventoryItem
---@return boolean success
function InstantDrop.dropCartSP(player, cartItem)
    local square = player:getCurrentSquare()
    if not square then
        return false
    end

    -- CRITICAL: Race condition guards against vanilla forceDropHeavyItems()
    -- Cart has heavyitem tag, so many vanilla actions call forceDropHeavyItems():
    -- ISEquipWeaponAction, ISEnterVehicle, ISEquipHeavyItem, ISGrabCorpseAction, etc.
    --
    -- Guard 1: Check if cart is still in player's hands
    local primary = player:getPrimaryHandItem()
    if primary ~= cartItem then
        SaucedCarts.debug("InstantDrop: cart not in hands, skipping")
        return false
    end

    -- Guard 2: Check if cart was already dropped to world by vanilla
    if cartItem:getWorldItem() then
        SaucedCarts.debug("InstantDrop: cart already on ground, skipping")
        return false
    end

    -- Note: previously we called ISTimedActionQueue.clear(player) here to
    -- cancel mid-flight cart transfers / repairs. Problem: the action that
    -- TRIGGERED the force-drop (ISGrabCorpseAction, ISEquipWeaponAction,
    -- ISEnterVehicle, etc.) is itself in the queue — clearing it mid-tick
    -- produces vanilla's "ISTimedActionQueue:tick: bugged action" freeze.
    -- Mid-flight cart-dependent actions self-invalidate via their
    -- :isValid() checks once the cart is in the world, so no explicit
    -- clear is needed.

    local inventory = player:getInventory()

    -- Apply accumulated durability damage before drop. Passing player
    -- enables the centralized 50%/25%/10% threshold halos.
    local newCondition = SaucedCarts.Durability.applyAccumulatedDamage(cartItem, player)

    if newCondition <= 0 then
        -- Cart broke during combat drop - drop contents and destroy
        SaucedCarts.Durability.dropContentsAndDestroy(cartItem, player, square)

        -- Remove from hands
        player:setPrimaryHandItem(nil)
        player:setSecondaryHandItem(nil)

        -- Remove from inventory
        inventory:Remove(cartItem)
        sendRemoveItemFromContainer(inventory, cartItem)

        -- Notify player
        if SaucedCarts.Notifications then
            SaucedCarts.Notifications.cartBroke(player)
        end

        -- Fire broke event
        if SaucedCarts._fireEvent then
            SaucedCarts._fireEvent(SaucedCarts.Events.onCartBroke, player, cartItem, square)
        end

        ISInventoryPage.renderDirty = true
        SaucedCarts.debug("InstantDrop: combat drop - cart broke, items dropped")
        return true
    end

    -- Threshold halos (50% / 25% / 10%) are now centralized inside
    -- applyAccumulatedDamage above and fire only when a threshold is
    -- crossed downward, so the same drop won't spam the player.

    -- Update visual state before drop (so world item spawns with correct model)
    SaucedCarts.updateCartVisual(cartItem, player)

    -- Remove from hands
    player:setPrimaryHandItem(nil)
    player:setSecondaryHandItem(nil)

    -- Remove from inventory (local)
    inventory:Remove(cartItem)

    -- Sync inventory removal
    sendRemoveItemFromContainer(inventory, cartItem)

    -- Add to world (SP only - 5th param = true for sync in self-hosted)
    -- NOTE: Do NOT call transmitCompleteItemToClients() after this - the 5th param
    -- already handles transmission. Double-transmit causes duplicates in self-hosted MP.
    local dropX = player:getX() - math.floor(player:getX())
    local dropY = player:getY() - math.floor(player:getY())
    local worldItem = square:AddWorldInventoryItem(cartItem, dropX, dropY, 0, true)

    -- Fire drop event
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onCartDrop, player, cartItem, square)
    end

    ISInventoryPage.renderDirty = true
    SaucedCarts.debug(function() return "InstantDrop: combat drop - cart dropped for aiming (condition: " .. newCondition .. ")" end)
    return true
end

-- =============================================================================
-- MAIN DROP HANDLER
-- =============================================================================

--- Handle instant cart drop (combat/aim reactivity)
--- In MP: sends request to server for authoritative execution
--- In SP: drops directly via local function
---@param player IsoPlayer
---@param cartItem InventoryItem
---@return boolean success
function InstantDrop.handle(player, cartItem)
    -- MP: Request server to perform drop (server-authoritative)
    if isClient() and player:getOnlineID() then
        SaucedCarts.Network.sendToServer(player, "requestInstantDrop", {
            cartId = cartItem:getID(),
            distancePushed = cartItem:getModData().SaucedCarts_distancePushed or 0,
        })

        -- Do NOT clear the queue here — same reason as the SP path: the
        -- force-drop-triggering action (ISGrabCorpseAction etc.) is in
        -- the queue, and clearing mid-tick produces vanilla's
        -- "ISTimedActionQueue:tick: bugged action" freeze/crash. Cart-
        -- dependent actions self-invalidate via :isValid() once the cart
        -- is in the world.

        -- Mark pending drop (prevents onPlayerUpdate from re-applying animations)
        local playerKey = getPlayerKey(player)
        pendingDropTime[playerKey] = getTimestampMs()

        -- Clear local animation state
        player:setVariable("Weapon", "")
        player:setVariable("RightHandMask", "")
        player:setVariable("LeftHandMask", "")

        SaucedCarts.debug("InstantDrop: requested from server")
        return true
    end

    -- SP: Perform drop directly (local execution)
    return InstantDrop.dropCartSP(player, cartItem)
end

-- =============================================================================
-- PENDING DROP STATE
-- =============================================================================

--- Check if player has a pending drop (prevents animation re-apply during server processing)
---@param player IsoPlayer
---@return boolean isPending, number|nil elapsedMs
function InstantDrop.isPending(player)
    local playerKey = getPlayerKey(player)
    local dropTime = pendingDropTime[playerKey]
    if not dropTime then
        return false, nil
    end

    local elapsed = getTimestampMs() - dropTime
    if elapsed > PENDING_DROP_TIMEOUT_MS then
        -- Timeout expired, clear the pending state
        pendingDropTime[playerKey] = nil
        return false, nil
    end

    return true, elapsed
end

--- Clear pending drop state for a player
---@param player IsoPlayer
function InstantDrop.clearPending(player)
    local playerKey = getPlayerKey(player)
    pendingDropTime[playerKey] = nil
end

-- =============================================================================
-- CLEANUP API
-- =============================================================================

--- Cleanup tracking for a specific player (on death/disconnect)
---@param player IsoPlayer
function InstantDrop.cleanup(player)
    local playerKey = getPlayerKey(player)
    pendingDropTime[playerKey] = nil
end

--- Reset all state (debug/testing)
function InstantDrop.reset()
    pendingDropTime = {}
end

-- =============================================================================
-- MODULE INFO
-- =============================================================================

SaucedCarts.debug("InstantDrop module loaded")

return InstantDrop
