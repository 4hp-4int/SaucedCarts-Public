-- ============================================================================
-- SaucedCarts/ContextMenu/RepairMenu.lua
-- ============================================================================
-- PURPOSE: Repair context menu options for carts.
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"
require "SaucedCarts/TimedActions/ISCartRepairAction"

---@class SaucedCartsRepairMenu
local RepairMenu = {}

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

--- Find repair item in player inventory or cart contents
---@param playerObj IsoPlayer The player
---@param cart InventoryItem The cart to repair
---@param repairItemType string Full item type (e.g., "Base.ScrapMetal")
---@return InventoryItem|nil The repair item, or nil if not found
local function findRepairItem(playerObj, cart, repairItemType)
    -- Check player inventory first (recurse into bags)
    local playerInv = playerObj:getInventory()
    if playerInv then
        local item = playerInv:getFirstTypeRecurse(repairItemType)
        if item then return item end
    end

    -- Check cart contents
    local cartContainer = cart:getItemContainer()
    if cartContainer then
        local item = cartContainer:getFirstType(repairItemType)
        if item then return item end
    end

    return nil
end

--- Get display name for an item type
---@param fullType string Full item type (e.g., "Base.ScrapMetal")
---@return string Display name
local function getItemDisplayName(fullType)
    local scriptItem = ScriptManager.instance:getItem(fullType)
    if scriptItem then
        return scriptItem:getDisplayName() or fullType
    end
    -- Fallback: extract item name from fullType
    return fullType:match("%.(.+)$") or fullType
end

-- ============================================================================
-- TOOLTIP CREATION
-- ============================================================================

--- Create a tooltip for the repair option
---@param cart InventoryItem The cart to repair
---@param repairItemType string The repair material type
---@param playerObj IsoPlayer The player (for skill calculation)
---@return ISToolTip
local function createRepairTooltip(cart, repairItemType, playerObj)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip:setVisible(false)

    local lines = {}

    -- Get CartData repair parameters
    local cartData = SaucedCarts.getCartData(cart)
    local baseRepairAmount = (cartData and cartData.repairAmount) or 10
    local repairSkillBonus = (cartData and cartData.repairSkillBonus) or 1
    local repairSkill = (cartData and cartData.repairSkill) or Perks.Maintenance

    -- Get sandbox options
    local repairAmountMult = SandboxVars.SaucedCarts.RepairAmountMultiplier or 100
    local skillBonusEnabled = SandboxVars.SaucedCarts.MaintenanceSkillBonus
    if skillBonusEnabled == nil then skillBonusEnabled = true end

    -- Calculate skill contribution
    local skillLevel = 0
    local skillContribution = 0
    if skillBonusEnabled and repairSkill and playerObj then
        skillLevel = playerObj:getPerkLevel(repairSkill)
        skillContribution = skillLevel * repairSkillBonus
    end

    -- Calculate final repair amount
    local finalRepairAmount = math.floor((baseRepairAmount + skillContribution) * repairAmountMult / 100)
    finalRepairAmount = math.max(1, finalRepairAmount)

    -- Cap at remaining condition needed
    local condition = cart:getCondition()
    local conditionMax = cart:getConditionMax()
    local restoreAmount = math.min(finalRepairAmount, conditionMax - condition)

    -- Show how much will be restored
    local restoreText = getText("UI_SaucedCarts_RepairTooltip_Restores") or "Restores %1 condition"
    restoreText = restoreText:gsub("%%1", tostring(restoreAmount))
    table.insert(lines, "<RGB:0.2,0.8,0.2>" .. restoreText)

    -- Show skill bonus if applicable
    if skillBonusEnabled and skillContribution > 0 then
        local skillBonusText = getText("UI_SaucedCarts_RepairTooltip_SkillBonus") or "Skill bonus: +%1"
        skillBonusText = skillBonusText:gsub("%%1", tostring(skillContribution))
        table.insert(lines, "<RGB:0.5,0.7,1.0>" .. skillBonusText)
    end

    -- Show current condition
    local currentText = getText("UI_SaucedCarts_RepairTooltip_Current") or "Current: %1/%2"
    currentText = currentText:gsub("%%1", tostring(condition)):gsub("%%2", tostring(conditionMax))
    table.insert(lines, currentText)

    -- Show material used
    local itemName = getItemDisplayName(repairItemType)
    local requiresText = getText("UI_SaucedCarts_RepairTooltip_Requires") or "Requires: %1"
    requiresText = requiresText:gsub("%%1", itemName)
    table.insert(lines, requiresText)

    tooltip.description = table.concat(lines, " <LINE> ")
    return tooltip
end

