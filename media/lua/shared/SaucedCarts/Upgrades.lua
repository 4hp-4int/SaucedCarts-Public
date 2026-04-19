-- ============================================================================
-- SaucedCarts/Upgrades.lua
-- ============================================================================
-- PURPOSE: Cart upgrade system for permanent modifications.
--          Flashlights are consumed on installation, their properties copied
--          to ModData. The cart itself becomes the light source and holds
--          battery state.
--
-- CONTEXT: SHARED (client + server)
--
-- UPGRADE TYPES:
--   - Flashlight: Consumed on install, cart emits light, battery powered
--
-- DATA MODEL:
--   modData.SaucedCarts_hasFlashlight = true|false
--   modData.SaucedCarts_flashlightData = { lightStrength, lightDistance, torchCone, ... }
--   modData.SaucedCarts_batteryCharge = 0.0-1.0
--   modData.SaucedCarts_isLightActive = true|false
--
-- LOAD ORDER: This file is loaded by Core.lua (via Durability).
--             Do NOT add require "SaucedCarts/Core" here (causes recursive require warning).
--             Dedicated servers may load files in non-deterministic order,
--             so we defensively initialize the namespace.
-- ============================================================================

-- Defensive init: dedicated server LoadDirBase may load this before Core.lua
SaucedCarts = SaucedCarts or {}
SaucedCarts.Config = SaucedCarts.Config or {}

SaucedCarts.Upgrades = {}

-- =============================================================================
-- CONSTANTS
-- =============================================================================

-- Battery drain rate (matches vanilla hand flashlight)
-- UseDelta decreases by this amount per real-time second when on
-- Fallback defaults guard against load-before-Core on dedicated servers
local BATTERY_DRAIN_PER_SECOND = SaucedCarts.Config.BATTERY_DRAIN_PER_SECOND or 0.00014

-- How often to check battery (in game ticks, ~60 = 1 second)
local BATTERY_CHECK_INTERVAL = SaucedCarts.Config.BATTERY_CHECK_INTERVAL or 60

-- =============================================================================
-- FLASHLIGHT UPGRADE STATE
-- =============================================================================

--- Check if cart has flashlight upgrade installed
---@param cart InventoryItem The cart item
---@return boolean hasFlashlight
function SaucedCarts.Upgrades.hasFlashlight(cart)
    if not cart then return false end
    local modData = cart:getModData()
    return modData.SaucedCarts_hasFlashlight == true
end

--- Get flashlight data from cart (light properties copied from consumed flashlight)
---@param cart InventoryItem The cart item
---@return table|nil flashlightData { lightStrength, lightDistance, torchCone, originalType, originalName }
function SaucedCarts.Upgrades.getFlashlightData(cart)
    if not cart then return nil end
    local modData = cart:getModData()
    return modData.SaucedCarts_flashlightData
end

--- Check if cart's light is currently active (on)
---@param cart InventoryItem The cart item
---@return boolean isActive
function SaucedCarts.Upgrades.isLightActive(cart)
    if not cart then return false end
    local modData = cart:getModData()
    return modData.SaucedCarts_isLightActive == true
end

--- Set light active state in ModData
---@param cart InventoryItem The cart item
---@param active boolean New active state
function SaucedCarts.Upgrades.setLightActive(cart, active)
    if not cart then return end
    local modData = cart:getModData()
    modData.SaucedCarts_isLightActive = active
end

-- =============================================================================
-- BATTERY STATE
-- =============================================================================

--- Get battery charge level (0.0 - 1.0)
---@param cart InventoryItem The cart item
---@return number charge Battery charge (0.0 = empty, 1.0 = full)
function SaucedCarts.Upgrades.getBatteryCharge(cart)
    if not cart then return 0 end
    local modData = cart:getModData()
    return modData.SaucedCarts_batteryCharge or 0
end

--- Set battery charge level
---@param cart InventoryItem The cart item
---@param charge number New charge level (clamped to 0.0 - 1.0)
function SaucedCarts.Upgrades.setBatteryCharge(cart, charge)
    if not cart then return end
    local modData = cart:getModData()
    modData.SaucedCarts_batteryCharge = math.max(0, math.min(1, charge))
end

--- Check if cart has any battery charge
---@param cart InventoryItem The cart item
---@return boolean hasBattery True if charge > 0
function SaucedCarts.Upgrades.hasBattery(cart)
    return SaucedCarts.Upgrades.getBatteryCharge(cart) > 0
