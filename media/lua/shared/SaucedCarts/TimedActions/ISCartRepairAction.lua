-- ============================================================================
-- SaucedCarts/TimedActions/ISCartRepairAction.lua
-- ============================================================================
-- PURPOSE: Timed action for repairing a cart using repair materials.
--          Follows ISCartPickupAction pattern for MP compatibility.
--
-- CONTEXT: SHARED (client + server)
--          Must be in shared/ for MP timed action sync to work.
--
-- KEY: Store serializable data (IDs, coordinates, booleans) not object refs.
--      Object references may not survive client->server serialization.
--
-- DESIGN:
--   - Repair materials can be in player inventory OR cart contents
--   - Condition change happens only in complete() (server-authoritative)
--   - Material is consumed only on successful repair
--   - Uses CartData registration for repairItem/repairAmount
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"
require "SaucedCarts/RepairSync"

-- MUST be global for MP action type registration
ISCartRepairAction = ISBaseTimedAction:derive("ISCartRepairAction")
ISCartRepairAction.Type = "ISCartRepairAction"

-- ============================================================================
-- VALIDATION
-- ============================================================================

function ISCartRepairAction:isValid()
    -- If already completed, stay valid
    if self.completed then
        return true
    end

    -- Re-find cart and repair item
    local cart = self:findCart()
    if not cart then
        return false
    end

    local repairItem = self:findRepairItem()
    if not repairItem then
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

function ISCartRepairAction:waitToStart()
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

function ISCartRepairAction:start()
    local cart = self:findCart()
    if cart then
        cart:setJobType(getText("UI_SaucedCarts_RepairCart") or "Repair Cart")
        cart:setJobDelta(0.0)
    end

    -- Use crafting animation
    self:setActionAnim("Craft")
    self.character:reportEvent("EventCraftItem")

    -- Play repair sound
    self.sound = self.character:playSound("Hammering")
end

function ISCartRepairAction:update()
    local cart = self:findCart()
    if cart then
        cart:setJobDelta(self:getJobDelta())
    end

    -- Face ground cart during repair
    if self.isGroundCart then
        if cart then
            local worldItem = cart:getWorldItem()
            if worldItem then
                self.character:faceThisObject(worldItem)
            end
        end
    end

    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function ISCartRepairAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end

    local cart = self:findCart()
    if cart then
        cart:setJobDelta(0.0)
    end

    ISBaseTimedAction.stop(self)
end

function ISCartRepairAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end

    local cart = self:findCart()
    if cart then
        cart:setJobDelta(0.0)
    end

    ISBaseTimedAction.perform(self)
end

-- ============================================================================
-- COMPLETE - Server-authoritative state changes
-- ============================================================================

