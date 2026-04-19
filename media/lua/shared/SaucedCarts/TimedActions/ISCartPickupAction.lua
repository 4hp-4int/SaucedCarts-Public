-- ============================================================================
-- SaucedCarts/TimedActions/ISCartPickupAction.lua
-- ============================================================================
-- PURPOSE: Timed action for picking up a cart from the ground.
--          Follows ISGrabCorpseAction/ISDropWorldItemAction patterns for MP.
--
-- CONTEXT: SHARED (client + server)
--          Must be in shared/ for MP timed action sync to work.
--
-- KEY: Store serializable data (coordinates, IDs) not object references.
--      The worldItem reference may not survive client->server serialization.
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"
require "SaucedCarts/CartVisuals"
require "SaucedCarts/Durability"

-- MUST be global for MP action type registration
ISCartPickupAction = ISBaseTimedAction:derive("ISCartPickupAction")
ISCartPickupAction.Type = "ISCartPickupAction"

function ISCartPickupAction:isValid()
    -- If we already completed successfully, stay valid
    -- (isValid can be called after complete() removes the item from world)
    if self.completed then
        return true
    end

    -- Don't allow pickup if already holding a heavy item (must drop first)
    local primary = self.character:getPrimaryHandItem()
    if primary and primary:isForceDropHeavyItem() then
        return false
    end

    -- Re-find the world item on each check (reference may have changed)
    local worldItem = self:findWorldItem()
    if not worldItem then
        return false
    end

    local sq = worldItem:getSquare()
    if not sq then
        return false
    end

    -- Check can reach
    if self.character and self.character:getSquare() then
        if not self.character:getSquare():canReachTo(sq) then
            return false
        end
    end

    return true
end

function ISCartPickupAction:waitToStart()
    local worldItem = self:findWorldItem()
    if worldItem then
        self.character:faceThisObject(worldItem)
    end
    return self.character:shouldBeTurning()
end

function ISCartPickupAction:update()
    local item = self:findItem()
    if item then
        item:setJobDelta(self:getJobDelta())
    end

    local worldItem = self:findWorldItem()
    if worldItem then
        self.character:faceThisObject(worldItem)
    end

    self.character:setMetabolicTarget(Metabolics.HeavyDomestic)
end

function ISCartPickupAction:start()
    local item = self:findItem()
    if item then
        item:setJobType(getText("ContextMenu_Grab"))
        item:setJobDelta(0.0)
    end

    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "Low")
    self.character:reportEvent("EventLootItem")

    -- Play pickup sound (wrap in pcall in case getPlaceOneSound throws)
    local sound = "PutItemInBag"
    pcall(function()
        if item and item:getPlaceOneSound() then
            sound = item:getPlaceOneSound()
        end
    end)
    self.sound = self.character:playSound(sound)
end

function ISCartPickupAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end

    local item = self:findItem()
    if item then
        item:setJobDelta(0.0)
    end

    ISBaseTimedAction.stop(self)
end

function ISCartPickupAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end

    local item = self:findItem()
    if item then
        item:setJobDelta(0.0)
    end

    ISBaseTimedAction.perform(self)
end

function ISCartPickupAction:complete()
    local worldItem = self:findWorldItem()
    if not worldItem then
        SaucedCarts.error("Pickup failed: world item not found at " .. self.squareX .. "," .. self.squareY .. "," .. self.squareZ)
        return false
    end

    local item = worldItem:getItem()
    if not item then
        SaucedCarts.error("Pickup failed: item not found (ID: " .. tostring(self.itemId) .. ")")
        return false
    end

    local square = worldItem:getSquare()
    if not square then
        SaucedCarts.error("Pickup failed: square not found for world item")
        return false
    end

    -- NOTE: Durability damage is now applied on DROP, not pickup.
    -- This provides a cleaner mental model: push cart → drop → damage applied.
    -- See ContainerRestrictions.lua (ISDropWorldItemAction hook) and
    -- CartStateHandler.lua (instantDropCart) for damage application.

    -- Remove from world
    square:transmitRemoveItemFromSquare(worldItem)
    square:removeWorldObject(worldItem)
    item:setWorldItem(nil)

    -- Add to inventory
    self.character:getInventory():AddItem(item)
    sendAddItemToContainer(self.character:getInventory(), item)

    -- Apply sandbox multipliers
    SaucedCarts.applyMultipliers(item)

    -- Equip in both hands
    self.character:setPrimaryHandItem(item)
    self.character:setSecondaryHandItem(item)

    -- Set animation variables
    self.character:setVariable("Weapon", "cart")
    self.character:setVariable("RightHandMask", "holdingcartright")
    self.character:setVariable("LeftHandMask", "holdingcartleft")

    -- Sync equip (server should do this)
    if isServer() then
        sendEquip(self.character)
    end

    -- Update visual state to match current fill level
    -- This ensures worldStaticModel is correct for when cart is dropped later
    SaucedCarts.updateCartVisual(item, self.character)

    -- Fire equip event
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onCartEquip, self.character, item, "ground")
    end

    -- Refresh inventory UI to show the cart container (must happen AFTER equip)
    -- Only on client - in dedicated MP getPlayerData doesn't exist on server, but in
    -- self-hosted MP it DOES exist (host is both client and server). Use explicit guard.
    if not isServer() then
        self.character:getInventory():setDrawDirty(true)
        if getPlayerData then
            local pdata = getPlayerData(self.character:getPlayerNum())
            if pdata then
                pdata.playerInventory:refreshBackpacks()
                pdata.lootInventory:refreshBackpacks()
            end
        end
    end

    -- Mark completed so isValid() doesn't fail after we remove the item
    self.completed = true

    return true
end

function ISCartPickupAction:getDuration()
    if self.character and self.character:isTimedActionInstant() then
        return 1
    end
    return 50
end

--- Find the world item by stored coordinates and item ID
function ISCartPickupAction:findWorldItem()
    local square = getCell():getGridSquare(self.squareX, self.squareY, self.squareZ)
    if not square then
        return nil
    end

    local objects = square:getWorldObjects()
    if not objects then
        return nil
    end

    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if instanceof(obj, "IsoWorldInventoryObject") then
            local item = obj:getItem()
            if item and item:getID() == self.itemId then
                return obj
            end
        end
    end

    return nil
end

--- Find the item by stored ID
function ISCartPickupAction:findItem()
    local worldItem = self:findWorldItem()
    if worldItem then
        return worldItem:getItem()
    end
    return nil
end

--- Create a new cart pickup action
--- Pass serializable primitives: coordinates and item ID
---@param character IsoPlayer
---@param squareX number X coordinate of square
---@param squareY number Y coordinate of square
---@param squareZ number Z coordinate of square
---@param itemId number Item ID to find
function ISCartPickupAction:new(character, squareX, squareY, squareZ, itemId)
    local o = ISBaseTimedAction.new(self, character)

    -- Store serializable data directly (primitives serialize correctly in MP)
    o.squareX = squareX
    o.squareY = squareY
    o.squareZ = squareZ
    o.itemId = itemId

    o.maxTime = o:getDuration()
    o.forceProgressBar = true
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.completed = false

    return o
end

--- Helper to create action from a world item (extracts serializable data)
---@param character IsoPlayer
---@param worldItem IsoWorldInventoryObject
---@return ISCartPickupAction
function ISCartPickupAction.FromWorldItem(character, worldItem)
    local square = worldItem:getSquare()
    local item = worldItem:getItem()
    return ISCartPickupAction:new(character, square:getX(), square:getY(), square:getZ(), item:getID())
end