end

--- Add battery charge to cart (from inserting a battery)
---@param cart InventoryItem The cart item
---@param charge number Charge to add (0.0 - 1.0)
---@return number newCharge The new total charge (capped at 1.0)
function SaucedCarts.Upgrades.addBatteryCharge(cart, charge)
    if not cart then return 0 end
    local current = SaucedCarts.Upgrades.getBatteryCharge(cart)
    local newCharge = math.min(1.0, current + charge)
    SaucedCarts.Upgrades.setBatteryCharge(cart, newCharge)
    return newCharge
end

--- Drain battery (called from server tick)
---@param cart InventoryItem The cart item
---@param deltaTime number Time in seconds to drain
---@return boolean depleted True if battery was depleted (hit 0)
function SaucedCarts.Upgrades.drainBattery(cart, deltaTime)
    if not cart then return false end

    local current = SaucedCarts.Upgrades.getBatteryCharge(cart)
    if current <= 0 then
        return true  -- Already depleted
    end

    local drainAmount = BATTERY_DRAIN_PER_SECOND * deltaTime
    local newCharge = math.max(0, current - drainAmount)
    SaucedCarts.Upgrades.setBatteryCharge(cart, newCharge)

    return newCharge <= 0
end

-- =============================================================================
-- UPGRADE CAPABILITY CHECKS
-- =============================================================================

--- Check if a cart type supports flashlight installation
---@param cart InventoryItem The cart item
---@return boolean canInstall True if cart type allows flashlight
function SaucedCarts.Upgrades.canHaveFlashlight(cart)
    if not cart then return false end
    local cartData = SaucedCarts.getCartData(cart)
    -- Default to true if not specified (backwards compatibility)
    return not cartData or cartData.canHaveFlashlight ~= false
end

--- Check if a flashlight can be installed on this specific cart
--- Validates both cart type capability and current state
---@param cart InventoryItem The cart item
---@return boolean canInstall True if flashlight can be installed
---@return string|nil reason Reason if cannot install
function SaucedCarts.Upgrades.canInstallFlashlight(cart)
    if not cart then return false, "No cart" end

    -- Check cart type allows flashlight
    if not SaucedCarts.Upgrades.canHaveFlashlight(cart) then
        return false, "Cart type doesn't support flashlight"
    end

    -- Check if already has flashlight
    if SaucedCarts.Upgrades.hasFlashlight(cart) then
        return false, "Flashlight already installed"
    end

    return true, nil
end

--- Check if a battery can be inserted into this cart
---@param cart InventoryItem The cart item
---@return boolean canInsert True if battery can be inserted
---@return string|nil reason Reason if cannot insert
function SaucedCarts.Upgrades.canInsertBattery(cart)
    if not cart then return false, "No cart" end

    -- Must have flashlight installed to use battery
    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        return false, "No flashlight installed"
    end

    -- Check if already at full charge
    local charge = SaucedCarts.Upgrades.getBatteryCharge(cart)
    if charge >= 1.0 then
        return false, "Battery already full"
    end

    return true, nil
end

--- Check if a battery can be removed from this cart
---@param cart InventoryItem The cart item
---@return boolean canRemove True if battery can be removed
---@return string|nil reason Reason if cannot remove
function SaucedCarts.Upgrades.canRemoveBattery(cart)
    if not cart then return false, "No cart" end

    -- Must have flashlight installed
    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        return false, "No flashlight installed"
    end

    -- Must have charge to remove
    local charge = SaucedCarts.Upgrades.getBatteryCharge(cart)
    if charge <= 0 then
        return false, "No battery charge to remove"
    end

    return true, nil
end

-- =============================================================================
-- FLASHLIGHT INSTALLATION
-- =============================================================================

