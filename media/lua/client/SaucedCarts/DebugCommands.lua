-- ============================================================================
-- SaucedCarts/DebugCommands.lua
-- ============================================================================
-- PURPOSE: Debug utilities for testing SaucedCarts in-game.
--          This is a thin loader that merges all debug modules.
--
-- CONTEXT: CLIENT ONLY
--
-- USAGE: In Lua console (debug mode or admin):
--   SaucedCartsDebug.spawnCart("ShoppingCart")
--   SaucedCartsDebug.giveCart("Wheelbarrow")
--   SaucedCartsDebug.setCondition(50)
--   SaucedCartsDebug.showStatus()
--   SaucedCartsDebug.listCarts()
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"
require "SaucedCarts/CartData"

-- Force load ContextMenu to ensure it registers event handlers
require "SaucedCarts/ContextMenu"

---@class SaucedCartsDebugModule
---@field spawnCart fun(cartType: string) Spawn cart at player position
---@field giveCart fun(cartType: string) Add cart to player inventory
---@field setCondition fun(condition: number) Set condition of held cart
---@field showStatus fun() Show status of held cart
---@field listCarts fun() List all available cart types
---@field listRegistered fun() List all registered cart types (alias for listCarts)
---@field checkRegistration fun(fullType: string) Check if a cart type is registered
SaucedCartsDebug = SaucedCartsDebug or {}

-- Load and merge all debug modules
local modules = {
    require "SaucedCarts/Debug/CartCommands",
    require "SaucedCarts/Debug/RegistrationCommands",
    require "SaucedCarts/Debug/VisualCommands",
    require "SaucedCarts/Debug/MigrationCommands",
    require "SaucedCarts/Debug/RestrictionCommands",
    require "SaucedCarts/Debug/AnimationCommands",
    require "SaucedCarts/Debug/TestCommands",
    require "SaucedCarts/Debug/ProfileCommands",
    require "SaucedCarts/Debug/FlashlightCommands",
    require "SaucedCarts/Debug/SpawnCommands",
    require "SaucedCarts/Debug/CapacityCommands",
}

local functionCount = 0
for _, mod in ipairs(modules) do
    for name, func in pairs(mod) do
        SaucedCartsDebug[name] = func
        functionCount = functionCount + 1
    end
end

SaucedCarts.debug(function() return "DebugCommands loaded (" .. #modules .. " modules, " .. functionCount .. " functions)" end)
