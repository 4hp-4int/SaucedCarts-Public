-- ============================================================================
-- SaucedCarts/Debug/ProfileCommands.lua
-- ============================================================================
-- PURPOSE: Profiling debug commands for performance analysis
--
-- CONTEXT: CLIENT ONLY
--
-- COMMANDS:
--   profile()       - Print profiling summary
--   profileReset()  - Reset profiling statistics
--   profileStart()  - Instrument key SaucedCarts functions
--   profileStatus() - Check if profiling is active
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"
local Profiler = require "SaucedCarts/Profiler"

local ProfileCommands = {}

--- Print profiling summary
function ProfileCommands.profile()
    Profiler.printSummary()
end

--- Reset profiling statistics
function ProfileCommands.profileReset()
    Profiler.reset()
end

--- Set threshold for logging individual calls (ms)
---@param ms number Minimum ms to log
function ProfileCommands.profileThreshold(ms)
    if not ms then
        print("[Profiler] Usage: SaucedCartsDebug.profileThreshold(1)")
        return
    end
    Profiler.setThreshold(ms)
    print("[Profiler] Threshold set to " .. ms .. "ms")
end

--- Check if profiling is active
function ProfileCommands.profileStatus()
    if Profiler.isActive() then
        print("[Profiler] ACTIVE - debug mode is on")
        local stats = Profiler.getStats()
        print("[Profiler] Tracking " .. #stats .. " functions")
    else
        print("[Profiler] INACTIVE - enable debug mode in sandbox settings")
    end
end

--- Instrument key SaucedCarts functions for profiling
--- Call this once after game start to begin tracking
function ProfileCommands.profileStart()
    if not getDebug() then
        print("[Profiler] Debug mode is OFF - profiling disabled")
        print("[Profiler] Enable debug in sandbox settings and restart")
        return
    end

    print("[Profiler] Instrumenting SaucedCarts functions...")

    -- Core functions
    if SaucedCarts.isCart then
        SaucedCarts.isCart = Profiler.wrap("isCart", SaucedCarts.isCart)
    end
    if SaucedCarts.getCartData then
        SaucedCarts.getCartData = Profiler.wrap("getCartData", SaucedCarts.getCartData)
    end

    -- Visual functions
    if SaucedCarts.updateCartVisual then
        SaucedCarts.updateCartVisual = Profiler.wrap("updateCartVisual", SaucedCarts.updateCartVisual)
    end
    if SaucedCarts.calculateFillState then
        SaucedCarts.calculateFillState = Profiler.wrap("calculateFillState", SaucedCarts.calculateFillState)
    end
    if SaucedCarts.getVisualModels then
        SaucedCarts.getVisualModels = Profiler.wrap("getVisualModels", SaucedCarts.getVisualModels)
    end

    -- Upgrade functions
    if SaucedCarts.Upgrades then
        if SaucedCarts.Upgrades.updatePlayer then
            SaucedCarts.Upgrades.updatePlayer = Profiler.wrap("Upgrades.updatePlayer", SaucedCarts.Upgrades.updatePlayer)
        end
        if SaucedCarts.Upgrades.getUpgradeKey then
            SaucedCarts.Upgrades.getUpgradeKey = Profiler.wrap("Upgrades.getUpgradeKey", SaucedCarts.Upgrades.getUpgradeKey)
        end
    end

    print("[Profiler] Instrumentation complete")
    print("[Profiler] Play normally, then run: SaucedCartsDebug.profile()")
end

return ProfileCommands
