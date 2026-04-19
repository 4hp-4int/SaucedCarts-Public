-- ============================================================================
-- SaucedCarts/TimedActions/ISCartEquipAction.lua
-- ============================================================================
-- PURPOSE: Timed action for equipping a cart from a container (inventory or vehicle).
--          Follows ISEquipWeaponAction patterns for MP.
--
-- CONTEXT: SHARED (client + server)
--          Must be in shared/ for MP timed action sync to work.
--
-- KEY: This handles equipping from player inventory OR vehicle containers.
--      For picking up from ground, use ISCartPickupAction instead.
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"
require "SaucedCarts/CartVisuals"

-- MUST be global for MP action type registration
ISCartEquipAction = ISBaseTimedAction:derive("ISCartEquipAction")
ISCartEquipAction.Type = "ISCartEquipAction"

function ISCartEquipAction:isValid()
    -- If we already completed, stay valid (cart may have moved)
    if self.completed then
        return true
    end

    -- Check cart still exists and is accessible
    local cart = self:findCart()
    if not cart then
        return false
    end

    -- Don't allow equipping if already holding a heavy item (must drop first)
    local primary = self.character:getPrimaryHandItem()
    if primary and primary:isForceDropHeavyItem() then
        return false
    end

    return true
end

function ISCartEquipAction:waitToStart()
    -- No movement needed - cart is in a container we can access
    return false
end

function ISCartEquipAction:update()
    local cart = self:findCart()
    if cart then
        cart:setJobDelta(self:getJobDelta())
    end

    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISCartEquipAction:start()
    local cart = self:findCart()
    if cart then
        cart:setJobType(getText("ContextMenu_Equip"))
        cart:setJobDelta(0.0)
    end

    -- Play equip animation
    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "Mid")
    self.character:reportEvent("EventLootItem")
end

function ISCartEquipAction:stop()
    local cart = self:findCart()
    if cart then
        cart:setJobDelta(0.0)
    end

    ISBaseTimedAction.stop(self)
end

function ISCartEquipAction:perform()
    local cart = self:findCart()
    if cart then
        cart:setJobDelta(0.0)
    end

    ISBaseTimedAction.perform(self)
end

function ISCartEquipAction:complete()
    local cart = self:findCart()
    if not cart then
        SaucedCarts.error("Equip failed: cart not found (ID: " .. tostring(self.cartId) .. ")")
        return false
    end

    local playerInv = self.character:getInventory()

    -- If cart is not in player inventory, transfer it first
    local currentContainer = cart:getContainer()
    if currentContainer and currentContainer ~= playerInv then
        -- Remove from source container
        currentContainer:Remove(cart)
        sendRemoveItemFromContainer(currentContainer, cart)

        -- Add to player inventory
        playerInv:AddItem(cart)
        sendAddItemToContainer(playerInv, cart)
    end

    -- Equip in both hands
    self.character:setPrimaryHandItem(cart)
    self.character:setSecondaryHandItem(cart)

    -- Set animation variables
    self.character:setVariable("Weapon", "cart")
    self.character:setVariable("RightHandMask", "holdingcartright")
    self.character:setVariable("LeftHandMask", "holdingcartleft")

    -- Sync equip (server should do this)
    if isServer() then
        sendEquip(self.character)
    end

    -- Apply sandbox multipliers if not already applied
    SaucedCarts.applyMultipliers(cart)

    -- Update visual state to match current fill level
    SaucedCarts.updateCartVisual(cart, self.character)

    -- Fire equip event
    if SaucedCarts._fireEvent then
        local source = self.sourceType == "vehicle" and "vehicle" or "inventory"
        SaucedCarts._fireEvent(SaucedCarts.Events.onCartEquip, self.character, cart, source)
    end

    -- Refresh inventory UI
    -- Only on client - in dedicated MP getPlayerData doesn't exist on server, but in
    -- self-hosted MP it DOES exist (host is both client and server). Use explicit guard.
    if not isServer() then
        playerInv:setDrawDirty(true)
        if getPlayerData then
            local pdata = getPlayerData(self.character:getPlayerNum())
            if pdata then
                pdata.playerInventory:refreshBackpacks()
                pdata.lootInventory:refreshBackpacks()
            end
        end
    end

    -- Mark completed so isValid() doesn't fail after cart moves
    self.completed = true

    SaucedCarts.debug("Cart equipped via timed action")

    return true
