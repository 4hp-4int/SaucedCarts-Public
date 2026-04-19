-- ============================================================================
-- SaucedCarts/ContextMenu/CartSubmenu.lua
-- ============================================================================
-- PURPOSE: Unified cart options submenu builder.
--          Creates the "Cart (Name)" parent menu with all cart options.
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"

-- Import submodules
local RepairMenu = require "SaucedCarts/ContextMenu/RepairMenu"
local FlashlightMenu = require "SaucedCarts/ContextMenu/FlashlightMenu"

---@class SaucedCartsCartSubmenu
local CartSubmenu = {}

-- ============================================================================
-- LOCAL HELPERS
-- ============================================================================

--- Get translated text with fallback
---@param key string Translation key
---@param fallback string Fallback text
---@return string
local function getTextOrFallback(key, fallback)
    local text = getText(key)
    return (text == key) and fallback or text
end

--- Get condition color for display (returns RGB hex string)
---@param conditionPercent number 0-100
---@return string RGB color code for rich text
local function getConditionColorTag(conditionPercent)
    if conditionPercent >= 75 then
        return "<RGB:0.2,0.8,0.2>"  -- Green
    elseif conditionPercent >= 50 then
        return "<RGB:0.6,0.8,0.2>"  -- Yellow-green
    elseif conditionPercent >= 25 then
        return "<RGB:0.9,0.6,0.1>"  -- Orange
    else
        return "<RGB:0.9,0.2,0.2>"  -- Red
    end
end

--- Create a tooltip for a cart option showing condition
---@param cart InventoryItem The cart item
---@param cartName string The cart name
---@param extraText string|nil Optional extra text (e.g., blocked reason)
---@return ISToolTip
local function createCartTooltip(cart, cartName, extraText)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip:setVisible(false)
    tooltip:setName(cartName)

    local lines = {}

    -- Condition info
    local condition = cart:getCondition()
    local conditionMax = cart:getConditionMax()
    if conditionMax and conditionMax > 0 then
        local conditionPercent = math.floor((condition / conditionMax) * 100)
        local colorTag = getConditionColorTag(conditionPercent)
        local conditionLabel = getText("IGUI_invpanel_Condition") or "Condition"
        table.insert(lines, conditionLabel .. ": " .. colorTag .. conditionPercent .. "%")

        -- Warning if low
        if conditionPercent <= 25 and conditionPercent > 0 then
            table.insert(lines, "<RGB:0.9,0.6,0.1>" .. (getText("UI_SaucedCarts_CartDamaged") or "Cart is damaged"))
        elseif condition <= 0 then
            table.insert(lines, "<RGB:0.9,0.2,0.2>" .. (getText("UI_SaucedCarts_CartBroke") or "Cart is broken"))
        end
    end

    -- Extra text (e.g., "Cannot pick up while sleeping")
    if extraText then
        table.insert(lines, " ")
        table.insert(lines, "<RGB:1,0.5,0.5>" .. extraText)
    end

    tooltip.description = table.concat(lines, " <LINE> ")
    return tooltip
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Build the complete cart options submenu
--- Structure:
---   Cart (Name) ▸
---     ├── Push Cart
---     ├── Repair Cart
---     └── Flashlight ▸
---           ├── Install Flashlight / Turn On/Off
---           ├── Insert/Remove Battery
---           └── Battery: X%
---
---@param context ISContextMenu The parent context menu
---@param playerObj IsoPlayer The player
---@param cart InventoryItem The cart item
---@param cartName string Display name for the cart
---@param isWorldCart boolean True if cart is on the ground
---@param pushHandler function|nil Handler for push action (nil if not applicable)
---@param pushArgs table|nil Arguments for push handler
---@param worldObj IsoWorldInventoryObject|nil The world object if cart is on ground
function CartSubmenu.addCartOptionsSubmenu(context, playerObj, cart, cartName, isWorldCart, pushHandler, pushArgs, worldObj)
    local cartText = getTextOrFallback("UI_SaucedCarts_Cart", "Cart") .. " (" .. cartName .. ")"

    -- Create parent "Cart (Name)" option
    local parentOption = context:addOption(cartText)
    local submenu = ISContextMenu:getNew(context)
    context:addSubMenu(parentOption, submenu)

    -- Add cart icon
    local texture = cart:getTexture()
    if texture then
        parentOption.iconTexture = texture
    end

    -- Add condition tooltip to parent
    parentOption.toolTip = createCartTooltip(cart, cartName, nil)

    -- 1. Push Cart option (if handler provided - not for equipped carts)
    if pushHandler then
        local pushText = getTextOrFallback("UI_SaucedCarts_PushCart", "Push Cart")
        local restArgs = pushArgs.restArgs or {}
        local pushOption = submenu:addOption(pushText, pushArgs.firstArg, pushHandler, unpack(restArgs))

        -- Disable if sleeping
        if playerObj:isAsleep() then
            pushOption.notAvailable = true
            local tooltip = ISWorldObjectContextMenu.addToolTip()
            tooltip:setVisible(false)
            local sleepText = isWorldCart
                and (getText("UI_SaucedCarts_CantPickupSleeping") or "Cannot pick up while sleeping")
                or (getText("UI_SaucedCarts_CantPushSleeping") or "Cannot push while sleeping")
            tooltip.description = "<RGB:1,0.5,0.5>" .. sleepText
            pushOption.toolTip = tooltip
        end
    end

    -- 2. Repair Cart option (if damaged)
    local condition = cart:getCondition()
    local conditionMax = cart:getConditionMax()
    if condition < conditionMax then
        RepairMenu.addRepairOption(submenu, playerObj, cart, isWorldCart)
    end

    -- 3. Flashlight submenu
    FlashlightMenu.buildFlashlightSubmenu(submenu, playerObj, cart, isWorldCart)

    -- 4. Fire event for addon extensions
    -- Addons can hook this to add their own upgrade submenus
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onBuildCartSubmenu, submenu, playerObj, cart, isWorldCart)
    end
end

SaucedCarts.debug("ContextMenu/CartSubmenu loaded")

return CartSubmenu
