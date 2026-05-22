-- ============================================================================
-- SaucedCarts/Durability.lua
-- ============================================================================
-- PURPOSE: Cart durability system - distance-based degradation.
--          Damage is applied server-authoritatively on pickup (not continuously).
--
-- CONTEXT: SHARED (client + server)
--          Must be in shared/ for ISCartPickupAction to access.
--
-- DESIGN: Distance is accumulated in ModData while pushing (client-side).
--         On next pickup, ISCartPickupAction:complete() calls applyAccumulatedDamage()
--         which runs on the server, ensuring server-authoritative condition changes.
--
-- LOAD ORDER: This file is loaded by Core.lua (via ContainerRestrictions).
--             Do NOT add require "SaucedCarts/Core" here (causes recursive require warning).
--             Dedicated servers may load files in non-deterministic order,
--             so we defensively initialize the namespace.
-- ============================================================================

-- Defensive init: dedicated server LoadDirBase may load this before Core.lua
SaucedCarts = SaucedCarts or {}
SaucedCarts.Config = SaucedCarts.Config or {}

require "SaucedCarts/Upgrades"

SaucedCarts.Durability = {}

-- How many tiles of pushing before 1 condition is lost
-- Balance via DurabilityMultiplier sandbox setting (scales ConditionMax, not this)
-- Default: 110 tiles per 1 damage = 11000 tiles total lifespan at 100 ConditionMax
-- Fallback default guards against load-before-Core on dedicated servers
local TILES_PER_DAMAGE = SaucedCarts.Config.TILES_PER_DAMAGE or 110

-- Threshold halo levels (percent of max condition). Ordered low → high.
-- When a damage application crosses a threshold downward, fire the
-- corresponding halo once. modData tracks the lowest threshold fired so
-- we don't spam at every drop. Repair clears the marker so the player
-- gets fresh warnings on the next damage cycle.
local DAMAGE_THRESHOLDS = { 10, 25, 50 }

local function thresholdNotificationKey(threshold)
    if threshold == 50 then return "cartCreaking" end
    if threshold == 25 then return "cartDamaged"  end
    if threshold == 10 then return "cartFailing"  end
    return nil
end

--- Fire any threshold halo crossed by this damage application. Idempotent
--- per-threshold via modData marker; repair flow resets it.
---
--- Routes by VM context: SP/MP-client halos directly; MP-server sends a
--- per-threshold network command (cartCreaking / cartDamaged / cartFailing)
--- that the client handler in `CartState/AnimationSync/Notifications.lua`
--- receives and turns into a HaloTextHelper call. Same pattern as the
--- existing cartBroke/cartDamaged broadcasts.
local function fireThresholdHalos(cart, player, oldCondition, newCondition)
    if not player or not cart then return end
    local conditionMax = cart.getConditionMax and cart:getConditionMax() or 0
    if conditionMax <= 0 then return end

    local oldPct = oldCondition / conditionMax * 100
    local newPct = newCondition / conditionMax * 100
    local modData = cart:getModData()
    local lowestFired = modData.SaucedCarts_lastDamageThreshold or 100

    -- Find the strictest threshold we just crossed downward AND haven't
    -- already fired. Iterate low→high so the most-urgent halo wins when
    -- damage crosses multiple thresholds in one tick.
    for _, t in ipairs(DAMAGE_THRESHOLDS) do
        if newPct < t and oldPct >= t and t < lowestFired then
            modData.SaucedCarts_lastDamageThreshold = t
            local key = thresholdNotificationKey(t)
            if not key then return end

            if isServer() then
                if SaucedCarts.Network and SaucedCarts.Network.sendToClient then
                    pcall(function()
                        SaucedCarts.Network.sendToClient(player, key, {})
                    end)
                end
            else
                if SaucedCarts.Notifications and SaucedCarts.Notifications[key] then
                    pcall(function() SaucedCarts.Notifications[key](player) end)
                end
            end
            return  -- one halo per damage tick
        end
    end
end

--- Apply accumulated distance damage to cart
--- Called in ISCartPickupAction:complete() (server-authoritative)
---@param cart InventoryItem
---@param player IsoPlayer|nil Optional. When provided, threshold halos
---       (50% / 25% / 10%) fire once per crossing — caller doesn't need
---       to chase condition transitions; centralizing here covers both
---       the pickup and combat-drop paths.
---@return number newCondition The cart's condition after damage (0 = broke)
function SaucedCarts.Durability.applyAccumulatedDamage(cart, player)
    if not cart then return 0 end

    local modData = cart:getModData()
    local distancePushed = modData.SaucedCarts_distancePushed or 0

    -- No distance accumulated, no damage
    if distancePushed <= 0 then
        return cart:getCondition()
    end

    local damageAmount = math.floor(distancePushed / TILES_PER_DAMAGE)

    if damageAmount > 0 then
        local currentCondition = cart:getCondition()
        local newCondition = math.max(0, currentCondition - damageAmount)
        cart:setCondition(newCondition)

        -- Keep remainder for next time (partial tile progress)
        local remainder = distancePushed - (damageAmount * TILES_PER_DAMAGE)
        modData.SaucedCarts_distancePushed = remainder

        SaucedCarts.debug(function() return "Applied " .. damageAmount .. " damage, condition: " ..
            currentCondition .. " -> " .. newCondition .. ", remainder: " .. string.format("%.1f", remainder) end)

        -- Threshold halos: fire if we crossed 50% / 25% / 10% downward.
        fireThresholdHalos(cart, player, currentCondition, newCondition)

        return newCondition
    end

    -- Not enough distance for damage yet, keep accumulating
    return cart:getCondition()
