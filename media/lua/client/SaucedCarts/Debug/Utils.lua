-- ============================================================================
-- SaucedCarts/Debug/Utils.lua
-- ============================================================================
-- PURPOSE: Shared utilities for debug commands
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"
require "SaucedCarts/CartData"

local Utils = {}

--- Helper: Get list of available cart type short names for error messages
---@return string Comma-separated list of cart types
function Utils.getAvailableCartTypes()
    local types = {}
    for fullType, _ in pairs(SaucedCarts.CartTypes) do
        -- Extract short name from fullType (e.g., "SaucedCarts.ShoppingCart" -> "ShoppingCart")
        local shortType = fullType:match("%.(.+)$") or fullType
        table.insert(types, shortType)
    end
    if #types == 0 then
        return "(none registered)"
    end
    return table.concat(types, ", ")
end

--- Helper: Try to resolve a cart type with multiple formats
--- Checks: exact fullType, prefixed with "SaucedCarts.", or finds matching short name
---@param cartType string The cart type to resolve
---@return string|nil fullType The resolved full type, or nil if not found
function Utils.resolveCartType(cartType)
    if not cartType then return nil end

    -- Try exact match first
    if SaucedCarts.CartTypes[cartType] then
        return cartType
    end

    -- Try with SaucedCarts prefix
    local withPrefix = "SaucedCarts." .. cartType
    if SaucedCarts.CartTypes[withPrefix] then
        return withPrefix
    end

    -- Try to find any cart type ending with the given name
    for fullType, _ in pairs(SaucedCarts.CartTypes) do
        local shortType = fullType:match("%.(.+)$") or fullType
        if shortType == cartType then
            return fullType
        end
    end

    return nil
end

--- Helper: Get the local player with error handling
---@return IsoPlayer|nil player, string|nil error
function Utils.getPlayer()
    local player = getPlayer()
    if not player then
        return nil, "[SaucedCarts] ERROR: No player found"
    end
    return player, nil
end

--- Helper: Get held cart with error handling
---@param player IsoPlayer
---@return InventoryItem|nil cart, string|nil error
function Utils.getHeldCart(player)
    local cart = SaucedCarts.getHeldCart(player)
    if not cart then
        return nil, "[SaucedCarts] ERROR: Not holding a cart"
    end
    return cart, nil
end

--- Helper: Dump all context menu option names (for debugging)
--- Call this to see exactly what option names are available
---@param context ISContextMenu The context menu to inspect
function Utils.dumpContextMenuOptions(context)
    print("=== Context Menu Options ===")
    if not context or not context.options then
        print("  (no context or options)")
        return
    end

    for i, option in ipairs(context.options) do
        local name = option.name or "(unnamed)"
        local text = option.text or option.name or "(no text)"
        print("  " .. i .. ": name='" .. tostring(name) .. "' text='" .. tostring(text) .. "'")
    end
    print("=============================")
end

return Utils
