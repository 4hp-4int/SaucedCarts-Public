-- ============================================================================
-- SaucedCarts/TimedActions/ISInstallFlashlightAction.lua
-- ============================================================================
-- PURPOSE: Timed action for installing a flashlight upgrade on a cart.
--          Consumes the flashlight and copies its light properties to cart.
--
-- CONTEXT: SHARED (client + server)
--          Must be in shared/ for MP timed action sync to work.
--
-- KEY: Store serializable data (IDs, coordinates, booleans) not object refs.
--      Object references may not survive client->server serialization.
--
-- DESIGN:
--   - Flashlight is CONSUMED permanently (not just attached)
--   - Light properties copied to cart ModData
--   - If flashlight has battery, charge transfers to cart
--   - Cart visual model updates to show flashlight mount
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"

-- MUST be global for MP action type registration
ISInstallFlashlightAction = ISBaseTimedAction:derive("ISInstallFlashlightAction")
ISInstallFlashlightAction.Type = "ISInstallFlashlightAction"

-- ============================================================================
-- ATTACHMENT MATERIALS
-- ============================================================================

--- Attachment materials in priority order (same as FlashlightMenu.lua)
local ATTACHMENT_MATERIALS = {
    ["Base.DuctTape"] = { uses = 1, name = "Duct Tape" },
    ["Base.Zipties"] = { uses = 1, name = "Zip Ties" },
    ["Base.Scotchtape"] = { uses = 1, name = "Adhesive Tape" },
    ["Base.Rope"] = { uses = 1, name = "Rope" },
    ["Base.Twine"] = { uses = 2, name = "Twine" },
}

--- Get the number of uses available from an item
---@param item InventoryItem
---@return number uses
local function getItemUses(item)
    if not item then return 0 end
    -- Drainable items use getCurrentUses(), non-drainable use getUsesRemaining()
    if item.getCurrentUses then
        return item:getCurrentUses()
    elseif item.getUsesRemaining then
        return item:getUsesRemaining()
    end
    -- Stackable/single-use items count as 1 use per item
    return 1
end

--- Find an attachment material with enough uses
---@param inv ItemContainer
---@param materialType string
---@param usesNeeded number
---@return InventoryItem|nil
local function findMaterialWithUses(inv, materialType, usesNeeded)
    local items = inv:getAllTypeRecurse(materialType)
    if not items then return nil end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if getItemUses(item) >= usesNeeded then
            return item
        end
    end
    return nil
end

-- ============================================================================
-- VALIDATION
-- ============================================================================

function ISInstallFlashlightAction:isValid()
    -- If already completed, stay valid
    if self.completed then
        return true
    end

    -- Re-find cart and flashlight
    local cart = self:findCart()
    if not cart then
        return false
    end

    local flashlight = self:findFlashlight()
    if not flashlight then
        return false
    end

    -- Cart must not already have flashlight
    if SaucedCarts.Upgrades.hasFlashlight(cart) then
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

    -- Check attachment material still available
    if not self.materialType or not self.materialUses then
        return false
    end
    local inv = self.character:getInventory()
    local material = findMaterialWithUses(inv, self.materialType, self.materialUses)
    if not material then
        return false
    end

    return true
end

function ISInstallFlashlightAction:waitToStart()
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

function ISInstallFlashlightAction:start()
    local cart = self:findCart()
    if cart then
        cart:setJobType(getText("UI_SaucedCarts_InstallFlashlight") or "Install Flashlight")
        cart:setJobDelta(0.0)
    end

    -- Use crafting animation
    self:setActionAnim("Craft")
    self.character:reportEvent("EventCraftItem")

    -- Play attachment sound (tape/ties sound)
    self.sound = self.character:playSound("FixWithTape")
end

function ISInstallFlashlightAction:update()
    local cart = self:findCart()
    if cart then
        cart:setJobDelta(self:getJobDelta())
    end
end

function ISInstallFlashlightAction:stop()
    local cart = self:findCart()
    if cart then
        cart:setJobType(nil)
        cart:setJobDelta(0.0)
    end

    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end

    ISBaseTimedAction.stop(self)
end

-- ============================================================================
-- COMPLETION
-- ============================================================================