function ISCartRepairAction:complete()
    -- For ground carts in MP client (not self-hosted), skip state changes.
    -- The server handles all modifications and syncs back to client.
    -- This prevents duplication from both client and server modifying the world item.
    local isPureClient = isClient() and not isServer()
    if self.isGroundCart and isPureClient then
        -- Client just shows notification - server handles actual repair
        if SaucedCarts.Notifications then
            SaucedCarts.Notifications.success(self.character,
                getText("UI_SaucedCarts_CartRepaired") or "Cart repaired!",
                "cart_repaired")
        end
        self.completed = true
        SaucedCarts.debug("Ground cart repair - client deferring to server")
        return true
    end

    -- Re-find cart
    local cart = self:findCart()
    if not cart then
        SaucedCarts.error("Repair failed: cart not found (ID: " .. tostring(self.cartId) .. ")")
        return false
    end

    -- Re-find repair item
    local repairItem = self:findRepairItem()
    if not repairItem then
        SaucedCarts.error("Repair failed: repair item not found (ID: " .. tostring(self.repairItemId) .. ")")
        return false
    end

    -- Get CartData repair parameters (with defaults for unregistered carts)
    local cartData = SaucedCarts.getCartData(cart)
    local baseRepairAmount = (cartData and cartData.repairAmount) or 10
    local repairSkillBonus = (cartData and cartData.repairSkillBonus) or 1
    local repairXpGain = (cartData and cartData.repairXpGain) or 3
    -- Resolve repairSkill: nil defaults to Perks.Maintenance at runtime
    local repairSkill = (cartData and cartData.repairSkill) or Perks.Maintenance

    -- Get sandbox options
    local repairAmountMult = SandboxVars.SaucedCarts.RepairAmountMultiplier or 100
    local skillBonusEnabled = SandboxVars.SaucedCarts.MaintenanceSkillBonus
    if skillBonusEnabled == nil then skillBonusEnabled = true end

    -- Calculate skill contribution
    local skillLevel = 0
    local skillContribution = 0
    if skillBonusEnabled and repairSkill then
        skillLevel = self.character:getPerkLevel(repairSkill)
        skillContribution = skillLevel * repairSkillBonus
    end

    -- Calculate final repair amount
    -- Formula: floor((baseRepairAmount + skillContribution) * repairAmountMult / 100)
    local finalRepairAmount = math.floor((baseRepairAmount + skillContribution) * repairAmountMult / 100)
    -- Ensure at least 1 condition is restored (if player has materials, give them something)
    finalRepairAmount = math.max(1, finalRepairAmount)

    -- Calculate new condition
    local currentCondition = cart:getCondition()
    local maxCondition = cart:getConditionMax()
    local newCondition = math.min(maxCondition, currentCondition + finalRepairAmount)
    local actualRepair = newCondition - currentCondition

    -- Apply condition change (SERVER-AUTHORITATIVE)
    cart:setCondition(newCondition)

    -- Track repair count (int - increments each time item is repaired)
    cart:setHaveBeenRepaired(cart:getHaveBeenRepaired() + 1)

    -- Reset distance accumulator so repair gives a fresh start
    cart:getModData().SaucedCarts_distancePushed = 0

    -- Reset the threshold-halo marker so the player gets fresh creak/
    -- damaged/failing warnings on the next damage cycle (otherwise we'd
    -- skip warnings that the cart already crossed pre-repair).
    if SaucedCarts.Durability and SaucedCarts.Durability.resetThresholdMarker then
        SaucedCarts.Durability.resetThresholdMarker(cart)
    end

    -- Fire repair event
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onCartRepair, self.character, cart, actualRepair, newCondition)
    end

    -- Consume repair material
    local repairItemContainer = repairItem:getContainer()
    if repairItemContainer then
        repairItemContainer:DoRemoveItem(repairItem)
        sendRemoveItemFromContainer(repairItemContainer, repairItem)
    end

    -- Award XP if skill bonus is enabled and repair actually happened
    if skillBonusEnabled and actualRepair > 0 and repairXpGain > 0 and repairSkill then
        self.character:getXp():AddXP(repairSkill, repairXpGain)
    end

    -- MP sync for inventory carts
    -- Note: Ground cart sync is handled by onCartRepair event → broadcast in UpgradeSync.lua
    if isServer() and not self.isGroundCart then
        if self.character then
            syncItemFields(self.character, cart)
        end
    end

    -- Notify player and refresh UI (client only, for non-ground carts or SP/self-hosted)
    if not isServer() then
        if SaucedCarts.Notifications then
            SaucedCarts.Notifications.success(self.character,
                getText("UI_SaucedCarts_CartRepaired") or "Cart repaired!",
                "cart_repaired")
        end

        -- Refresh inventory UI to show updated condition
        self.character:getInventory():setDrawDirty(true)
        if getPlayerData then
            local pdata = getPlayerData(self.character:getPlayerNum())
            if pdata then
                pdata.playerInventory:refreshBackpacks()
                pdata.lootInventory:refreshBackpacks()
            end
        end
    end

    -- Mark completed
    self.completed = true

    SaucedCarts.debug(function() return string.format("Cart repaired: %d -> %d (+%d) | base=%d skill=+%d mult=%d%% | XP=%d",
        currentCondition, newCondition, actualRepair,
        baseRepairAmount, skillContribution, repairAmountMult,
        skillBonusEnabled and repairXpGain or 0) end)

    return true
end

-- ============================================================================
-- DURATION
-- ============================================================================

