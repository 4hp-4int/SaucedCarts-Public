-- ============================================================================
-- SaucedCarts/CartState/FlashlightHook.lua
-- ============================================================================
-- PURPOSE: Hook vanilla flashlight toggle (F key) for cart flashlight.
--          When player presses F while holding an upgraded cart, toggle the
--          cart's light instead of searching for a handheld flashlight.
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"
require "SaucedCarts/UpgradeSync"

---@class SaucedCartsFlashlightHook
local FlashlightHook = {}

-- =============================================================================
-- STATE
-- =============================================================================

local vanillaToggleLight = nil

-- =============================================================================
-- HOOK INSTALLATION
-- =============================================================================

--- Install the F-key hook for cart flashlight toggle
---@return boolean success True if hook was installed
local function installHook()
    -- Wait for ItemBindingHandler to be loaded
    if not ItemBindingHandler or not ItemBindingHandler.toggleLight then
        SaucedCarts.debug("FlashlightHook: ItemBindingHandler not ready, deferring hook")
        return false
    end

    -- Already hooked
    if vanillaToggleLight then
        return true
    end

    -- Store original function
    vanillaToggleLight = ItemBindingHandler.toggleLight

    -- Replace with our wrapper
    ItemBindingHandler.toggleLight = function(key)
        local player = getSpecificPlayer(0)
        if not player then
            return vanillaToggleLight(key)
        end

        -- Check if player is holding an upgraded cart
        local primary = player:getPrimaryHandItem()
        if primary and SaucedCarts.isCart(primary) then
            if SaucedCarts.Upgrades.hasFlashlight(primary) then
                -- Toggle cart's light using local wrapper (updates tracking for SP battery drain)
                local newState, success = SaucedCarts.UpgradeSync.toggleFlashlightLocal(primary, player)

                if success then
                    -- MP sync (server also needs to know for broadcasting to other clients)
                    if isClient() then
                        SaucedCarts.UpgradeSync.requestToggle(player, primary:getID())
                    end

                    SaucedCarts.debug(function() return "FlashlightHook: F key toggled cart light to " .. tostring(newState) end)
                else
                    SaucedCarts.debug("FlashlightHook: F key toggle failed (no battery?)")
                end

                return  -- Handled, don't continue to vanilla
            end
        end

        -- Fall through to vanilla behavior
        return vanillaToggleLight(key)
    end

    SaucedCarts.debug("FlashlightHook: F key flashlight hook installed")
    return true
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

--- Initialize the flashlight hook
--- Call this at module load or OnGameStart
function FlashlightHook.init()
    if not installHook() then
        Events.OnGameStart.Add(function()
            installHook()
        end)
    end
end

--- Check if hook is installed
---@return boolean
function FlashlightHook.isInstalled()
    return vanillaToggleLight ~= nil
end

-- =============================================================================
-- AUTO-INITIALIZATION
-- =============================================================================

-- Try to hook immediately on require
FlashlightHook.init()

SaucedCarts.debug("FlashlightHook module loaded")

return FlashlightHook
