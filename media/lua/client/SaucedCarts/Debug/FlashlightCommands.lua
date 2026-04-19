-- ============================================================================
-- SaucedCarts/Debug/FlashlightCommands.lua
-- ============================================================================
-- PURPOSE: Debug commands for cart flashlight system testing.
--
-- CONTEXT: CLIENT ONLY (loaded via DebugCommands.lua)
--
-- USAGE:
--   SaucedCartsDebug.showFlashlightStatus()
--   SaucedCartsDebug.toggleFlashlight()
--   SaucedCartsDebug.setBatteryCharge(0.5)
--   SaucedCartsDebug.installFlashlight()
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"

local FlashlightCommands = {}

--- Show flashlight state of held cart
function FlashlightCommands.showFlashlightStatus()
    local player = getSpecificPlayer(0)
    if not player then
        print("[SaucedCarts] No player found")
        return
    end

    local cart = SaucedCarts.getHeldCart(player)
    if not cart then
        print("[SaucedCarts] No cart equipped")
        return
    end

    print("=== Cart Flashlight Status ===")
    print("  Cart: " .. cart:getFullType() .. " ID=" .. cart:getID())

    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        print("  Flashlight installed: NO")
        print("==============================")
        return
    end

    local flashlightData = SaucedCarts.Upgrades.getFlashlightData(cart)
    local isActive = SaucedCarts.Upgrades.isLightActive(cart)
    local charge = SaucedCarts.Upgrades.getBatteryCharge(cart)
    local isEmitting = SaucedCarts.Upgrades.isCartEmittingLight(cart)

    print("  Flashlight installed: YES")
    print("  Light state: " .. (isActive and "ON" or "OFF"))
    print("  Is emitting: " .. tostring(isEmitting))
    print("  Battery: " .. string.format("%.2f", charge * 100) .. "%")

    if flashlightData then
        print("  Light strength: " .. (flashlightData.lightStrength or "nil"))
        print("  Light distance: " .. (flashlightData.lightDistance or "nil"))
        print("  Torch cone: " .. tostring(flashlightData.torchCone))
        print("  Original type: " .. (flashlightData.originalType or "nil"))
    end

    print("==============================")
end

--- Toggle flashlight on held cart
function FlashlightCommands.toggleFlashlight()
    local player = getSpecificPlayer(0)
    if not player then
        print("[SaucedCarts] No player found")
        return
    end

    local cart = SaucedCarts.getHeldCart(player)
    if not cart then
        print("[SaucedCarts] No cart equipped")
        return
    end

    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        print("[SaucedCarts] Cart has no flashlight installed")
        return
    end

    local newState, success = SaucedCarts.Upgrades.toggleFlashlight(cart, player)
    if success then
        print("[SaucedCarts] Flashlight toggled " .. (newState and "ON" or "OFF"))
    else
        print("[SaucedCarts] Failed to toggle flashlight (no battery?)")
    end
end

--- Set battery charge on held cart
---@param charge number Battery charge 0-1
function FlashlightCommands.setBatteryCharge(charge)
    local player = getSpecificPlayer(0)
    if not player then
        print("[SaucedCarts] No player found")
        return
    end

    local cart = SaucedCarts.getHeldCart(player)
    if not cart then
        print("[SaucedCarts] No cart equipped")
        return
    end

    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        print("[SaucedCarts] Cart has no flashlight installed")
        return
    end

    charge = tonumber(charge) or 1.0
    charge = math.max(0, math.min(1, charge))

    SaucedCarts.Upgrades.setBatteryCharge(cart, charge)
    print("[SaucedCarts] Battery charge set to " .. string.format("%.2f", charge * 100) .. "%")
end

--- Instantly install flashlight on held cart (bypasses timed action)
function FlashlightCommands.installFlashlight()
    local player = getSpecificPlayer(0)
    if not player then
        print("[SaucedCarts] No player found")
        return
    end

    local cart = SaucedCarts.getHeldCart(player)
    if not cart then
        print("[SaucedCarts] No cart equipped")
        return
    end

    if SaucedCarts.Upgrades.hasFlashlight(cart) then
        print("[SaucedCarts] Cart already has flashlight installed")
        return
    end

    local canInstall, reason = SaucedCarts.Upgrades.canInstallFlashlight(cart)
    if not canInstall then
        print("[SaucedCarts] Cannot install flashlight: " .. (reason or "unknown"))
        return
    end

    -- Create a virtual flashlight and install
    local modData = cart:getModData()
    modData.SaucedCarts_hasFlashlight = true
    modData.SaucedCarts_flashlightData = {
        lightStrength = 1.8,
        lightDistance = 15,
        torchCone = true,
        torchDot = 0.5,
        originalType = "Base.Torch",
        originalName = "Debug Flashlight",
    }
    modData.SaucedCarts_batteryCharge = 1.0
    modData.SaucedCarts_isLightActive = false

    print("[SaucedCarts] Flashlight installed (debug, full battery)")
end

--- Simulate battery drain for testing
---@param seconds number|nil Seconds to drain (default 60)
function FlashlightCommands.drainBattery(seconds)
    local player = getSpecificPlayer(0)
    if not player then
        print("[SaucedCarts] No player found")
        return
    end

    local cart = SaucedCarts.getHeldCart(player)
    if not cart then
        print("[SaucedCarts] No cart equipped")
        return
    end

    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        print("[SaucedCarts] Cart has no flashlight installed")
        return
    end

    seconds = tonumber(seconds) or 60
    local chargeBefore = SaucedCarts.Upgrades.getBatteryCharge(cart)
    local depleted = SaucedCarts.Upgrades.drainBattery(cart, seconds)
    local chargeAfter = SaucedCarts.Upgrades.getBatteryCharge(cart)

    print("[SaucedCarts] Simulated " .. seconds .. "s drain")
    print("  Before: " .. string.format("%.4f", chargeBefore))
    print("  After: " .. string.format("%.4f", chargeAfter))
    print("  Drained: " .. string.format("%.4f", chargeBefore - chargeAfter))
    if depleted then
        print("  Battery DEPLETED!")
    end
end

return FlashlightCommands