--- Install flashlight upgrade on cart (consumes flashlight)
--- Called from ISInstallFlashlightAction:complete()
---@param cart InventoryItem The cart item
---@param flashlight InventoryItem The flashlight to consume (properties copied)
---@return boolean success Whether installation succeeded
function SaucedCarts.Upgrades.installFlashlight(cart, flashlight)
    if not cart or not flashlight then return false end

    -- Validate installation is allowed (defense in depth)
    local canInstall, reason = SaucedCarts.Upgrades.canInstallFlashlight(cart)
    if not canInstall then
        SaucedCarts.debug(function() return "Upgrades: cannot install flashlight - " .. (reason or "unknown") end)
        return false
    end

    local modData = cart:getModData()

    -- Copy light properties from flashlight
    modData.SaucedCarts_hasFlashlight = true
    modData.SaucedCarts_flashlightData = {
        lightStrength = flashlight:getLightStrength() or 1.8,
        lightDistance = flashlight:getLightDistance() or 15,
        torchCone = flashlight.isTorchCone and flashlight:isTorchCone() or true,
        torchDot = flashlight:getTorchDot() or 0.5,
        originalType = flashlight:getFullType(),
        originalName = flashlight:getDisplayName(),
    }

    -- Transfer battery charge if flashlight has one
    local batteryCharge = 0
    if flashlight.getCurrentUsesFloat then
        batteryCharge = flashlight:getCurrentUsesFloat() or 0
    end
    modData.SaucedCarts_batteryCharge = batteryCharge
    modData.SaucedCarts_isLightActive = false

    SaucedCarts.debug(function() return string.format(
        "Upgrades: installed flashlight - strength=%.2f, dist=%d, cone=%s, dot=%.2f, battery=%.2f",
        modData.SaucedCarts_flashlightData.lightStrength,
        modData.SaucedCarts_flashlightData.lightDistance,
        tostring(modData.SaucedCarts_flashlightData.torchCone),
        modData.SaucedCarts_flashlightData.torchDot,
        batteryCharge
    ) end)

    return true
end

-- =============================================================================
-- CART LIGHT EMISSION
-- =============================================================================
-- The CART itself emits light, not the flashlight.
-- When toggled ON, we copy the stored flashlight properties to the cart.
-- Cart is already in player's hands, so getActiveLightItems() detects it.