end

--- Reset the threshold marker on a cart. Called by the repair flow so
--- the player gets fresh warnings the next time the cart starts taking
--- damage.
---@param cart InventoryItem
function SaucedCarts.Durability.resetThresholdMarker(cart)
    if not cart or not cart.getModData then return end
    cart:getModData().SaucedCarts_lastDamageThreshold = nil
end

--- Salvage materials dropped when a cart breaks
--- Intentionally less than crafting cost (you don't get everything back)
local SALVAGE_DROPS = {
    { item = "Base.ScrapMetal", min = 1, max = 2 },  -- Bent metal scraps
    { item = "Base.Wire", min = 0, max = 1 },        -- Maybe salvageable wire
    { item = "Base.MetalPipe", min = 0, max = 1 },   -- Maybe a bent pipe
}

--- Drop salvage materials at a location
---@param square IsoGridSquare Where to drop
local function dropSalvage(square)
    for _, salvage in ipairs(SALVAGE_DROPS) do
        local count = ZombRand(salvage.min, salvage.max + 1)
        for i = 1, count do
            local item = instanceItem(salvage.item)
            if item then
                -- Spread items slightly for visual variety
                local xOff = ZombRandFloat(0.3, 0.7)
                local yOff = ZombRandFloat(0.3, 0.7)
                square:AddWorldInventoryItem(item, xOff, yOff, 0, true)
            end
        end
    end
    SaucedCarts.debug("Dropped salvage materials from broken cart")
end

--- Drop all items from cart container to ground and destroy cart
--- Called when cart breaks (condition <= 0)
---
--- NOTE: This only handles dropping items from the cart's internal container.
--- The world object cleanup (transmitRemoveItemFromSquare, removeWorldObject)
--- is handled by the caller (ISCartPickupAction:complete).
---
---@param cart InventoryItem The cart item
---@param player IsoPlayer The player (for fallback square)
---@param square IsoGridSquare|nil Optional square override (for ground carts)
---@return boolean success
function SaucedCarts.Durability.dropContentsAndDestroy(cart, player, square)
    if not cart then return false end

    local container = cart:getItemContainer()
    square = square or (player and player:getCurrentSquare())

    if not square then
        SaucedCarts.error("dropContentsAndDestroy: no valid square")
        return false
    end

    -- Drop all items to ground. Two paths:
    --   - Corpse items: route through performCartTransfer so they
    --     materialize as real IsoDeadBody via its floor-drop corpse
    --     branch (loadCorpseFromByteData + addCorpse + sendCorpse).
    --     Otherwise broken-cart corpses would drop as un-grabbable
    --     Base.CorpseMale items with no respawn path.
    --   - Non-corpse items: the original AddWorldInventoryItem path
    --     (auto-transmit) — no benefit from performCartTransfer and it'd
    --     need additional test stubbing for ISTransferAction deps.
    -- M1 (2026-04-24): added corpse routing so broken carts containing
    -- bodies behave correctly after the corpse-storage feature landed.
    if container then
        local items = container:getItems()
        local itemCount = items:size()
        local droppedCount = 0
        -- Iterate backwards since we're removing
        for i = itemCount - 1, 0, -1 do
            local item = items:get(i)
            if item then
                local isCorpse = SaucedCarts.CorpseStorage
                    and SaucedCarts.CorpseStorage.isCorpseItem
                    and SaucedCarts.CorpseStorage.isCorpseItem(item)
                if isCorpse and player then
                    pcall(function()
                        SaucedCarts.performCartTransfer(player, item, container, nil, square, nil)
                    end)
                else
                    container:DoRemoveItem(item)
                    square:AddWorldInventoryItem(item, 0.5, 0.5, 0, true)
                end
                droppedCount = droppedCount + 1
            end
        end
        if droppedCount > 0 then
            SaucedCarts.debug(function() return "Dropped " .. droppedCount .. " items from broken cart" end)
        end
    end

    -- Defensive final reconcile. Per-item drops already cleared counts,
    -- but the onCartBroke event listener also calls reconcile(cart, nil);
    -- we do it here too in case the caller fires dropContentsAndDestroy
    -- without the associated onCartBroke event (idempotent anyway).
    if SaucedCarts.CorpseStorage and SaucedCarts.CorpseStorage.reconcile then
        pcall(function() SaucedCarts.CorpseStorage.reconcile(cart, nil) end)
    end

    -- Drop salvage materials (scrap metal, wire, etc.)
    dropSalvage(square)

    -- Note: World object cleanup handled by caller
    SaucedCarts.debug("Cart broke - destroyed")
    return true
end

--- Get the TILES_PER_DAMAGE constant (for debug/testing)
---@return number
function SaucedCarts.Durability.getTilesPerDamage()
    return TILES_PER_DAMAGE
end

SaucedCarts.debug("Durability loaded")

return SaucedCarts.Durability
