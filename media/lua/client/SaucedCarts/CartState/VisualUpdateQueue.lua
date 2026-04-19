-- ============================================================================
-- SaucedCarts/CartState/VisualUpdateQueue.lua
-- ============================================================================
-- PURPOSE: Queue and coalesce cart visual updates.
--          When items are transferred to/from cart, the visual model may need
--          to change based on fill state. This module defers updates to the
--          next tick to coalesce rapid transfers (bulk operations) into a
--          single visual update.
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/CartVisuals"
require "SaucedCarts/Network"

---@class SaucedCartsVisualUpdateQueue
local VisualUpdateQueue = {}

-- =============================================================================
-- STATE
-- =============================================================================

-- Queue of carts that need visual updates
-- Format: { cart = InventoryItem, cartId = number, player = IsoPlayer, ticksRemaining = number }
-- Uses cartId for comparison to handle edge cases where object references change
local pendingCartUpdates = {}

-- How many ticks to wait before processing
-- Short delay coalesces rapid transfers (shift-click bulk) into one update
local PENDING_UPDATE_TICKS = 1

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

--- Check if a container belongs to a cart (ground or equipped)
--- Wrapper around shared helper with dedicated server context check.
---@param container ItemContainer
---@param player IsoPlayer|nil Optional player to check equipped items
---@return InventoryItem|nil cart The cart item, or nil if not a cart container
local function getCartFromContainer(container, player)
    -- Skip if called from dedicated server context (isServer true but isClient false)
    -- In SP: isClient=false, isServer=false → runs
    -- In MP client: isClient=true, isServer=false → runs
    -- In MP self-hosted: isClient=true, isServer=true → runs
    -- In MP dedicated server: isClient=false, isServer=true → skips
    if isServer() and not isClient() then return nil end

    -- Use shared helper from Network module
    return SaucedCarts.Network.getCartFromContainer(container, player)
end

-- =============================================================================
-- QUEUE MANAGEMENT
-- =============================================================================

--- Queue a cart for visual update (deferred for coalescing)
---@param cart InventoryItem
---@param player IsoPlayer
function VisualUpdateQueue.queueUpdate(cart, player)
    local cartId = cart:getID()

    -- Check if cart is already queued (use ID comparison for reliability)
    for _, pending in ipairs(pendingCartUpdates) do
        if pending.cartId == cartId then
            -- Reset timer and update cart reference (in case it changed)
            pending.cart = cart
            pending.ticksRemaining = PENDING_UPDATE_TICKS
            return
        end
    end

    -- Add to queue
    table.insert(pendingCartUpdates, {
        cart = cart,
        cartId = cartId,
        player = player,
        ticksRemaining = PENDING_UPDATE_TICKS
    })
    SaucedCarts.debug(function() return "VisualUpdateQueue: queued cart (ID: " .. tostring(cartId) .. ")" end)
end

--- Process pending cart updates on each tick
local function processPendingUpdates()
    -- Early exit if nothing pending (fast path for 99% of ticks)
    if #pendingCartUpdates == 0 then return end

    local i = 1
    while i <= #pendingCartUpdates do
        local pending = pendingCartUpdates[i]
        pending.ticksRemaining = pending.ticksRemaining - 1

        if pending.ticksRemaining <= 0 then
            -- Validate cart still exists (could have been deleted/removed)
            -- getCondition() will error if item is invalid, so use pcall
            local isValid = pcall(function() return pending.cart:getCondition() end)

            if isValid then
                SaucedCarts.updateCartVisual(pending.cart, pending.player)

                -- Fire visual update event
                if SaucedCarts._fireEvent then
                    local fillState = SaucedCarts.calculateFillState(pending.cart, pending.player)
                    local modelName = pending.cart:getStaticModel()
                    SaucedCarts._fireEvent(SaucedCarts.Events.onCartVisualUpdate, pending.cart, fillState, modelName)
                end
            end
            table.remove(pendingCartUpdates, i)
        else
            i = i + 1
        end
    end
