-- ============================================================================
-- SaucedCarts/TimedActions/ISRemoveBatteryAction.lua
-- ============================================================================
-- PURPOSE: Timed action for removing battery from an upgraded cart.
--          Creates a battery item with the cart's remaining charge.
--
-- CONTEXT: SHARED (client + server)
--          Must be in shared/ for MP timed action sync to work.
--
-- KEY: Store serializable data (IDs, coordinates, booleans) not object refs.
--      Object references may not survive client->server serialization.
--
-- DESIGN:
--   - Cart's charge is removed
--   - New battery item created with that charge
--   - If light was active, it turns off
--   - Requires cart to have flashlight upgrade with charge > 0
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"

-- MUST be global for MP action type registration
ISRemoveBatteryAction = ISBaseTimedAction:derive("ISRemoveBatteryAction")
ISRemoveBatteryAction.Type = "ISRemoveBatteryAction"

-- ============================================================================
-- VALIDATION
-- ============================================================================

function ISRemoveBatteryAction:isValid()
    -- If already completed, stay valid
    if self.completed then
        return true
    end

    -- Re-find cart
    local cart = self:findCart()
    if not cart then
        return false
    end

    -- Cart must have flashlight upgrade
    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        return false
    end

    -- Cart must have charge to remove
    local charge = SaucedCarts.Upgrades.getBatteryCharge(cart)
    if not charge or charge <= 0 then
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

function ISRemoveBatteryAction:waitToStart()
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

function ISRemoveBatteryAction:start()
    local cart = self:findCart()
    if cart then
        cart:setJobType(getText("UI_SaucedCarts_RemoveBattery") or "Remove Battery")
        cart:setJobDelta(0.0)
    end

    -- Use crafting animation
    self:setActionAnim("Craft")
    self.character:reportEvent("EventCraftItem")
end

function ISRemoveBatteryAction:update()
    local cart = self:findCart()
    if cart then
        cart:setJobDelta(self:getJobDelta())
    end
end

function ISRemoveBatteryAction:stop()
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

function ISRemoveBatteryAction:perform()
    self.completed = true

    local cart = self:findCart()
    if not cart then
        SaucedCarts.debug("ISRemoveBatteryAction: cart not found in perform()")
        return
    end

    -- Check again that cart has flashlight
    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        SaucedCarts.debug("ISRemoveBatteryAction: cart has no flashlight upgrade")
        return
    end

    -- Get current charge
    local charge = SaucedCarts.Upgrades.getBatteryCharge(cart)
    if not charge or charge <= 0 then
        SaucedCarts.debug("ISRemoveBatteryAction: cart has no charge")
        return
    end

    -- If light is on, turn it off first and broadcast to other clients
    local wasLightActive = SaucedCarts.Upgrades.isLightActive(cart)
    if wasLightActive then
        SaucedCarts.Upgrades.setLightActive(cart, false)
        SaucedCarts.Upgrades.disableCartLight(cart)

        -- Broadcast light state change so other clients see it turn off
        if isServer() then
            SaucedCarts.Network.broadcast("cartLightUpdate", {
                playerOnlineId = self.character:getOnlineID(),
                cartId = cart:getID(),
                isActive = false,
            })
        end
    end

    -- Remove charge from cart
    SaucedCarts.Upgrades.setBatteryCharge(cart, 0)

    -- Create battery with the charge
    local battery = instanceItem("Base.Battery")
    if battery then
        battery:setCurrentUsesFloat(charge)
        battery:setCondition(battery:getConditionMax())

        -- Add to player inventory
        local inv = self.character:getInventory()
        inv:AddItem(battery)
        sendAddItemToContainer(inv, battery)

        SaucedCarts.debug(function() return "ISRemoveBatteryAction: created battery with charge " .. tostring(charge) end)
    else
        SaucedCarts.debug("ISRemoveBatteryAction: failed to create battery item")
    end

    -- Fire event
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onBatteryRemoved, self.character, cart, charge)
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
function ISRemoveBatteryAction:findCart()
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

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

--- Create a new remove battery action
--- CRITICAL: Only primitive types in constructor for MP serialization
---@param character IsoPlayer The player performing the action
---@param cartId number The cart's item ID
---@param squareX number|nil X coordinate if cart is on ground
---@param squareY number|nil Y coordinate if cart is on ground
---@param squareZ number|nil Z coordinate if cart is on ground
function ISRemoveBatteryAction:new(character, cartId, squareX, squareY, squareZ)
    local o = ISBaseTimedAction.new(self, character)

    -- Serializable primitives only
    o.cartId = cartId
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

--- Helper: Create action from cart item
--- Extracts IDs for MP-safe construction
---@param character IsoPlayer
---@param cart InventoryItem
---@return ISRemoveBatteryAction
function ISRemoveBatteryAction.FromCart(character, cart)
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

    return ISRemoveBatteryAction:new(
        character,
        cart:getID(),
        squareX, squareY, squareZ
    )
end

SaucedCarts.debug("ISRemoveBatteryAction loaded")
