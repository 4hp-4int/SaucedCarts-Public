-- ============================================================================
-- SaucedCarts/TimedActions/ISRemoveFlashlightAction.lua
-- ============================================================================
-- PURPOSE: Timed action for uninstalling a cart's flashlight upgrade.
--          Returns the original light item (and any remaining battery charge).
--
-- CONTEXT: SHARED (client + server)
--          Must be in shared/ for MP timed action sync to work.
--
-- KEY: Store serializable data (IDs, coordinates, booleans) not object refs.
--      Object references may not survive client->server serialization.
--
-- DESIGN:
--   - Reverses ISInstallFlashlightAction. The attachment material (tape/ties)
--     is NOT returned - it was consumed getting the light on there.
--   - The returned item is rebuilt from flashlightData.originalType, so it
--     comes back stock: no weapon parts, no ammo, default condition. That is
--     a deliberate floor, not a full restore - we never stored those.
--   - Remaining charge comes back as a separate Base.Battery, matching
--     ISRemoveBatteryAction, so a depleted light doesn't silently eat it.
--   - Item creation is server-authoritative (see perform()).
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"

-- MUST be global for MP action type registration
ISRemoveFlashlightAction = ISBaseTimedAction:derive("ISRemoveFlashlightAction")
ISRemoveFlashlightAction.Type = "ISRemoveFlashlightAction"

--- Fallback when the stored originalType no longer resolves (mod uninstalled,
--- item renamed between builds). Better a plain torch than nothing at all.
local FALLBACK_TYPE = "Base.Torch"

-- ============================================================================
-- VALIDATION
-- ============================================================================

function ISRemoveFlashlightAction:isValid()
    -- If already completed, stay valid
    if self.completed then
        return true
    end

    -- Re-find cart
    local cart = self:findCart()
    if not cart then
        return false
    end

    -- Cart must actually have a flashlight to remove
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

function ISRemoveFlashlightAction:waitToStart()
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

function ISRemoveFlashlightAction:start()
    local cart = self:findCart()
    if cart then
        cart:setJobType(getText("UI_SaucedCarts_RemoveFlashlight") or "Remove Flashlight")
        cart:setJobDelta(0.0)
    end

    -- Use crafting animation
    self:setActionAnim("Craft")
    self.character:reportEvent("EventCraftItem")

    -- Same tape/ties sound as installing, played in reverse spirit
    self.sound = self.character:playSound("FixWithTape")
end

function ISRemoveFlashlightAction:update()
    local cart = self:findCart()
    if cart then
        cart:setJobDelta(self:getJobDelta())
    end
end

function ISRemoveFlashlightAction:stop()
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

