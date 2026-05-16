-- ============================================================================
-- SaucedCarts/ContainerRestrictions.lua
-- ============================================================================
-- PURPOSE: Restrict carts to specific containers - blocks transfers to bags,
--          backpacks, furniture, and other non-vehicle containers. Carts can
--          exist in player's main inventory, on the ground, or in vehicles.
--
-- CONTEXT: SHARED (client + server)
--          CRITICAL: This file runs on BOTH client and server for MP safety.
--          The server validates all transfers, so even hacked clients cannot
--          bypass these restrictions.
--
-- MULTIPLAYER SAFETY:
--   - isItemAllowed hook runs on server, providing authoritative validation
--   - Client hooks are for UX only (notifications) - server is authoritative
--   - All hooks use pcall to never break vanilla functionality
--
-- LAYERS:
--   1. isItemAllowed hook - Server-authoritative container validation
--   2. ISUnequipAction hook - Force drop on unequip (runs in complete())
--
-- LOAD ORDER: This file is loaded by Core.lua - SaucedCarts namespace already exists.
--             Do NOT add require "SaucedCarts/Core" here (causes recursive require warning).
-- ============================================================================

require "SaucedCarts/Durability"

---@class SaucedCartsContainerRestrictions
local ContainerRestrictions = {}

-- ============================================================================
-- SAFE HELPER FUNCTIONS
-- ============================================================================

-- Note: SaucedCarts.safeIsCart() is now centralized in Core.lua as SaucedCarts.SaucedCarts.safeIsCart()

--- Safely get container parent
---@param container ItemContainer
---@return any|nil
local function safeGetParent(container)
    if not container then return nil end

    local success, result = pcall(function()
        return container:getParent()
    end)

    if not success then
        return nil
    end

    return result
end

--- Check if a vehicle container has room for a cart
--- Uses PZ's native weight-based capacity check pattern
---@param container ItemContainer The destination vehicle container
---@param item InventoryItem The cart being transferred
---@return boolean True if there is enough capacity
local function vehicleContainerHasRoom(container, item)
    if not container or not item then return true end  -- Fail-safe: allow

    local success, hasRoom = pcall(function()
        -- getUnequippedWeight() = base weight + contents weight (with weight reduction applied)
        local cartWeight = item:getUnequippedWeight()
        local usedCapacity = container:getCapacityWeight()
        local maxCapacity = container:getCapacity()

        local wouldExceed = (cartWeight + usedCapacity) > maxCapacity

        if wouldExceed then
            SaucedCarts.debug(function() return string.format(
                "Vehicle capacity check: cart=%.1f, used=%.1f, max=%d - BLOCKED",
                cartWeight, usedCapacity, maxCapacity
            ) end)
        end

        return not wouldExceed
    end)

    if not success then
        SaucedCarts.debug("vehicleContainerHasRoom error - allowing transfer")
        return true  -- Fail-safe: allow (server validates anyway)
    end

    return hasRoom
end

-- ============================================================================
-- LAYER 1: CONTAINER-LEVEL HOOK (SERVER-AUTHORITATIVE)
-- ============================================================================
-- Hook ItemContainer.isItemAllowed() to block carts from non-player containers.
-- This runs on BOTH client and server - the server validation is authoritative.

local containerHookInitialized = false