end

function ISCartEquipAction:getDuration()
    if self.character and self.character:isTimedActionInstant() then
        return 1
    end
    -- Shorter than pickup from ground (50) since we don't need to walk/bend down
    return 30
end

--- Find the cart by stored ID
--- Re-finds the cart using stored primitives (MP-safe)
function ISCartEquipAction:findCart()
    -- Search player inventory first
    local playerInv = self.character:getInventory()
    if playerInv then
        local items = playerInv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:getID() == self.cartId then
                return item
            end
        end
    end

    -- If source was a vehicle, search nearby vehicle containers
    if self.sourceType == "vehicle" and self.vehicleX then
        local square = getCell():getGridSquare(self.vehicleX, self.vehicleY, self.vehicleZ)
        if square then
            -- Search vehicles on this square and adjacent squares
            for dx = -1, 1 do
                for dy = -1, 1 do
                    local checkSquare = getCell():getGridSquare(self.vehicleX + dx, self.vehicleY + dy, self.vehicleZ)
                    if checkSquare then
                        local vehicle = checkSquare:getVehicleContainer()
                        if vehicle then
                            local found = self:searchVehicleForCart(vehicle)
                            if found then return found end
                        end
                    end
                end
            end
        end
    end

    return nil
end

--- Search all containers in a vehicle for the cart by ID
---@param vehicle BaseVehicle
---@return InventoryItem|nil
function ISCartEquipAction:searchVehicleForCart(vehicle)
    if not vehicle then return nil end

    -- Get all parts and check for containers
    local script = vehicle:getScript()
    if not script then return nil end

    local partCount = script:getPartCount()
    for i = 0, partCount - 1 do
        local partScript = script:getPart(i)
        if partScript then
            local part = vehicle:getPartById(partScript:getId())
            if part then
                local container = part:getItemContainer()
                if container then
                    local items = container:getItems()
                    for j = 0, items:size() - 1 do
                        local item = items:get(j)
                        if item:getID() == self.cartId then
                            return item
                        end
                    end
                end
            end
        end
    end

    return nil
end

--- Create a new cart equip action
--- Pass serializable primitives only (for MP)
---@param character IsoPlayer
---@param cartId number Cart item ID
---@param sourceType string "inventory" or "vehicle"
---@param vehicleX number|nil Vehicle X coordinate (if sourceType is "vehicle")
---@param vehicleY number|nil Vehicle Y coordinate (if sourceType is "vehicle")
---@param vehicleZ number|nil Vehicle Z coordinate (if sourceType is "vehicle")
function ISCartEquipAction:new(character, cartId, sourceType, vehicleX, vehicleY, vehicleZ)
    local o = ISBaseTimedAction.new(self, character)

    -- Store serializable primitives only (MP-safe)
    o.cartId = cartId
    o.sourceType = sourceType or "inventory"
    o.vehicleX = vehicleX
    o.vehicleY = vehicleY
    o.vehicleZ = vehicleZ
    o.completed = false

    o.maxTime = o:getDuration()
    o.forceProgressBar = true
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    return o
end

--- Helper to create action from a cart item (extracts serializable data)
---@param character IsoPlayer
---@param cart InventoryItem
---@return ISCartEquipAction
function ISCartEquipAction.FromCart(character, cart)
    local container = cart:getContainer()
    local sourceType = "inventory"
    local vehicleX, vehicleY, vehicleZ = nil, nil, nil

    if container then
        local parent = container:getParent()
        if instanceof(parent, "BaseVehicle") then
            sourceType = "vehicle"
            -- Store vehicle position for re-finding
            local vehicleSquare = parent:getSquare()
            if vehicleSquare then
                vehicleX = vehicleSquare:getX()
                vehicleY = vehicleSquare:getY()
                vehicleZ = vehicleSquare:getZ()
            end
        end
    end

    return ISCartEquipAction:new(character, cart:getID(), sourceType, vehicleX, vehicleY, vehicleZ)
end