function ISRemoveFlashlightAction:perform()
    self.completed = true

    local cart = self:findCart()
    if not cart then
        SaucedCarts.debug("ISRemoveFlashlightAction: cart not found in perform()")
        return
    end

    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        SaucedCarts.debug("ISRemoveFlashlightAction: cart has no flashlight upgrade")
        return
    end

    -- If the light is on, kill it and tell the other clients before we tear
    -- down the ModData that told them it was on.
    local wasLightActive = SaucedCarts.Upgrades.isLightActive(cart)
    if wasLightActive and isServer() then
        SaucedCarts.Network.broadcast("cartLightUpdate", {
            playerOnlineId = self.character:getOnlineID(),
            cartId = cart:getID(),
            isActive = false,
        })
    end

    local flashlightData, batteryCharge = SaucedCarts.Upgrades.removeFlashlight(cart)
    local returnedType = (flashlightData and flashlightData.originalType) or FALLBACK_TYPE

    -- V4 guard: B42 replays timed actions in BOTH the client and server VMs.
    -- If each one ran instanceItem the player would get two flashlights. The
    -- server is authoritative; its sendAddItemToContainer delivers the item to
    -- the client. isClient() is false in SP and on the dedicated server, true
    -- on any MP client including a co-op host.
    if not isClient() then
        local inv = self.character:getInventory()

        local returned = instanceItem(returnedType)
        if not returned and returnedType ~= FALLBACK_TYPE then
            SaucedCarts.debug(function() return
                "ISRemoveFlashlightAction: " .. tostring(returnedType) ..
                " no longer resolves, falling back to " .. FALLBACK_TYPE end)
            returned = instanceItem(FALLBACK_TYPE)
        end

        if returned then
            -- Comes back empty: the charge is handed over as a battery below so
            -- the two removal paths (light vs battery) stay consistent.
            if returned.setCurrentUsesFloat then
                returned:setCurrentUsesFloat(0)
            end
            inv:AddItem(returned)
            sendAddItemToContainer(inv, returned)
        else
            SaucedCarts.error("ISRemoveFlashlightAction: could not instance " .. tostring(returnedType))
        end

        if batteryCharge and batteryCharge > 0 then
            local battery = instanceItem("Base.Battery")
            if battery then
                battery:setCurrentUsesFloat(batteryCharge)
                battery:setCondition(battery:getConditionMax())
                inv:AddItem(battery)
                sendAddItemToContainer(inv, battery)
            end
        end
    end

    -- Update cart visual model (back to the un-upgraded model). force=true:
    -- the removal is a known repaint, don't trust the differ's memo.
    -- .log (not .debug) on purpose: rare action, and the applied-model +
    -- placement facts are exactly what's needed to triage "mesh didn't
    -- swap when the action ended" reports from normal logs.
    if SaucedCarts.updateCartVisual then
        local repainted = SaucedCarts.updateCartVisual(cart, self.character, true)
        SaucedCarts.log(string.format(
            "RemoveFlashlight: repaint=%s model=%s ground=%s equipped=%s",
            tostring(repainted), tostring(cart:getStaticModel()),
            tostring(cart:getWorldItem() ~= nil),
            tostring(self.character and self.character:getPrimaryHandItem() == cart)))
    end

    -- Fire event (for local listeners)
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onFlashlightRemoved, self.character, cart, returnedType)
    end

    -- Sync item state (only for equipped carts)
    -- syncItemModData fails for world items (container not replicated to clients)
    if isServer() and not self.isGroundCart then
        syncItemModData(self.character, cart)
        syncItemFields(self.character, cart)
    end

    -- MP: reuse the upgradeInstalled broadcast so every client refreshes the
    -- hand/world model. The handler clears the cached upgrade key and re-reads
    -- ModData, which now says "no flashlight".
    if isServer() then
        SaucedCarts.Network.broadcast("upgradeInstalled", {
            playerOnlineId = self.character:getOnlineID(),
            cartId = cart:getID(),
            upgradeType = "flashlightRemoved",
            newUpgradeKey = nil,
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
function ISRemoveFlashlightAction:findCart()
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

--- Create a new remove flashlight action
--- CRITICAL: Only primitive types in constructor for MP serialization
---@param character IsoPlayer The player performing the action
---@param cartId number The cart's item ID
---@param squareX number|nil X coordinate if cart is on ground
---@param squareY number|nil Y coordinate if cart is on ground
---@param squareZ number|nil Z coordinate if cart is on ground
function ISRemoveFlashlightAction:new(character, cartId, squareX, squareY, squareZ)
    local o = ISBaseTimedAction.new(self, character)

    -- Serializable primitives only
    o.cartId = cartId
    o.squareX = squareX
    o.squareY = squareY
    o.squareZ = squareZ
    o.isGroundCart = (squareX ~= nil)

    -- Action properties
    o.maxTime = 220  -- ~3.7s, faster than the 330 it takes to install
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
---@return ISRemoveFlashlightAction
function ISRemoveFlashlightAction.FromCart(character, cart)
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

    return ISRemoveFlashlightAction:new(
        character,
        cart:getID(),
        squareX, squareY, squareZ
    )
end

SaucedCarts.debug("ISRemoveFlashlightAction loaded")