--- Enable light emission on cart using stored flashlight properties
---@param cart InventoryItem The cart item (in player's hands)
function SaucedCarts.Upgrades.enableCartLight(cart)
    if not cart then return end

    local flashlightData = SaucedCarts.Upgrades.getFlashlightData(cart)
    if not flashlightData then
        return
    end

    -- Copy light properties to cart
    cart:setLightStrength(flashlightData.lightStrength or 1.8)
    cart:setLightDistance(flashlightData.lightDistance or 15)
    cart:setTorchCone(flashlightData.torchCone ~= false)  -- Default true
    -- Note: TorchDot comes from item script (no Lua setter), cart should have TorchDot = 0.5 defined

    -- Enable activation on cart so isEmittingLight() works
    cart:setCanBeActivated(true)
    cart:setActivated(true)
end

--- Disable light emission on cart
---@param cart InventoryItem The cart item
function SaucedCarts.Upgrades.disableCartLight(cart)
    if not cart then return end

    -- Turn off and reset light properties
    cart:setActivated(false)
    cart:setLightStrength(0)
    cart:setLightDistance(0)
    cart:setTorchCone(false)
    cart:setCanBeActivated(false)
end

--- Check if cart is currently emitting light
---@param cart InventoryItem The cart item
---@return boolean isEmitting True if cart is emitting light
function SaucedCarts.Upgrades.isCartEmittingLight(cart)
    if not cart then return false end
    return cart.isEmittingLight and cart:isEmittingLight() or false
end

-- =============================================================================
-- TOGGLE FLASHLIGHT (Called from F key or context menu)
-- =============================================================================

--- Toggle cart flashlight on/off
---@param cart InventoryItem The cart item
---@param player IsoPlayer The player holding the cart
---@return boolean newState The new active state (true = on, false = off)
---@return boolean success Whether toggle succeeded
function SaucedCarts.Upgrades.toggleFlashlight(cart, player)
    if not cart or not player then
        return false, false
    end

    -- Check if cart has flashlight upgrade
    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        SaucedCarts.debug("Upgrades: toggleFlashlight - no flashlight installed")
        return false, false
    end

    local isCurrentlyOn = SaucedCarts.Upgrades.isLightActive(cart)

    if isCurrentlyOn then
        -- Turn OFF
        SaucedCarts.Upgrades.setLightActive(cart, false)
        SaucedCarts.Upgrades.disableCartLight(cart)

        -- Play sound
        if cart.playActivateDeactivateSound then
            cart:playActivateDeactivateSound()
        end

        -- Fire event
        if SaucedCarts._fireEvent then
            SaucedCarts._fireEvent(SaucedCarts.Events.onFlashlightToggled, player, cart, false)
        end

        SaucedCarts.debug("Upgrades: flashlight toggled OFF")
        return false, true
    else
        -- Turn ON - check battery first
        local charge = SaucedCarts.Upgrades.getBatteryCharge(cart)
        if charge <= 0 then
            SaucedCarts.debug("Upgrades: toggleFlashlight - no battery")
            -- Notify player (client only)
            if not isServer() then
                if SaucedCarts.Notifications then
                    SaucedCarts.Notifications.warn(player,
                        getText("UI_SaucedCarts_NoBattery") or "No battery!",
                        "no_battery")
                end
            end
            return false, false
        end

        -- Turn ON
        SaucedCarts.Upgrades.setLightActive(cart, true)
        SaucedCarts.Upgrades.enableCartLight(cart)

        -- Play sound
        if cart.playActivateDeactivateSound then
            cart:playActivateDeactivateSound()
        end

        -- Fire event
        if SaucedCarts._fireEvent then
            SaucedCarts._fireEvent(SaucedCarts.Events.onFlashlightToggled, player, cart, true)
        end

        SaucedCarts.debug("Upgrades: flashlight toggled ON")
        return true, true
    end
end

-- =============================================================================
-- VISUAL MODEL HELPERS
-- =============================================================================

--- Get the upgrade key for model selection
--- Returns nil if no upgrades, or "flashlight" if flashlight installed
---@param cart InventoryItem The cart item
---@return string|nil upgradeKey
function SaucedCarts.Upgrades.getUpgradeKey(cart)
    if not cart then return nil end

    if SaucedCarts.Upgrades.hasFlashlight(cart) then
        return "flashlight"
    end

    return nil
end

-- =============================================================================
-- STATE RECOVERY (called from OnPlayerUpdate)
-- =============================================================================

--- Ensure cart light state matches ModData (recovery after area transitions)
---@param player IsoPlayer The player
function SaucedCarts.Upgrades.updatePlayer(player)
    if not player then return end

    local cart = SaucedCarts.getHeldCart(player)
    if not cart then return end

    -- Only process flashlight-upgraded carts
    if not SaucedCarts.Upgrades.hasFlashlight(cart) then return end

    local shouldBeOn = SaucedCarts.Upgrades.isLightActive(cart)
    local isEmitting = SaucedCarts.Upgrades.isCartEmittingLight(cart)

    -- Sync state: ensure cart light matches ModData
    if shouldBeOn and not isEmitting then
        -- Light should be on but cart isn't emitting - fix it
        SaucedCarts.Upgrades.enableCartLight(cart)
    elseif not shouldBeOn and isEmitting then
        -- Light should be off but cart is emitting - fix it
        SaucedCarts.Upgrades.disableCartLight(cart)
    end
end

-- =============================================================================
-- EVENT HOOKS
-- =============================================================================

-- NOTE: Upgrades.updatePlayer() is called from CartStateHandler.onPlayerUpdate()
-- to avoid duplicate OnPlayerUpdate handlers. This consolidates per-frame work.

-- Register upgrade-related event handlers
local function registerUpgradeEventHandlers()
    -- Cart dropped to ground: disable flashlight
    if SaucedCarts.Events and SaucedCarts.Events.onCartDrop then
        SaucedCarts.Events.onCartDrop:Add(function(player, cart, square)
            if not cart then return end

            -- Flashlight: turn off when dropped
            if SaucedCarts.Upgrades.hasFlashlight(cart) then
                SaucedCarts.Upgrades.setLightActive(cart, false)
                SaucedCarts.Upgrades.disableCartLight(cart)
                SaucedCarts.debug("Upgrades: toggled off flashlight on cart drop")
            end
        end)
    end

    -- Cart broke: clean up flashlight
    if SaucedCarts.Events and SaucedCarts.Events.onCartBroke then
        SaucedCarts.Events.onCartBroke:Add(function(player, cart, square)
            if not cart then return end

            if SaucedCarts.Upgrades.hasFlashlight(cart) then
                SaucedCarts.Upgrades.disableCartLight(cart)
            end
        end)
    end
end

registerUpgradeEventHandlers()

-- =============================================================================
-- MODULE INITIALIZATION
-- =============================================================================

SaucedCarts.debug("Upgrades module loaded")

return SaucedCarts.Upgrades
