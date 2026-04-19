-- ============================================================================
-- SaucedCarts/TimedActions/ISInsertBatteryAction.lua
-- ============================================================================
-- PURPOSE: Timed action for inserting a battery into an upgraded cart.
--          Consumes the battery and adds its charge to the cart.
--
-- CONTEXT: SHARED (client + server)
--          Must be in shared/ for MP timed action sync to work.
--
-- KEY: Store serializable data (IDs, coordinates, booleans) not object refs.
--      Object references may not survive client->server serialization.
--
-- DESIGN:
--   - Battery is CONSUMED permanently
--   - Battery charge transfers to cart (caps at 1.0)
--   - Requires cart to have flashlight upgrade installed
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"

-- MUST be global for MP action type registration
ISInsertBatteryAction = ISBaseTimedAction:derive("ISInsertBatteryAction")
ISInsertBatteryAction.Type = "ISInsertBatteryAction"

-- ============================================================================
-- VALIDATION
-- ============================================================================

function ISInsertBatteryAction:isValid()
    -- If already completed, stay valid
    if self.completed then
        return true
    end

    -- Re-find cart and battery
    local cart = self:findCart()
    if not cart then
        return false
    end

    local battery = self:findBattery()
    if not battery then
        return false
    end

    -- Cart must have flashlight upgrade
    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        return false
    end

    -- For ground carts, check reachability
    if self.isGroundCart then
        local worldItem = cart:getWorldItem()
        if not worldItem then
            return false
        end
        local sq = worldItem:getSquare()
        if sq and self.character:getSquare() then
            if not self.character:getSquare():canReachTo(sq) then
                return false
            end
        end
    end

    return true
end

function ISInsertBatteryAction:waitToStart()
    -- Face ground cart if applicable
    if self.isGroundCart then
        local cart = self:findCart()
        if cart then
            local worldItem = cart:getWorldItem()
            if worldItem then
                self.character:faceThisObject(worldItem)
            end
        end
    end
    return self.character:shouldBeTurning()
end

-- ============================================================================
-- ACTION LIFECYCLE
-- ============================================================================

function ISInsertBatteryAction:start()
    local cart = self:findCart()
    if cart then
        cart:setJobType(getText("UI_SaucedCarts_InsertBattery") or "Insert Battery")
        cart:setJobDelta(0.0)
    end

    -- Use crafting animation
    self:setActionAnim("Craft")
    self.character:reportEvent("EventCraftItem")
end

function ISInsertBatteryAction:update()
    local cart = self:findCart()
    if cart then
        cart:setJobDelta(self:getJobDelta())
    end
end

function ISInsertBatteryAction:stop()
    local cart = self:findCart()
    if cart then
        cart:setJobType(nil)
        cart:setJobDelta(0.0)
    end

    ISBaseTimedAction.stop(self)
end

-- ============================================================================
-- COMPLETION
-- ============================================================================

function ISInsertBatteryAction:perform()
    self.completed = true

    local cart = self:findCart()
    local battery = self:findBattery()

    if not cart or not battery then
        SaucedCarts.debug("ISInsertBatteryAction: cart or battery not found in perform()")
        return
    end

    -- Check again that cart has flashlight
    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        SaucedCarts.debug("ISInsertBatteryAction: cart has no flashlight upgrade")
        return
    end

    -- Get battery charge (uses delta 0.0-1.0)
    local batteryCharge = battery:getCurrentUsesFloat()
    if batteryCharge <= 0 then
        SaucedCarts.debug("ISInsertBatteryAction: battery is empty")
        return
    end

    -- Add charge to cart (cap at 1.0)
    local success = SaucedCarts.Upgrades.addBatteryCharge(cart, batteryCharge)
    if not success then
        SaucedCarts.debug("ISInsertBatteryAction: failed to add charge")
        return
    end

    -- Consume the battery
    local container = battery:getContainer()
    if container then
        container:DoRemoveItem(battery)
        sendRemoveItemFromContainer(container, battery)
    end

    -- Fire event
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onBatteryInserted, self.character, cart, batteryCharge)
    end

    -- Sync item state (only for equipped carts)
    -- syncItemModData fails for world items (container not replicated to clients)
    if isServer() and not self.isGroundCart then
        syncItemModData(self.character, cart)
        syncItemFields(self.character, cart)
    end

    -- Clean up job indicator
    cart:setJobType(nil)
    cart:setJobDelta(0.0)

    ISBaseTimedAction.perform(self)
end

-- ============================================================================
-- FINDERS (Re-locate objects by ID)
-- ============================================================================

--- Find the cart by stored ID
---@return InventoryItem|nil
function ISInsertBatteryAction:findCart()
    -- Check equipped hands first
    local primary = self.character:getPrimaryHandItem()
    if primary and primary:getID() == self.cartId then
        return primary
    end
    local secondary = self.character:getSecondaryHandItem()
    if secondary and secondary:getID() == self.cartId then
        return secondary
    end

    -- Check player inventory
    local inv = self.character:getInventory()
    if inv then
        local cart = inv:getItemById(self.cartId)
        if cart then return cart end
    end

    -- Check world (if ground cart)
    if self.isGroundCart and self.squareX and self.squareY and self.squareZ then
        local square = getCell():getGridSquare(self.squareX, self.squareY, self.squareZ)
        if square then
            local objects = square:getWorldObjects()
            if objects then
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    if instanceof(obj, "IsoWorldInventoryObject") then
                        local item = obj:getItem()
                        if item and item:getID() == self.cartId then
                            return item
                        end
                    end
                end
            end
        end
    end

    return nil
end

--- Find the battery by stored ID
---@return InventoryItem|nil
function ISInsertBatteryAction:findBattery()
    local inv = self.character:getInventory()
    if inv then
        return inv:getItemById(self.batteryId)
    end
    return nil
end

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

--- Create a new insert battery action
--- CRITICAL: Only primitive types in constructor for MP serialization
---@param character IsoPlayer The player performing the action
---@param cartId number The cart's item ID
---@param batteryId number The battery's item ID
---@param squareX number|nil X coordinate if cart is on ground
---@param squareY number|nil Y coordinate if cart is on ground
---@param squareZ number|nil Z coordinate if cart is on ground
function ISInsertBatteryAction:new(character, cartId, batteryId, squareX, squareY, squareZ)
    local o = ISBaseTimedAction.new(self, character)

    -- Serializable primitives only
    o.cartId = cartId
    o.batteryId = batteryId
    o.squareX = squareX
    o.squareY = squareY
    o.squareZ = squareZ
    o.isGroundCart = (squareX ~= nil)

    -- Action properties
    o.maxTime = 100  -- ~1.7 seconds
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = false
    o.completed = false

    return o
end

--- Helper: Create action from cart and battery items
--- Extracts IDs for MP-safe construction
---@param character IsoPlayer
---@param cart InventoryItem
---@param battery InventoryItem
---@return ISInsertBatteryAction
function ISInsertBatteryAction.FromItems(character, cart, battery)
    local squareX, squareY, squareZ = nil, nil, nil

    -- Check if cart is on ground
    local worldItem = cart:getWorldItem()
    if worldItem then
        local sq = worldItem:getSquare()
        if sq then
            squareX = sq:getX()
            squareY = sq:getY()
            squareZ = sq:getZ()
        end
    end

    return ISInsertBatteryAction:new(
        character,
        cart:getID(),
        battery:getID(),
        squareX, squareY, squareZ
    )
end

SaucedCarts.debug("ISInsertBatteryAction loaded")