--- Create a tooltip explaining what's needed to repair
---@param cart InventoryItem The cart to repair
---@param repairItemType string The repair material type
---@return ISToolTip
local function createRepairNeededTooltip(cart, repairItemType)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip:setVisible(false)

    local lines = {}

    -- Show what's needed
    local itemName = getItemDisplayName(repairItemType)
    local needText = getText("UI_SaucedCarts_RepairTooltip_NeedMaterial") or "Need %1 to repair"
    needText = needText:gsub("%%1", itemName)
    table.insert(lines, "<RGB:0.9,0.6,0.1>" .. needText)

    -- Show current condition. Inline-concatenating a trailing "%" hit a
    -- weird PZ tooltip-render bug for some users (visible as "$s" in the
    -- tooltip — looks like a downstream format pass eats the literal "%").
    -- Vanilla translations encode literal percent via "%%" inside getText
    -- (e.g. UI_GameLoad_humidity = "Humidity: %.1f %%"); doing the same
    -- here routes the substitution through the translator and renders
    -- cleanly across all locales.
    local condition = cart:getCondition()
    local conditionMax = cart:getConditionMax()
    local conditionPercent = math.floor((condition / conditionMax) * 100)
    local colorTag = getConditionColorTag(conditionPercent)
    local conditionLine = getText("UI_SaucedCarts_RepairTooltip_ConditionPercent",
        tostring(conditionPercent))
    table.insert(lines, colorTag .. " " .. conditionLine)

    tooltip.description = table.concat(lines, " <LINE> ")
    return tooltip
end

-- ============================================================================
-- REPAIR HANDLER
-- ============================================================================

--- Handle repairing a cart
--- World menu callback: (playerNum, cart, repairItem)
--- Inventory menu callback: (items, playerNum, cart, repairItem)
---@param arg1 number|table Player index (world menu) or items table (inventory menu)
---@param arg2 InventoryItem|number Cart (world menu) or player index (inventory menu)
---@param arg3 InventoryItem|nil Repair item (world menu) or cart (inventory menu)
---@param arg4 InventoryItem|nil Repair item (inventory menu only)
local function onRepairCart(arg1, arg2, arg3, arg4)
    local playerObj, cartItem, repairMaterial

    if type(arg1) == "number" then
        -- World menu: (playerNum, cart, repairItem)
        playerObj = getSpecificPlayer(arg1)
        cartItem = arg2
        repairMaterial = arg3
    elseif type(arg1) == "table" and type(arg2) == "number" then
        -- Inventory menu: (items, playerNum, cart, repairItem)
        playerObj = getSpecificPlayer(arg2)
        cartItem = arg3
        repairMaterial = arg4
    else
        SaucedCarts.error("onRepairCart: invalid arguments - arg1=" .. type(arg1) .. ", arg2=" .. type(arg2))
        return
    end

    if not playerObj or not cartItem or not repairMaterial then
        SaucedCarts.error("onRepairCart: missing player, cart, or repair item")
        return
    end

    -- Queue the timed action
    local action = ISCartRepairAction.FromCart(playerObj, cartItem, repairMaterial)
    ISTimedActionQueue.add(action)
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Add repair option to a context menu for a cart
---@param context ISContextMenu The context menu
---@param playerObj IsoPlayer The player
---@param cart InventoryItem The cart item
---@param isWorldMenu boolean True if this is a world object context menu
function RepairMenu.addRepairOption(context, playerObj, cart, isWorldMenu)
    local condition = cart:getCondition()
    local conditionMax = cart:getConditionMax()

    -- Don't show repair if at max condition
    if condition >= conditionMax then
        return
    end

    -- Get repair requirements from CartData
    local cartData = SaucedCarts.getCartData(cart)
    local repairItemType = (cartData and cartData.repairItem) or "Base.ScrapMetal"

    -- Find repair material
    local repairItem = findRepairItem(playerObj, cart, repairItemType)

    -- Create option text. Append the material status inline so the player
    -- sees what they need without hovering for the tooltip — addresses
    -- "I had no idea what I was missing" feedback. Repair currently
    -- consumes one item of the configured type per action, so the
    -- shorthand is just "(have <Material>)" / "(need <Material>)".
    local materialName = getItemDisplayName(repairItemType)
    local repairBaseText = getTextOrFallback("UI_SaucedCarts_RepairCart", "Repair Cart")
    local statusText
    if repairItem then
        statusText = " (" ..
            getTextOrFallback("UI_SaucedCarts_RepairOption_Have", "have") ..
            " " .. materialName .. ")"
    else
        statusText = " (" ..
            getTextOrFallback("UI_SaucedCarts_RepairOption_Need", "need") ..
            " " .. materialName .. ")"
    end
    local repairText = repairBaseText .. statusText

    -- Add option
    -- ISContextMenu:addOption signature: (text, firstArg, callback, ...moreArgs)
    -- Callback receives: (firstArg, ...moreArgs)
    local option
    if isWorldMenu then
        -- World menu: callback gets (playerNum, cart, repairItem)
        option = context:addOption(repairText, playerObj:getPlayerNum(), onRepairCart, cart, repairItem)
    else
        -- Inventory menu: callback gets (items, playerNum, cart, repairItem)
        option = context:addOption(repairText, {}, onRepairCart, playerObj:getPlayerNum(), cart, repairItem)
    end

    -- Set icon
    option.iconTexture = getTexture("media/ui/Container_Toolbox.png")

    -- Set tooltip and availability
    if repairItem then
        -- Pass playerObj for skill calculation in tooltip
        option.toolTip = createRepairTooltip(cart, repairItemType, playerObj)
    else
        option.notAvailable = true
        option.toolTip = createRepairNeededTooltip(cart, repairItemType)
    end
end

SaucedCarts.debug("ContextMenu/RepairMenu loaded")

return RepairMenu
