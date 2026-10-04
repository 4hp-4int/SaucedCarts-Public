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

    -- If cart is not in player inventory, transfer it first. The LOCAL
    -- mutations run on both VMs (the client needs the cart in playerInv
    -- right now for the hand-equip below); the SENDS are server-only —
    -- client-side sendRemoveItemFromContainer = SyncItemDelete =
    -- Capability.EditItem = anti-cheat kick (see ISInstallFlashlightAction).
    local currentContainer = cart:getContainer()
    if currentContainer and currentContainer ~= playerInv then
        currentContainer:Remove(cart)
        playerInv:AddItem(cart)
        if not isClient() then
            sendRemoveItemFromContainer(currentContainer, cart)
            sendAddItemToContainer(playerInv, cart)
        end
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
--- Depth-first search of a container for the cart by ID, descending into
--- nested containers (a cart CAN reach the inside of a bag: vanilla "put in
--- container" has no cart-specific gate, and the client's containsID check —
--- which routes to this action — is not recursive either, so the server must
--- match the client's reachability or the equip desyncs). Depth-capped:
--- containers do not legitimately nest deeper than a few levels, and a
--- corrupt self-referencing chain must not hang the server.
---@param container ItemContainer|nil
---@param depth number|nil
---@return InventoryItem|nil
function ISCartEquipAction:searchContainerForCart(container, depth)
    if not container then return nil end
    depth = depth or 0
    if depth > 4 then return nil end

    local items = container:getItems()
    if not items then return nil end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getID() == self.cartId then
            return item
        end
        if instanceof(item, "InventoryContainer") then
            local inner = item.getInventory and item:getInventory() or nil
            local found = self:searchContainerForCart(inner, depth + 1)
            if found then return found end
        end
    end
    return nil
end

--- Scan the squares in a (2r+1)² window around x,y,z for the cart: vehicle
--- part containers and world container objects (crates, shelves, lockers).
---@return InventoryItem|nil
function ISCartEquipAction:searchSquaresForCart(x, y, z, radius)
    if not x or not y or not z then return nil end
    local cell = getCell()
    if not cell then return nil end
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell.getGridSquare and cell:getGridSquare(x + dx, y + dy, z) or nil
            if square then
                local vehicle = square.getVehicleContainer and square:getVehicleContainer() or nil
                if vehicle then
                    local found = self:searchVehicleForCart(vehicle)
                    if found then return found end
                end
                if square.getObjects then
                    local objects = square:getObjects()
                    if objects then
                        for i = 0, objects:size() - 1 do
                            local obj = objects:get(i)
                            local container = obj and obj.getContainer and obj:getContainer() or nil
                            local found = self:searchContainerForCart(container)
                            if found then return found end
                        end
                    end
                end
                -- Container ITEMS lying on the ground (a bag someone set down).
                -- They are IsoWorldInventoryObjects, whose getContainer() is
                -- nil -- the container belongs to the item -- so the object
                -- walk above never looks inside them.
                if square.getWorldObjects then
                    local worldObjects = square:getWorldObjects()
                    if worldObjects then
                        for i = 0, worldObjects:size() - 1 do
                            local wo = worldObjects:get(i)
                            local it = wo and wo.getItem and wo:getItem() or nil
                            local inner = it and it.getItemContainer and it:getItemContainer() or nil
                            if inner then
                                local found = self:searchContainerForCart(inner)
                                if found then return found end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- Server-side cart re-resolution from the action's serialized primitives
--- (cartId, sourceType, vehicleX/Y/Z). This runs on the AUTHORITATIVE copy of
--- a replicating action: a miss here after the client predicted the equip is
--- the reported "I try to push it and it just goes into my inventory". So the
--- ladder must cover every location the client would have offered "Push" for,
--- not just the tidy ones:
---   1. Player inventory, recursively (a cart nested in a bag).
---   2. The carried vehicle coords, 5x5 (long vehicles put the trunk further
---      from the reference square than the old 3x3 reached).
---   3. Last resort, ANY sourceType: the squares around the CHARACTER — the
---      player clicked the cart, so it is within reach. Covers world
---      containers (the client labels those "inventory"), vehicles whose
---      square was nil at click time (coords never captured), and drift
---      beyond the window. ID-exact matching everywhere: the ladder can
---      widen but never resolve the wrong item.
function ISCartEquipAction:findCart()
    -- 1. Player inventory, recursive.
    local found = self:searchContainerForCart(self.character:getInventory())
    if found then return found end

    -- 2. Carried vehicle coords.
    if self.sourceType == "vehicle" and self.vehicleX then
        found = self:searchSquaresForCart(self.vehicleX, self.vehicleY, self.vehicleZ, 2)
        if found then return found end
    end

    -- 3. Around the character.
    if self.character and self.character.getX then
        local cx = self.character:getX()
        local cy = self.character:getY()
        local cz = self.character:getZ()
        if cx and cy and cz then
            found = self:searchSquaresForCart(math.floor(cx), math.floor(cy), math.floor(cz), 2)
            if found then return found end
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