function ISCartRepairAction:getDuration()
    if self.character and self.character:isTimedActionInstant() then
        return 1
    end

    -- Get cart to access CartData (may be nil during early construction)
    local cart = self:findCart()
    local cartData = cart and SaucedCarts.getCartData(cart)

    -- Get base time from CartData (default 100 ticks)
    local baseTime = (cartData and cartData.repairTimeBase) or 100
    -- Resolve repairSkill: nil defaults to Perks.Maintenance at runtime
    local repairSkill = (cartData and cartData.repairSkill) or Perks.Maintenance

    -- Get sandbox options
    local repairTimeMult = SandboxVars.SaucedCarts.RepairTimeMultiplier or 100
    local skillBonusEnabled = SandboxVars.SaucedCarts.MaintenanceSkillBonus
    if skillBonusEnabled == nil then skillBonusEnabled = true end

    -- Calculate skill-based time reduction
    -- Each skill level reduces time by 5 ticks, max 50% reduction (10 levels = 50 ticks off 100 base)
    local skillReduction = 0
    if skillBonusEnabled and repairSkill and self.character then
        local skillLevel = self.character:getPerkLevel(repairSkill)
        -- 5 ticks reduction per level, capped at 50% of base time
        local maxReduction = math.floor(baseTime * 0.5)
        skillReduction = math.min(skillLevel * 5, maxReduction)
    end

    -- Calculate final duration
    -- Formula: max(10, floor((baseTime - skillReduction) * repairTimeMult / 100))
    local finalDuration = math.max(10, math.floor((baseTime - skillReduction) * repairTimeMult / 100))

    return finalDuration
end

-- ============================================================================
-- FIND HELPERS - Re-locate objects by stored IDs
-- ============================================================================

--- Find the cart by stored ID
--- Searches inventory for equipped carts, world for ground carts
---@return InventoryItem|nil
function ISCartRepairAction:findCart()
    -- For ground carts, search at stored coordinates
    if self.isGroundCart then
        local square = getCell():getGridSquare(self.squareX, self.squareY, self.squareZ)
        if not square then return nil end

        local objects = square:getWorldObjects()
        if not objects then return nil end

        for i = 0, objects:size() - 1 do
            local obj = objects:get(i)
            if instanceof(obj, "IsoWorldInventoryObject") then
                local item = obj:getItem()
                if item and item:getID() == self.cartId then
                    return item
                end
            end
        end
        return nil
    end

    -- For equipped/inventory carts, search player inventory
    local inv = self.character:getInventory()
    if not inv then return nil end

    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getID() == self.cartId then
            return item
        end
    end

    return nil
end

--- Find the repair item by stored ID
--- Searches player inventory and cart contents
---@return InventoryItem|nil
function ISCartRepairAction:findRepairItem()
    -- Search player inventory first
    local inv = self.character:getInventory()
    if inv then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:getID() == self.repairItemId then
                return item
            end
        end
    end

    -- Search cart contents
    local cart = self:findCart()
    if cart then
        local cartContainer = cart:getItemContainer()
        if cartContainer then
            local cartItems = cartContainer:getItems()
            for i = 0, cartItems:size() - 1 do
                local item = cartItems:get(i)
                if item:getID() == self.repairItemId then
                    return item
                end
            end
        end
    end

    return nil
end

-- ============================================================================
-- CONSTRUCTOR - Primitives only for MP serialization
-- ============================================================================

--- Create a new cart repair action
--- Pass serializable primitives: IDs, coordinates, booleans
---@param character IsoPlayer
---@param cartId number Cart item ID
---@param repairItemId number Repair material item ID
---@param isGroundCart boolean True if cart is on ground
---@param squareX number X coordinate (for ground carts)
---@param squareY number Y coordinate (for ground carts)
---@param squareZ number Z coordinate (for ground carts)
function ISCartRepairAction:new(character, cartId, repairItemId, isGroundCart, squareX, squareY, squareZ)
    local o = ISBaseTimedAction.new(self, character)

    -- Store serializable data directly (primitives serialize correctly in MP)
    o.cartId = cartId
    o.repairItemId = repairItemId
    o.isGroundCart = isGroundCart
    o.squareX = squareX or 0
    o.squareY = squareY or 0
    o.squareZ = squareZ or 0

    o.maxTime = o:getDuration()
    o.forceProgressBar = true
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true
    o.completed = false

    return o
end

-- ============================================================================
-- HELPER - Create from objects (client-side only)
-- ============================================================================

--- Helper to create action from cart and repair item objects
--- Extracts serializable primitives from objects
---@param character IsoPlayer
---@param cart InventoryItem The cart to repair
---@param repairItem InventoryItem The repair material
---@return ISCartRepairAction
function ISCartRepairAction.FromCart(character, cart, repairItem)
    local isGround = cart:getWorldItem() ~= nil
    local sq = isGround and cart:getWorldItem():getSquare() or nil

    return ISCartRepairAction:new(
        character,
        cart:getID(),
        repairItem:getID(),
        isGround,
        sq and sq:getX() or 0,
        sq and sq:getY() or 0,
        sq and sq:getZ() or 0
    )
end