end

-- =============================================================================
-- TRANSFER ACTION HOOK
-- =============================================================================

--- Hook into ISInventoryTransferAction to detect cart container transfers
--- Fires onCartContentsChanged event - visual updates handled by event listener
local function hookTransferAction()
    -- Ensure ISInventoryTransferAction is loaded
    if not ISInventoryTransferAction then
        SaucedCarts.debug(function() return "VisualUpdateQueue: ISInventoryTransferAction not found, skipping hook" end)
        return
    end

    -- Store original perform function
    local originalPerform = ISInventoryTransferAction.perform

    -- Wrap with our event-firing logic
    -- Uses pcall to ensure we never break the original action
    ISInventoryTransferAction.perform = function(self)
        -- Safely check containers BEFORE calling original
        local srcCart, destCart
        pcall(function()
            srcCart = getCartFromContainer(self.srcContainer, self.character)
            destCart = getCartFromContainer(self.destContainer, self.character)
        end)

        -- ALWAYS call original perform (never break vanilla behavior)
        originalPerform(self)

        -- Fire contents changed events - visual updates handled by event listener below
        if srcCart or destCart then
            pcall(function()
                if SaucedCarts._fireEvent then
                    if srcCart then
                        SaucedCarts._fireEvent(SaucedCarts.Events.onCartContentsChanged, srcCart, self.character)
                    end
                    if destCart and destCart ~= srcCart then
                        SaucedCarts._fireEvent(SaucedCarts.Events.onCartContentsChanged, destCart, self.character)
                    end
                end
            end)
        end
    end

    SaucedCarts.debug(function() return "VisualUpdateQueue: hooked ISInventoryTransferAction:perform()" end)
end

-- =============================================================================
-- EVENT-DRIVEN VISUAL UPDATES
-- =============================================================================
-- Listen for onCartContentsChanged and trigger visual updates.
-- This decouples the visual update from the transfer hook.

local function onCartContentsChanged(cart, player)
    if not cart or not player then return end

    local worldItem = cart:getWorldItem()
    if worldItem and isClient() then
        -- Ground cart in MP: client pre-calculates fill state and sends to server.
        -- This avoids race conditions where server state lags behind client prediction.
        -- The client's local state is correct after ISInventoryTransferAction completes locally.
        local location = SaucedCarts.Network.getGroundCartLocation(cart)
        if location then
            -- Pre-calculate fill state and model from client's current (post-transfer) state
            local fillState = SaucedCarts.calculateFillState(cart)
            local modelName = SaucedCarts.buildCartModelName(cart, fillState)
            location.fillState = fillState
            location.modelName = modelName
            SaucedCarts.Network.sendToServer(player, "syncGroundCartVisual", location)
        end
    else
        -- Equipped cart or SP: update locally
        VisualUpdateQueue.queueUpdate(cart, player)
    end
end

-- Register event listener
if SaucedCarts.Events and SaucedCarts.Events.onCartContentsChanged then
    SaucedCarts.Events.onCartContentsChanged:Add(onCartContentsChanged)
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

--- Get current queue size (for debugging)
---@return number
function VisualUpdateQueue.getQueueSize()
    return #pendingCartUpdates
end

--- Reset all state (debug/testing)
function VisualUpdateQueue.reset()
    pendingCartUpdates = {}
end

--- Get cart from container (exposed for other modules that may need it)
---@param container ItemContainer
---@param player IsoPlayer|nil
---@return InventoryItem|nil
function VisualUpdateQueue.getCartFromContainer(container, player)
    return getCartFromContainer(container, player)
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

Events.OnTick.Add(processPendingUpdates)
Events.OnGameStart.Add(hookTransferAction)

SaucedCarts.debug(function() return "VisualUpdateQueue module loaded" end)

return VisualUpdateQueue