local function initContainerRestrictions()
    if containerHookInitialized then
        SaucedCarts.debug("Container restrictions already initialized, skipping")
        return
    end

    -- Get the ItemContainer metatable
    local containerMeta = __classmetatables[ItemContainer.class]
    if not containerMeta then
        SaucedCarts.error("Could not find ItemContainer metatable - container restrictions NOT initialized")
        return
    end

    -- Store original function
    local originalIsItemAllowed = containerMeta.__index.isItemAllowed
    if not originalIsItemAllowed then
        SaucedCarts.error("ItemContainer.isItemAllowed not found - container restrictions NOT initialized")
        return
    end

    containerMeta.__index.isItemAllowed = function(self, item)
        -- Wrap our logic in pcall - NEVER break vanilla isItemAllowed
        local shouldBlock = false

        local checkSuccess = pcall(function()
            -- Only check SaucedCarts carts
            if SaucedCarts.safeIsCart(item) then
                -- FIRST: Check container type - most reliable for floor/vehicle detection
                -- This is critical for mod compatibility (e.g., Inventory Tetris) where
                -- the parent object might be unexpected but container type is always correct.
                local containerType = self:getType()
                if containerType then
                    local typeLower = string.lower(containerType)
                    if typeLower == SaucedCarts.ContainerTypes.FLOOR then
                        -- Floor container always allows carts (drop operations)
                        shouldBlock = false
                        SaucedCarts.debug(function() return "isItemAllowed: allowing cart to floor (type check)" end)
                        return  -- Early exit - floor is always allowed
                    elseif SaucedCarts.isVehicleContainerType(containerType) then
                        -- Vehicle container detected by type name - check capacity
                        if vehicleContainerHasRoom(self, item) then
                            shouldBlock = false
                            SaucedCarts.debug(function() return "isItemAllowed: allowing cart to vehicle container (type: " .. containerType .. ")" end)
                        else
                            shouldBlock = true
                            SaucedCarts.debug(function() return "isItemAllowed: blocking cart - vehicle at capacity (type: " .. containerType .. ")" end)
                        end
                        return  -- Early exit - vehicle check complete
                    end
                end

                -- SECOND: Check parent type for player inventory and other cases
                local parent = safeGetParent(self)

                -- Carts can go to:
                -- 1. Ground (IsoGridSquare parent) - drop operations
                -- 2. Player's main inventory (IsoPlayer parent) - pickup/equip operations
                -- 3. Vehicle containers (BaseVehicle parent) - trunk/glovebox storage
                -- Block: bags, backpacks, furniture, etc.
                if instanceof(parent, "IsoGridSquare") then
                    -- Ground is allowed - this is a drop operation
                    shouldBlock = false
                elseif instanceof(parent, "IsoPlayer") then
                    -- Player's main inventory is allowed - needed for pickup/equip
                    shouldBlock = false
                elseif instanceof(parent, "BaseVehicle") then
                    -- Vehicle containers allowed if there's capacity
                    if vehicleContainerHasRoom(self, item) then
                        shouldBlock = false
                    else
                        shouldBlock = true
                    end
                elseif instanceof(parent, "VehiclePart") then
                    -- Vehicle part containers (mods) - also check capacity
                    if vehicleContainerHasRoom(self, item) then
                        shouldBlock = false
                    else
                        shouldBlock = true
                    end
                else
                    -- Everything else is blocked (bags, backpacks, furniture, etc.)
                    shouldBlock = true
                    SaucedCarts.debug(function() return "isItemAllowed: blocking cart transfer to " .. tostring(parent) .. " (type: " .. tostring(containerType) .. ")" end)
                end
            end
        end)

        if not checkSuccess then
            -- On error, allow transfer (fail-safe)
            SaucedCarts.debug("isItemAllowed check error - allowing transfer")
            shouldBlock = false
        end

        if shouldBlock then
            return false
        end

        -- Chain to original function (maintains mod compatibility)
        return originalIsItemAllowed(self, item)
    end

    containerHookInitialized = true
    SaucedCarts.debug("Container restrictions initialized (server-authoritative)")
end

-- ============================================================================
-- LAYER 2: FORCE DROP ON UNEQUIP
-- ============================================================================
-- Hook ISUnequipAction.complete to force-drop carts instead of keeping in inventory.
-- complete() runs on the server in MP - this is where state changes happen.

local unequipHookInitialized = false