function ISInstallFlashlightAction:perform()
    self.completed = true

    local cart = self:findCart()
    local flashlight = self:findFlashlight()

    if not cart or not flashlight then
        SaucedCarts.debug("ISInstallFlashlightAction: cart or flashlight not found in perform()")
        return
    end

    -- Check again that cart doesn't already have flashlight
    if SaucedCarts.Upgrades.hasFlashlight(cart) then
        SaucedCarts.debug("ISInstallFlashlightAction: cart already has flashlight")
        return
    end

    -- Install flashlight upgrade (copies properties to ModData)
    local success = SaucedCarts.Upgrades.installFlashlight(cart, flashlight)
    if not success then
        SaucedCarts.debug("ISInstallFlashlightAction: installation failed")
        return
    end

    -- Consume the flashlight
    local container = flashlight:getContainer()
    if container then
        container:DoRemoveItem(flashlight)
        sendRemoveItemFromContainer(container, flashlight)
    end

    -- Consume the attachment material
    local inv = self.character:getInventory()
    local material = findMaterialWithUses(inv, self.materialType, self.materialUses)
    if material then
        local currentUses = getItemUses(material)
        local newUses = currentUses - self.materialUses

        if newUses <= 0 then
            -- Consume entire item
            local matContainer = material:getContainer()
            if matContainer then
                matContainer:DoRemoveItem(material)
                sendRemoveItemFromContainer(matContainer, material)
            end
        else
            -- Reduce uses (drainable or multi-use items)
            if material.setCurrentUses then
                material:setCurrentUses(newUses)
            elseif material.setUsesRemaining then
                material:setUsesRemaining(newUses)
            end
            -- Sync item state
            if isServer() then
                syncItemFields(self.character, material)
            end
        end
    end

    local materialName = ATTACHMENT_MATERIALS[self.materialType] and ATTACHMENT_MATERIALS[self.materialType].name or self.materialType
    SaucedCarts.debug("ISInstallFlashlightAction: consumed flashlight + " .. self.materialUses .. " uses of " .. materialName)

    -- Update cart visual model (server-side)
    if SaucedCarts.updateCartVisual then
        SaucedCarts.updateCartVisual(cart, self.character)
    end

    -- Fire event (for local listeners)
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onFlashlightInstalled, self.character, cart, self.flashlightType)
    end

    -- Sync item state (only for equipped carts)
    -- syncItemModData fails for world items (container not replicated to clients)
    if isServer() and not self.isGroundCart then
        syncItemModData(self.character, cart)
        syncItemFields(self.character, cart)
    end

    -- MP: Broadcast upgrade installed to all clients for visual refresh
    -- In Build 42, perform() runs on server - clients need notification to refresh hand models
    -- Include new upgrade key so client can apply it before visual update (avoids sync race)
    if isServer() then
        local newUpgradeKey = SaucedCarts.Upgrades.getUpgradeKey(cart)  -- "flashlight" or nil
        SaucedCarts.Network.broadcast("upgradeInstalled", {
            playerOnlineId = self.character:getOnlineID(),
            cartId = cart:getID(),
            upgradeType = "flashlight",
            newUpgradeKey = newUpgradeKey,
            squareX = self.squareX,
            squareY = self.squareY,
            squareZ = self.squareZ,
        })
    end

    -- Clean up job indicator
    cart:setJobType(nil)
    cart:setJobDelta(0.0)

    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end

    ISBaseTimedAction.perform(self)
end

-- ============================================================================
-- FINDERS (Re-locate objects by ID)
-- ============================================================================

--- Find the cart by stored ID
---@return InventoryItem|nil
function ISInstallFlashlightAction:findCart()
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

--- Find the flashlight by stored ID
---@return InventoryItem|nil
function ISInstallFlashlightAction:findFlashlight()
    local inv = self.character:getInventory()
    if inv then
        return inv:getItemById(self.flashlightId)
    end
    return nil
end

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

--- Create a new install flashlight action
--- CRITICAL: Only primitive types in constructor for MP serialization
---@param character IsoPlayer The player performing the action
---@param cartId number The cart's item ID
---@param flashlightId number The flashlight's item ID
---@param flashlightType string The flashlight's full type (for event)
---@param materialType string The attachment material full type (e.g. "Base.DuctTape")
---@param materialUses number How many uses to consume from the material
---@param squareX number|nil X coordinate if cart is on ground
---@param squareY number|nil Y coordinate if cart is on ground
---@param squareZ number|nil Z coordinate if cart is on ground
function ISInstallFlashlightAction:new(character, cartId, flashlightId, flashlightType, materialType, materialUses, squareX, squareY, squareZ)
    local o = ISBaseTimedAction.new(self, character)

    -- Serializable primitives only
    o.cartId = cartId
    o.flashlightId = flashlightId
    o.flashlightType = flashlightType
    o.materialType = materialType
    o.materialUses = materialUses
    o.squareX = squareX
    o.squareY = squareY
    o.squareZ = squareZ
    o.isGroundCart = (squareX ~= nil)

    -- Action properties
    o.maxTime = 330  -- ~5.5 seconds
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = false
    o.completed = false

    return o
end

--- Helper: Create action from cart and flashlight items
--- Extracts IDs for MP-safe construction
---@param character IsoPlayer
---@param cart InventoryItem
---@param flashlight InventoryItem
---@param materialType string The attachment material full type
---@param materialUses number How many uses to consume
---@return ISInstallFlashlightAction
function ISInstallFlashlightAction.FromItems(character, cart, flashlight, materialType, materialUses)
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

    return ISInstallFlashlightAction:new(
        character,
        cart:getID(),
        flashlight:getID(),
        flashlight:getFullType(),
        materialType,
        materialUses,
        squareX, squareY, squareZ
    )
end

SaucedCarts.debug("ISInstallFlashlightAction loaded")
