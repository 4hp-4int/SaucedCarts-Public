-- ============================================================================
-- SaucedCarts/Notifications.lua
-- ============================================================================
-- PURPOSE: Centralized notification system for SaucedCarts.
--          Provides easy HaloText notifications with consistent styling.
--
-- CONTEXT: CLIENT ONLY
--
-- USAGE:
--   local Notifications = require "SaucedCarts/Notifications"
--   Notifications.warn(player, "I can't put a grocery cart in my pocket!")
--   Notifications.info(player, "Cart condition: 75%")
--   Notifications.success(player, "Cart repaired!")
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"

---@class SaucedCartsNotifications
local Notifications = {}

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

-- Throttle settings to prevent notification spam
local THROTTLE_TIME_MS = 1500  -- Minimum time between same-type notifications
local lastNotificationTime = {}

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

--- Check if we should throttle this notification
---@param player IsoPlayer The player
---@param throttleKey string Key to identify notification type
---@return boolean True if notification should be shown (not throttled)
local function shouldShowNotification(player, throttleKey)
    if not player then return false end

    local playerNum = player:getPlayerNum()
    local key = playerNum .. "_" .. throttleKey
    local now = getTimestampMs()

    if lastNotificationTime[key] and (now - lastNotificationTime[key]) < THROTTLE_TIME_MS then
        return false
    end

    lastNotificationTime[key] = now
    return true
end

--- Get color by type
--- Uses HaloTextHelper colors if available, falls back to hardcoded colors
---@param colorType string "warning", "info", "success", "error"
---@return table Color table {r, g, b, a}
local function getColor(colorType)
    -- Fallback colors (RGBA 0-1 range)
    local fallbackColors = {
        warning = {r = 1.0, g = 0.8, b = 0.2, a = 1.0},  -- Yellow/orange
        success = {r = 0.2, g = 1.0, b = 0.2, a = 1.0},  -- Green
        error   = {r = 1.0, g = 0.2, b = 0.2, a = 1.0},  -- Red
        info    = {r = 1.0, g = 1.0, b = 1.0, a = 1.0},  -- White
    }

    -- Try to use HaloTextHelper colors
    if HaloTextHelper then
        local success, color = pcall(function()
            if colorType == "warning" then
                -- HaloTextHelper doesn't have getColorWarning, use getBadColor (orange/red)
                return HaloTextHelper.getBadColor and HaloTextHelper.getBadColor()
            elseif colorType == "success" then
                return HaloTextHelper.getColorGreen and HaloTextHelper.getColorGreen()
            elseif colorType == "error" then
                return HaloTextHelper.getColorRed and HaloTextHelper.getColorRed()
            else
                return HaloTextHelper.getColorWhite and HaloTextHelper.getColorWhite()
            end
        end)

        if success and color then
            return color
        end
    end

    -- Return fallback color
    return fallbackColors[colorType] or fallbackColors.info
end

--- Show a HaloText notification above the player
---@param player IsoPlayer The player
---@param text string The notification text
---@param colorType string "warning", "info", "success", "error"
---@param throttleKey string|nil Optional key for throttling (nil = no throttle)
---@param arrowUp boolean|nil Arrow direction (default true)
local function showHaloText(player, text, colorType, throttleKey, arrowUp)
    if not player then return end
    if not HaloTextHelper then
        SaucedCarts.debug(function() return "HaloTextHelper not available, skipping notification: " .. text end)
        return
    end

    -- Apply throttle if key provided
    if throttleKey and not shouldShowNotification(player, throttleKey) then
        SaucedCarts.debug(function() return "Notification throttled: " .. throttleKey end)
        return
    end

    local color = getColor(colorType)
    local arrow = arrowUp ~= false  -- Default to true

    HaloTextHelper.addTextWithArrow(player, text, arrow, color)
    SaucedCarts.debug(function() return "Notification shown: " .. text end)
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Show a warning notification (yellow/orange)
--- Used for blocked actions, restrictions, etc.
---@param player IsoPlayer The player
---@param text string The notification text
---@param throttleKey string|nil Optional throttle key
function Notifications.warn(player, text, throttleKey)
    showHaloText(player, text, "warning", throttleKey, true)
end

--- Show an info notification (white)
--- Used for status updates, neutral messages
---@param player IsoPlayer The player
---@param text string The notification text
---@param throttleKey string|nil Optional throttle key
function Notifications.info(player, text, throttleKey)
    showHaloText(player, text, "info", throttleKey, true)
end

--- Show a success notification (green)
--- Used for completed actions, repairs, etc.
---@param player IsoPlayer The player
---@param text string The notification text
---@param throttleKey string|nil Optional throttle key
function Notifications.success(player, text, throttleKey)
    showHaloText(player, text, "success", throttleKey, true)
end

--- Show an error notification (red)
--- Used for failures, critical issues
---@param player IsoPlayer The player
---@param text string The notification text
---@param throttleKey string|nil Optional throttle key
function Notifications.error(player, text, throttleKey)
    showHaloText(player, text, "error", throttleKey, false)
end

-- ============================================================================
-- PRESET NOTIFICATIONS
-- ============================================================================
-- These are commonly used notifications with built-in throttling

--- Notify player that cart cannot be grabbed/transferred
---@param player IsoPlayer The player
function Notifications.cantGrabCart(player)
    Notifications.warn(player, getText("UI_SaucedCarts_CantGrabCart"), "cant_grab_cart")
end

--- Notify player that cart cannot be dragged
---@param player IsoPlayer The player
function Notifications.cantDragCart(player)
    Notifications.warn(player, getText("UI_SaucedCarts_CantDragCart"), "cant_drag_cart")
end

--- Notify player that action is blocked while holding cart
---@param player IsoPlayer The player
---@param action string The blocked action name
function Notifications.cantWhileHoldingCart(player, action)
    local text = getText("UI_SaucedCarts_CantWhileHoldingCart", action)
    Notifications.warn(player, text, "cant_while_holding_" .. action)
end

--- Notify player about orphan carts found
---@param player IsoPlayer The player
---@param count number Number of orphan carts
function Notifications.orphansFound(player, count)
    local text = getText("UI_SaucedCarts_OrphansFound", count)
    Notifications.warn(player, text, "orphans_found")
end

--- Notify player that cart condition is low (< 25%)
---@param player IsoPlayer The player
function Notifications.cartDamaged(player)
    Notifications.warn(player, getText("UI_SaucedCarts_CartDamaged"), "cart_damaged")
end

--- Notify player that cart broke on pickup
---@param player IsoPlayer The player
function Notifications.cartBroke(player)
    Notifications.error(player, getText("UI_SaucedCarts_CartBroke"), "cart_broke")
end

--- Notify player that vehicle container is full
---@param player IsoPlayer The player
function Notifications.vehicleFull(player)
    Notifications.warn(player, getText("UI_SaucedCarts_VehicleFull"), "vehicle_full")
end

-- ============================================================================
-- MODULE REGISTRATION
-- ============================================================================

SaucedCarts.Notifications = Notifications

SaucedCarts.debug("Notifications loaded")

return Notifications