local function initUnequipHook()
    if unequipHookInitialized then
        SaucedCarts.debug("Unequip hook already initialized, skipping")
        return
    end

    -- Ensure ISUnequipAction exists
    if not ISUnequipAction then
        SaucedCarts.debug("ISUnequipAction not found - unequip hook skipped (may load later)")
        return
    end

    local originalComplete = ISUnequipAction.complete
    if not originalComplete then
        SaucedCarts.error("ISUnequipAction.complete not found - unequip hook NOT initialized")
        return
    end

    ISUnequipAction.complete = function(self)
        -- Wrap our logic in pcall - NEVER break vanilla unequip
        local shouldForceDrop = false
        local forceDropSuccess = false
        local hasPendingTransfer = false

        pcall(function()
            -- Check if unequipping a SaucedCarts cart
            if self.item and SaucedCarts.safeIsCart(self.item) and self.character then
                -- On client, check if there's a pending valid transfer (e.g., to vehicle)
                -- This allows drag-to-vehicle to work without force-dropping
                if not isServer() then
                    local cartId = self.item:getID()
                    if SaucedCarts.TransferRestrictions and
                       SaucedCarts.TransferRestrictions.hasPendingTransfer and
                       SaucedCarts.TransferRestrictions.hasPendingTransfer(cartId) then
                        SaucedCarts.debug("Cart has pending valid transfer - skipping force-drop")
                        SaucedCarts.TransferRestrictions.clearPendingTransfer(cartId)
                        hasPendingTransfer = true
                        return
                    end
                end

                SaucedCarts.debug("Intercepted cart unequip - will force drop")
                shouldForceDrop = true
            end
        end)

        -- If cart has a pending valid transfer, let vanilla handle it
        if hasPendingTransfer then
            return originalComplete(self)
        end

        if shouldForceDrop then
            -- MP CLIENT: never create the world item here. This file is
            -- SHARED, so in MP the timed-action lifecycle runs complete() on
            -- BOTH the client and the server; each would call
            -- AddWorldInventoryItem and the player ends up with two carts
            -- (reported "unequipped and it duplicated in place"). Delegate to
            -- the same server-authoritative drop InstantDrop.handle uses.
            -- Do NOT clear the action queue (clearing mid-tick triggers
            -- vanilla's "bugged action" freeze — see InstantDrop.lua).
            if isClient() and self.character:getOnlineID() then
                pcall(function()
                    local md = self.item:getModData()
                    if SaucedCarts.Network and SaucedCarts.Network.sendToServer then
                        SaucedCarts.Network.sendToServer(self.character,
                            "requestInstantDrop", {
                                cartId = self.item:getID(),
                                distancePushed = (md and md.SaucedCarts_distancePushed) or 0,
                            })
                    end
                    self.character:setVariable("Weapon", "")
                    self.character:setVariable("RightHandMask", "")
                    self.character:setVariable("LeftHandMask", "")
                end)
                SaucedCarts.debug("Cart unequip - delegated to server (MP-safe, no client-side drop)")
                pcall(function() ISBaseTimedAction.perform(self) end)
                return
            end

            -- Idempotence guard: if the cart is already a world item, a drop
            -- already happened (complete() ran twice, or a racing
            -- requestInstantDrop beat us). Do NOT create a second world item.
            local alreadyDropped = false
            pcall(function()
                alreadyDropped = self.item:getWorldItem() ~= nil
            end)
            if alreadyDropped then
                SaucedCarts.debug("Cart already on ground during unequip - skipping duplicate drop")
                pcall(function() ISBaseTimedAction.perform(self) end)
                return
            end

            -- SP / dedicated-server: perform the authoritative MP-safe drop.
            local dropSuccess = pcall(function()
                local character = self.character
                local item = self.item
                local square = character:getCurrentSquare()

                if not square then
                    SaucedCarts.debug("No square for cart drop - aborting")
                    return
                end

                -- Apply accumulated durability damage before drop
                local newCondition = SaucedCarts.Durability.applyAccumulatedDamage(item)

                if newCondition <= 0 then
                    -- Cart broke - drop contents and destroy
                    SaucedCarts.Durability.dropContentsAndDestroy(item, character, square)

                    -- Remove from hands and inventory
                    character:removeFromHands(item)
                    character:getInventory():Remove(item)
                    sendRemoveItemFromContainer(character:getInventory(), item)

                    -- Notify player (client only)
                    if not isServer() and SaucedCarts.Notifications then
                        SaucedCarts.Notifications.cartBroke(character)
                    end

                    -- Fire broke event
                    if SaucedCarts._fireEvent then
                        SaucedCarts._fireEvent(SaucedCarts.Events.onCartBroke, character, item, square)
                    end

                    forceDropSuccess = true
                    SaucedCarts.debug("Cart broke on unequip - items dropped")
                    return
                end

                -- Show low condition warning if applicable (25% threshold)
                local conditionMax = item:getConditionMax()
                if not isServer() and conditionMax > 0 and newCondition <= math.floor(conditionMax * 0.25) then
                    if SaucedCarts.Notifications then
                        SaucedCarts.Notifications.cartDamaged(character)
                    end
                end

                -- Remove from hands first
                character:removeFromHands(item)

                -- Remove from inventory with MP sync
                character:getInventory():Remove(item)
                sendRemoveItemFromContainer(character:getInventory(), item)

                -- Add to world with auto-transmit (5th param = true)
                -- NOTE: Do NOT call transmitCompleteItemToClients() after this - the 5th param
                -- already handles transmission. Double-transmit causes duplicates in self-hosted MP.
                local worldItem = square:AddWorldInventoryItem(item, 0, 0, 0, true)

                -- Fire drop event
                if SaucedCarts._fireEvent then
                    SaucedCarts._fireEvent(SaucedCarts.Events.onCartDrop, character, item, square)
                end

                -- Update visual state for dropped cart (syncs to all clients)
                SaucedCarts.updateCartVisual(item, character)

                forceDropSuccess = true
                SaucedCarts.debug(function() return "Cart dropped to ground with MP sync (condition: " .. newCondition .. ")" end)
            end)

            if forceDropSuccess then
                -- We handled everything - just end the action properly
                pcall(function()
                    ISBaseTimedAction.perform(self)
                end)
                return
            else
                -- CRITICAL: Do NOT fall through to original on drop failure.
                -- Falling through would allow the cart to remain in inventory,
                -- bypassing our container restrictions. Instead, fail the action
                -- silently - the cart stays equipped (user can try again).
                SaucedCarts.error("Cart drop failed during unequip - action blocked to maintain restriction")
                pcall(function()
                    ISBaseTimedAction.perform(self)
                end)
                return
            end
        end

        -- Chain to original for non-carts only
        return originalComplete(self)
    end

    unequipHookInitialized = true
    SaucedCarts.debug("Unequip hook initialized")
end

-- ============================================================================
-- LAYER 3: DROP ACTION HOOK (DURABILITY ON VANILLA DROP)
-- ============================================================================
-- Hook ISDropWorldItemAction.complete to apply durability damage when carts are dropped.
-- This catches vanilla "Drop" action from inventory context menu.

local dropActionHookInitialized = false

local function initDropActionHook()
    if dropActionHookInitialized then
        SaucedCarts.debug("Drop action hook already initialized, skipping")
        return
    end

    -- Ensure ISDropWorldItemAction exists
    if not ISDropWorldItemAction then
        SaucedCarts.debug("ISDropWorldItemAction not found - drop hook skipped (may load later)")
        return
    end

    local originalComplete = ISDropWorldItemAction.complete
    if not originalComplete then
        SaucedCarts.error("ISDropWorldItemAction.complete not found - drop hook NOT initialized")
        return
    end

    -- Wrap isValid to bypass vanilla's 50kg floor-weight gate for carts.
    -- Vanilla's check (`ground + item:getUnequippedWeight() > 50 -> invalid`)
    -- treats a loaded cart as indistinguishable from "loose items on the
    -- floor" — so a cart full of rescue-run loot is rejected the moment
    -- the user presses V / selects Drop, and the action queue clears as
    -- "bugged". Carts are wheeled containers, not pile-of-loose-items;
    -- the floor cap shouldn't apply. Same class of carve-out as the
    -- container-restriction fix that stopped the floor cap from rejecting
    -- items going INTO a ground cart.
    local originalIsValid = ISDropWorldItemAction.isValid
    if originalIsValid then
        ISDropWorldItemAction.isValid = function(self)
            local isCart = false
            pcall(function()
                isCart = self.item and SaucedCarts.safeIsCart(self.item)
            end)
            if not isCart then
                return originalIsValid(self)
            end

            local playerSq = self.character and self.character:getCurrentSquare()
            if self.isPlaceItem and playerSq ~= nil
                and (not self.sq:isAdjacentTo(playerSq) or self.sq:isBlockedTo(playerSq)) then
                return false
            end

            local inv = self.character:getInventory()
            if not inv then return false end
            if isClient() and self.item then
                return inv:containsID(self.item:getID())
            end
            return inv:contains(self.item)
        end
    end

    ISDropWorldItemAction.complete = function(self)
        -- Check if dropping a SaucedCarts cart
        local isCart = false
        pcall(function()
            isCart = self.item and SaucedCarts.safeIsCart(self.item)
        end)

        if isCart then
            -- Wrap durability logic in pcall - never break vanilla drop
            local cartBroke = false
            pcall(function()
                local square = self.character and self.character:getCurrentSquare()
                if square then
                    -- Apply accumulated durability damage before drop
                    local newCondition = SaucedCarts.Durability.applyAccumulatedDamage(self.item)

                    if newCondition <= 0 then
                        -- Cart broke - drop contents and destroy
                        SaucedCarts.Durability.dropContentsAndDestroy(self.item, self.character, square)

                        -- Remove from hands and inventory (action expects item to be gone)
                        self.character:removeFromHands(self.item)
                        self.character:getInventory():Remove(self.item)
                        sendRemoveItemFromContainer(self.character:getInventory(), self.item)

                        -- Notify player (client only)
                        if not isServer() and SaucedCarts.Notifications then
                            SaucedCarts.Notifications.cartBroke(self.character)
                        end

                        -- Fire broke event
                        if SaucedCarts._fireEvent then
                            SaucedCarts._fireEvent(SaucedCarts.Events.onCartBroke, self.character, self.item, square)
                        end

                        cartBroke = true
                        SaucedCarts.debug("Cart broke on vanilla drop - items dropped")
                    else
                        -- Show low condition warning if applicable (25% threshold)
                        local conditionMax = self.item:getConditionMax()
                        if not isServer() and conditionMax > 0 and newCondition <= math.floor(conditionMax * 0.25) then
                            if SaucedCarts.Notifications then
                                SaucedCarts.Notifications.cartDamaged(self.character)
                            end
                        end
                        SaucedCarts.debug(function() return "Vanilla drop - durability applied (condition: " .. newCondition .. ")" end)
                    end
                end
            end)

            if cartBroke then
                -- Cart was destroyed - skip original drop, just end the action
                pcall(function()
                    ISBaseTimedAction.perform(self)
                end)
                return
            end
        end

        -- Chain to original for normal behavior (carts that didn't break + non-carts)
        local result = originalComplete(self)

        -- Fire drop event for carts that didn't break (now on ground)
        if isCart and not cartBroke then
            pcall(function()
                local square = self.character and self.character:getCurrentSquare()
                if square and SaucedCarts._fireEvent then
                    SaucedCarts._fireEvent(SaucedCarts.Events.onCartDrop, self.character, self.item, square)
                end
                -- Update visual state for dropped cart (syncs to all clients)
                SaucedCarts.updateCartVisual(self.item, self.character)
            end)
        end

        return result
    end

    dropActionHookInitialized = true
    SaucedCarts.debug("Drop action hook initialized")
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function onGameStart()
    initContainerRestrictions()
    initUnequipHook()
    initDropActionHook()
end

-- Register initialization event
Events.OnGameStart.Add(onGameStart)

-- ============================================================================
-- DEBUG API
-- ============================================================================

--- Test if container restrictions are active
---@return boolean True if restrictions are initialized
function ContainerRestrictions.isInitialized()
    return containerHookInitialized
end

--- Test if unequip hook is active
---@return boolean
function ContainerRestrictions.isUnequipHookInitialized()
    return unequipHookInitialized
end

--- Test container restriction by checking if a cart would be allowed in a bag
--- For debug purposes only
---@param player IsoPlayer The player to test with
---@return string Result message
function ContainerRestrictions.testRestriction(player)
    if not player then
        return "No player provided"
    end

    if not containerHookInitialized then
        return "Container restrictions NOT initialized"
    end

    -- Check if player has a cart
    local cart = SaucedCarts.getHeldCart(player)
    if not cart then
        return "Player not holding a cart - equip a cart first to test"
    end

    -- Try to find a bag in inventory
    local inventory = player:getInventory()
    if not inventory then
        return "Could not access player inventory"
    end

    local items = inventory:getItems()
    local testBag = nil

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if instanceof(item, "InventoryContainer") and not SaucedCarts.safeIsCart(item) then
            testBag = item
            break
        end
    end

    if not testBag then
        return "No bag found in inventory to test with"
    end

    -- Test if cart is allowed in the bag
    local bagContainer = testBag:getItemContainer()
    if not bagContainer then
        return "Could not access bag container"
    end

    local allowed = bagContainer:isItemAllowed(cart)

    if allowed then
        return "FAILED: Cart was allowed in bag (restriction not working)"
    else
        return "SUCCESS: Cart blocked from bag container"
    end
end

-- Export for debug access
SaucedCarts.ContainerRestrictions = ContainerRestrictions

-- Test hooks (exposed for pz-test-kit — not part of the public API).
SaucedCarts.ContainerRestrictions.initDropActionHook = initDropActionHook

SaucedCarts.debug("ContainerRestrictions module loaded")

return ContainerRestrictions
