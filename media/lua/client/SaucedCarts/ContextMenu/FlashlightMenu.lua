-- ============================================================================
-- SaucedCarts/ContextMenu/FlashlightMenu.lua
-- ============================================================================
-- PURPOSE: Flashlight upgrade context menu options for carts.
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"
require "SaucedCarts/TimedActions/ISInstallFlashlightAction"
require "SaucedCarts/TimedActions/ISInsertBatteryAction"
require "SaucedCarts/TimedActions/ISRemoveBatteryAction"
require "SaucedCarts/TimedActions/ISRemoveFlashlightAction"

---@class SaucedCartsFlashlightMenu
local FlashlightMenu = {}

-- ----------------------------------------------------------------------------
-- base:flashlight tag resolution
-- ----------------------------------------------------------------------------
-- InventoryItem exposes ONLY hasTag(ItemTag) — there is no hasTag(String)
-- overload, and Kahlua's missing-overload RuntimeException is NOT containable
-- by pcall (2026-08-07: the recursive flashlight sweep crashed the context
-- menu on a Base.IDcard exactly this way). Resolve the ItemTag object once,
-- the way vanilla does (ISMapSymbolDialog.lua:45), and only ever pass THAT
-- to hasTag. Lazy so we never race script/tag registration at Lua load.
local flashlightTag, flashlightTagResolved = nil, false

local function getFlashlightTag()
    if flashlightTagResolved then return flashlightTag end
    flashlightTagResolved = true
    if ItemTag and ItemTag.get and ResourceLocation and ResourceLocation.of then
        local ok, tag = pcall(function()
            return ItemTag.get(ResourceLocation.of("base:flashlight"))
        end)
        if ok and tag then flashlightTag = tag end
    end
    return flashlightTag
end

--- Test seam: the offline kit has no ItemTag/ResourceLocation globals, so
--- tests inject a sentinel here and key their mock _tags tables off it.
function FlashlightMenu._setFlashlightTag(tag)
    flashlightTag, flashlightTagResolved = tag, true
end

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

--- Vanilla handheld lights, matched by type regardless of tags/category.
local EXPLICIT_FLASHLIGHT_TYPES = {
    ["Base.Torch"] = true,
    ["Base.HandTorch"] = true,
    ["Base.FlashLight_AngleHead"] = true,
    ["Base.FlashLight_AngleHead_Army"] = true,
    ["Base.Flashlight_Crafted"] = true,
    ["Base.PenLight"] = true,
}

--- True if the item's light comes from a mounted weapon part rather than from
--- the item itself.
---
--- This is the whole reason the loose heuristics below are fenced off.
--- HandWeapon delegates every light getter to its attached part:
---
---   isTorchCone()    -> activeLight.isTorchCone()    || super   (HandWeapon.java:2600)
---   getLightDistance()-> activeLight.getLightDistance()          (HandWeapon.java:2610)
---   canBeActivated() -> activeLight.canBeActivated()             (HandWeapon.java:2615)
---
--- Base.GunLight is a WeaponPart with ActivatedItem = true and
--- LightDistance = 15, so an M1911 with one mounted is indistinguishable from
--- a flashlight by any light property. A player lost exactly that pistol to
--- "Install Flashlight" - the install consumes the item outright.
---@param item InventoryItem
---@return boolean
local function isWeaponWithMountedLight(item)
    if not instanceof(item, "HandWeapon") then return false end
    if not item.getActiveLight then
        -- Older build without the accessor: can't distinguish, so don't gamble
        -- with an item we're about to destroy.
        return true
    end
    local success, part = pcall(function() return item:getActiveLight() end)
    if not success then return true end
    return part ~= nil
end

--- Check if an item is a flashlight that can be installed on a cart
---@param item InventoryItem
---@return boolean
local function isInstallableFlashlight(item)
    if not item then return false end

    -- Skip containers (carts, bags, etc.) - they're not flashlights
    if instanceof(item, "InventoryContainer") then
        return false
    end

    -- A gun wearing a light is a gun.
    if isWeaponWithMountedLight(item) then
        return false
    end

    local fullType = item:getFullType()
    if not fullType then return false end

    -- Check explicit vanilla flashlight types
    -- Base.Torch = big flashlight, Base.HandTorch = small flashlight
    if EXPLICIT_FLASHLIGHT_TYPES[fullType] then
        return true
    end

    -- B42 tags handheld lights with base:flashlight (drainable.txt; note
    -- Torch/HandTorch carry no tag — they're caught by the explicit types
    -- and LightSource category instead). Best signal for modded lights.
    -- MUST pass the resolved ItemTag, never a string — see getFlashlightTag.
    local tag = getFlashlightTag()
    if tag and item.hasTag then
        local success, tagged = pcall(function() return item:hasTag(tag) end)
        if success and tagged then
            return true
        end
    end

    -- DisplayCategory = LightSource is what vanilla marks handheld lights with.
    if item.getDisplayCategory then
        local success, category = pcall(function() return item:getDisplayCategory() end)
        if success and category == "LightSource" then
            return true
        end
    end

    -- Fallback for untagged/uncategorised modded lights. Weapons never reach
    -- this: a HandWeapon with no mounted light is still a weapon, and one with
    -- a mounted light was rejected up top. Both cone AND distance are required
    -- so lighters (LightDistance = 5, TorchCone = false) don't qualify.
    if instanceof(item, "HandWeapon") then
        return false
    end

    local hasCone = false
    if item.isTorchCone then
        local success, result = pcall(function() return item:isTorchCone() end)
        hasCone = success and result == true
    end
    if not hasCone then return false end

    if item.getLightDistance then
        local success, result = pcall(function() return item:getLightDistance() end)
        if success and result and result > 0 then
            return true
        end
    end

    return false
end

--- Check if an item is a battery
---@param item InventoryItem
---@return boolean
local function isBattery(item)
    if not item then return false end
    local fullType = item:getFullType()
    return fullType == "Base.Battery"
end

-- ============================================================================
-- ATTACHMENT MATERIALS
-- ============================================================================

--- Attachment materials in priority order (best first)
--- @type table[]
local ATTACHMENT_MATERIALS = {
    { type = "Base.DuctTape", uses = 1, name = "Duct Tape" },
    { type = "Base.Zipties", uses = 1, name = "Zip Ties" },
    { type = "Base.Scotchtape", uses = 1, name = "Adhesive Tape" },
    { type = "Base.Rope", uses = 1, name = "Rope" },
    { type = "Base.Twine", uses = 2, name = "Twine" },
}

--- Find an attachment material item with enough uses
---@param playerObj IsoPlayer
---@param materialType string Item full type
---@param usesNeeded number Uses required
---@return InventoryItem|nil item The found item or nil
local function findMaterialWithUses(playerObj, materialType, usesNeeded)
    local inv = playerObj:getInventory()
    local items = inv:getAllTypeRecurse(materialType)
    if not items then return nil end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        -- Drainable items use getCurrentUses(), non-drainable use getUsesRemaining()
        local uses = 0
        if item.getCurrentUses then
            uses = item:getCurrentUses()
        elseif item.getUsesRemaining then
            uses = item:getUsesRemaining()
        else
            -- Stackable/single-use items count as 1 use per item
            uses = 1
        end
        if uses >= usesNeeded then
            return item
        end
    end
    return nil
end

--- Find the best available attachment material
---@param playerObj IsoPlayer
---@return table|nil materialInfo {type, uses, name, item} or nil if none found
local function findBestAttachmentMaterial(playerObj)
    for _, mat in ipairs(ATTACHMENT_MATERIALS) do
        local item = findMaterialWithUses(playerObj, mat.type, mat.uses)
        if item then
            return { type = mat.type, uses = mat.uses, name = mat.name, item = item }
        end
    end
    return nil
end

--- Check if player has any attachment material for flashlight installation
---@param playerObj IsoPlayer
---@return boolean hasMaterial
---@return table|nil materialInfo Best available material info
local function hasAttachmentMaterial(playerObj)
    local material = findBestAttachmentMaterial(playerObj)
    if material then
        return true, material
    end
    return false, nil
end

--- Get all available attachment materials (for tooltip)
---@param playerObj IsoPlayer
---@return table[] availableMaterials Array of {name, uses, hasEnough}
local function getAvailableMaterials(playerObj)
    local available = {}
    for _, mat in ipairs(ATTACHMENT_MATERIALS) do
        local item = findMaterialWithUses(playerObj, mat.type, mat.uses)
        table.insert(available, {
            name = mat.name,
            uses = mat.uses,
            hasEnough = item ~= nil
        })
    end
    return available
end

--- Build detailed requirements tooltip showing available materials
---@param playerObj IsoPlayer
---@param flashlightName string
---@return string tooltipDescription
local function buildRequirementsTooltip(playerObj, flashlightName)
    local lines = {}

    table.insert(lines, getText("UI_SaucedCarts_InstallFlashlightTooltip") or "Attach flashlight to cart")
    table.insert(lines, " ")
    table.insert(lines, "<RGB:1,1,0>Requirements:")

    -- Flashlight (always have it if we got here)
    table.insert(lines, "<RGB:0.2,0.9,0.2> - 1x " .. flashlightName .. " (consumed)")

    -- Attachment material
    table.insert(lines, " ")
    table.insert(lines, "<RGB:1,1,0>Attachment material (one of):")

    local materials = getAvailableMaterials(playerObj)
    local hasAny = false
    for _, mat in ipairs(materials) do
        local color = mat.hasEnough and "<RGB:0.2,0.9,0.2>" or "<RGB:0.6,0.6,0.6>"
        local usesText = mat.uses > 1 and (" (" .. mat.uses .. " uses)") or ""
        table.insert(lines, color .. " - " .. mat.name .. usesText)
        if mat.hasEnough then hasAny = true end
    end

    if not hasAny then
        table.insert(lines, " ")
        table.insert(lines, "<RGB:1,0.3,0.3>No attachment material available!")
    end

    table.insert(lines, " ")
    table.insert(lines, "<RGB:1,0.5,0>" .. getTextOrFallback("UI_SaucedCarts_InstallFlashlightWarning",
        "The flashlight is consumed. Removing it later returns a stock one."))

    return table.concat(lines, " <LINE> ")
end

--- Recursively search containers for items matching a predicate
---@param container ItemContainer The container to search
---@param predicate function(item) Returns true if item matches
---@param results table Array to add matching items to
---@param visited table Set of visited container IDs to avoid infinite loops
local function searchContainerRecursive(container, predicate, results, visited)
    if not container then return end

    -- Avoid infinite loops from nested containers
    local containerId = tostring(container)
    if visited[containerId] then return end
    visited[containerId] = true

    local items = container:getItems()
    if not items then return end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            -- Check if item matches
            if predicate(item) then
                table.insert(results, item)
            end

            -- Recurse into sub-containers (bags, etc.) but NOT carts
            if instanceof(item, "InventoryContainer") and not SaucedCarts.isCart(item) then
                local subContainer = item:getItemContainer()
                if subContainer then
                    searchContainerRecursive(subContainer, predicate, results, visited)
                end
            end
        end
    end
end

-- ============================================================================
-- INVENTORY SEARCH
-- ============================================================================

--- Find all batteries in player's inventory (recurse into bags)
---@param playerObj IsoPlayer
---@return table batteries Array of battery items
local function findBatteries(playerObj)
    local batteries = {}
    local inv = playerObj:getInventory()
    if not inv then return batteries end

    searchContainerRecursive(inv, function(item)
        return isBattery(item) and item:getCurrentUsesFloat() > 0
    end, batteries, {})

    return batteries
end

--- Find all flashlights in player's inventory (recurse into bags)
---@param playerObj IsoPlayer
---@return table flashlights Array of flashlight items
local function findFlashlights(playerObj)
    local flashlights = {}
    local inv = playerObj:getInventory()
    if not inv then return flashlights end

    searchContainerRecursive(inv, function(item)
        return isInstallableFlashlight(item)
    end, flashlights, {})

    return flashlights
end

--- Find all nearby carts that can have flashlight installed
---@param playerObj IsoPlayer
---@param includeEquipped boolean Include equipped cart
---@return table carts Array of {item, isEquipped, worldObj, squareX, squareY, squareZ}
local function findUpgradeableCarts(playerObj, includeEquipped)
    local carts = {}

    -- Check equipped cart
    if includeEquipped then
        local primary = playerObj:getPrimaryHandItem()
        if primary and SaucedCarts.isCart(primary) then
            local canInstall, _ = SaucedCarts.Upgrades.canInstallFlashlight(primary)
            if canInstall then
                table.insert(carts, {
                    item = primary,
                    isEquipped = true,
                    worldObj = nil,
                    name = SaucedCarts.getCartDisplayName(primary),
                })
            end
        end
    end

    -- Check nearby ground carts
    local playerSquare = playerObj:getCurrentSquare()
    if playerSquare then
        local seen = {}
        for dy = -2, 2 do
            for dx = -2, 2 do
                local square = getCell():getGridSquare(
                    playerSquare:getX() + dx,
                    playerSquare:getY() + dy,
                    playerSquare:getZ()
                )
                if square and playerSquare:canReachTo(square) then
                    local objects = square:getWorldObjects()
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if instanceof(obj, "IsoWorldInventoryObject") then
                            local item = obj:getItem()
                            if item and SaucedCarts.isCart(item) then
                                local cartId = item:getID()
                                if not seen[cartId] then
                                    seen[cartId] = true
                                    local canInstall, _ = SaucedCarts.Upgrades.canInstallFlashlight(item)
                                    if canInstall then
                                        table.insert(carts, {
                                            item = item,
                                            isEquipped = false,
                                            worldObj = obj,
                                            squareX = square:getX(),
                                            squareY = square:getY(),
                                            squareZ = square:getZ(),
                                            name = SaucedCarts.getCartDisplayName(item),
                                        })
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return carts
end

-- ============================================================================
-- ACTION HANDLERS
-- ============================================================================

--- Handle flashlight toggle (context menu version)
---@param items table Items from context
---@param player number Player index
---@param cart InventoryItem The cart
local function onToggleFlashlight(items, player, cart)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or not cart then return end

    -- Use toggleFlashlightLocal for unified tracking (SP battery drain + MP sync prep)
    require "SaucedCarts/UpgradeSync"
    local newState, success = SaucedCarts.UpgradeSync.toggleFlashlightLocal(cart, playerObj)

    -- Request MP sync (server also needs to know for broadcasting to other clients)
    if success and isClient() then
        if SaucedCarts.UpgradeSync then
            SaucedCarts.UpgradeSync.requestToggle(playerObj, cart:getID())
        end
    end
end

--- Handle install flashlight
---@param items table Items from context
---@param player number Player index
---@param cart InventoryItem The cart
---@param flashlight InventoryItem The flashlight
---@param materialInfo table Material info {type, uses, name, item}
local function onInstallFlashlight(items, player, cart, flashlight, materialInfo)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or not cart or not flashlight or not materialInfo then return end

    local action = ISInstallFlashlightAction.FromItems(playerObj, cart, flashlight, materialInfo.type, materialInfo.uses)
    ISTimedActionQueue.add(action)
end

--- Handle remove flashlight
---@param items table Items from context
---@param player number Player index
---@param cart InventoryItem The cart
local function onRemoveFlashlight(items, player, cart)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or not cart then return end

    local action = ISRemoveFlashlightAction.FromCart(playerObj, cart)
    ISTimedActionQueue.add(action)
end

--- Handle insert battery
---@param items table Items from context
---@param player number Player index
---@param cart InventoryItem The cart
---@param battery InventoryItem The battery
local function onInsertBattery(items, player, cart, battery)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or not cart or not battery then return end

    local action = ISInsertBatteryAction.FromItems(playerObj, cart, battery)
    ISTimedActionQueue.add(action)
end

--- Handle remove battery
---@param items table Items from context
---@param player number Player index
---@param cart InventoryItem The cart
local function onRemoveBattery(items, player, cart)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or not cart then return end

    local action = ISRemoveBatteryAction.FromCart(playerObj, cart)
    ISTimedActionQueue.add(action)
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Check if an item is a flashlight that can be installed
---@param item InventoryItem
---@return boolean
function FlashlightMenu.isInstallableFlashlight(item)
    return isInstallableFlashlight(item)
end

--- Find all flashlights in player's inventory
---@param playerObj IsoPlayer
---@return table flashlights
function FlashlightMenu.findFlashlights(playerObj)
    return findFlashlights(playerObj)
end

--- Find all batteries in player's inventory
---@param playerObj IsoPlayer
---@return table batteries
function FlashlightMenu.findBatteries(playerObj)
    return findBatteries(playerObj)
end

--- Add "Install on Cart" option to flashlight context menu
---@param context ISContextMenu The context menu
---@param playerObj IsoPlayer The player
---@param flashlight InventoryItem The flashlight item
function FlashlightMenu.addInstallOnCartOption(context, playerObj, flashlight)
    -- Find carts that can have flashlight installed
    local carts = findUpgradeableCarts(playerObj, true)

    if #carts == 0 then
        return
    end

    local installText = getTextOrFallback("UI_SaucedCarts_InstallOnCart", "Install on Cart")

    -- onInstallFlashlight bails without materialInfo, so this has to be
    -- resolved here too - passing it was previously missed and the option
    -- did nothing at all when clicked.
    local hasMaterial, materialInfo = hasAttachmentMaterial(playerObj)
    local flashlightName = flashlight:getDisplayName() or "Flashlight"

    --- Attach the requirements tooltip / availability state to one option
    local function configureOption(option)
        local tooltip = ISWorldObjectContextMenu.addToolTip()
        tooltip:setVisible(false)
        tooltip.description = buildRequirementsTooltip(playerObj, flashlightName)
        option.toolTip = tooltip
        if not hasMaterial then
            option.notAvailable = true
        end
    end

    if #carts == 1 then
        -- Single cart: add directly
        local cart = carts[1]
        local optionText = installText .. " (" .. cart.name .. ")"
        local option = context:addOption(optionText, {}, onInstallFlashlight, playerObj:getPlayerNum(), cart.item, flashlight, materialInfo)
        option.iconTexture = cart.item:getTexture()
        configureOption(option)
    else
        -- Multiple carts: submenu
        local parentOption = context:addOption(installText)
        local submenu = ISContextMenu:getNew(context)
        context:addSubMenu(parentOption, submenu)

        for _, cart in ipairs(carts) do
            local locationText = cart.isEquipped and " (equipped)" or " (ground)"
            local option = submenu:addOption(cart.name .. locationText, {}, onInstallFlashlight, playerObj:getPlayerNum(), cart.item, flashlight, materialInfo)
            option.iconTexture = cart.item:getTexture()
            configureOption(option)
        end
    end
end

--- Build flashlight submenu for a cart
--- Called by CartSubmenu to build the flashlight portion of the cart menu
---@param submenu ISContextMenu The parent submenu to add flashlight options to
---@param playerObj IsoPlayer The player
---@param cart InventoryItem The cart item
---@param isWorldCart boolean True if cart is on ground (not equipped)
function FlashlightMenu.buildFlashlightSubmenu(submenu, playerObj, cart, isWorldCart)
    local hasFlashlight = SaucedCarts.Upgrades.hasFlashlight(cart)
    local flashlights = findFlashlights(playerObj)
    local hasFlashlightInInventory = #flashlights > 0

    -- Only show Flashlight submenu if relevant (has upgrade or can install)
    local canHaveFlashlight = SaucedCarts.Upgrades.canHaveFlashlight(cart)

    if canHaveFlashlight and (hasFlashlight or hasFlashlightInInventory) then
        local flashlightText = getTextOrFallback("UI_SaucedCarts_Flashlight", "Flashlight")
        local flashlightParent = submenu:addOption(flashlightText)
        local flashlightSubmenu = ISContextMenu:getNew(submenu)
        submenu:addSubMenu(flashlightParent, flashlightSubmenu)
        flashlightParent.iconTexture = getTexture("Item_Torch")

        if hasFlashlight then
            -- Cart has flashlight installed - show control options
            local charge = SaucedCarts.Upgrades.getBatteryCharge(cart)
            local isActive = SaucedCarts.Upgrades.isLightActive(cart)
            local hasBattery = charge > 0

            -- Check if cart is equipped
            local primary = playerObj:getPrimaryHandItem()
            local isEquipped = primary and primary:getID() == cart:getID()

            -- Toggle On/Off
            local toggleText = isActive
                and getTextOrFallback("UI_SaucedCarts_TurnOff", "Turn Off")
                or getTextOrFallback("UI_SaucedCarts_TurnOn", "Turn On")

            local toggleOption = flashlightSubmenu:addOption(toggleText, {}, onToggleFlashlight, playerObj:getPlayerNum(), cart)

            if isWorldCart or not isEquipped then
                toggleOption.notAvailable = true
                local tooltip = ISWorldObjectContextMenu.addToolTip()
                tooltip:setVisible(false)
                tooltip.description = "<RGB:0.7,0.7,0.7>" .. (getText("UI_SaucedCarts_MustEquipCart") or "Must be pushing cart to use flashlight")
                toggleOption.toolTip = tooltip
            elseif not hasBattery then
                toggleOption.notAvailable = true
                local tooltip = ISWorldObjectContextMenu.addToolTip()
                tooltip:setVisible(false)
                tooltip.description = "<RGB:0.9,0.6,0.1>" .. (getText("UI_SaucedCarts_NoBattery") or "No battery!")
                toggleOption.toolTip = tooltip
            end

            -- Insert Battery (if player has battery)
            local batteries = findBatteries(playerObj)
            if #batteries > 0 then
                table.sort(batteries, function(a, b) return a:getCurrentUsesFloat() > b:getCurrentUsesFloat() end)
                local bestBattery = batteries[1]
                local insertText = getTextOrFallback("UI_SaucedCarts_InsertBattery", "Insert Battery")
                local batteryPercent = math.floor(bestBattery:getCurrentUsesFloat() * 100)
                insertText = insertText .. " (" .. batteryPercent .. "%)"
                flashlightSubmenu:addOption(insertText, {}, onInsertBattery, playerObj:getPlayerNum(), cart, bestBattery)
            end

            -- Remove Battery (if cart has charge)
            if hasBattery then
                local removeText = getTextOrFallback("UI_SaucedCarts_RemoveBattery", "Remove Battery")
                flashlightSubmenu:addOption(removeText, {}, onRemoveBattery, playerObj:getPlayerNum(), cart)
            end

            -- Remove Flashlight (undoes the install, hands the light back)
            local flashlightData = SaucedCarts.Upgrades.getFlashlightData(cart)
            local removeText = getTextOrFallback("UI_SaucedCarts_RemoveFlashlight", "Remove Flashlight")
            local removeOption = flashlightSubmenu:addOption(removeText, {}, onRemoveFlashlight, playerObj:getPlayerNum(), cart)
            removeOption.iconTexture = getTexture("Item_Torch")

            local removeTooltip = ISWorldObjectContextMenu.addToolTip()
            removeTooltip:setVisible(false)
            local removeLines = {}
            table.insert(removeLines, "<RGB:1,1,0>" .. getTextOrFallback("UI_SaucedCarts_RemoveFlashlightReturns", "Returns:"))
            table.insert(removeLines, "<RGB:0.2,0.9,0.2> - 1x " ..
                ((flashlightData and flashlightData.originalName) or "Flashlight"))
            if hasBattery then
                table.insert(removeLines, "<RGB:0.2,0.9,0.2> - 1x Battery (" .. math.floor(charge * 100) .. "%)")
            end
            table.insert(removeLines, " ")
            table.insert(removeLines, "<RGB:0.7,0.7,0.7>" .. getTextOrFallback("UI_SaucedCarts_RemoveFlashlightNote",
                "Comes back stock. Attachments, ammo and condition are not restored, and the tape is not recovered."))
            removeTooltip.description = table.concat(removeLines, " <LINE> ")
            removeOption.toolTip = removeTooltip

            -- Battery status (info only)
            local batteryPercent = math.floor(charge * 100)
            local statusText = getTextOrFallback("UI_SaucedCarts_BatteryStatus", "Battery") .. ": " .. batteryPercent .. "%"
            local statusOption = flashlightSubmenu:addOption(statusText, nil, nil)
            statusOption.notAvailable = true
            local statusTooltip = ISWorldObjectContextMenu.addToolTip()
            statusTooltip:setVisible(false)
            if batteryPercent >= 50 then
                statusTooltip.description = "<RGB:0.2,0.8,0.2>" .. statusText
            elseif batteryPercent >= 25 then
                statusTooltip.description = "<RGB:0.9,0.6,0.1>" .. statusText
            else
                statusTooltip.description = "<RGB:0.9,0.2,0.2>" .. statusText
            end
            statusOption.toolTip = statusTooltip
        else
            -- No flashlight installed - show install option(s).
            --
            -- NEVER auto-pick from `flashlights`. The chosen item is destroyed,
            -- and this used to take flashlights[1] straight off a recursive
            -- inventory sweep - whichever candidate the walk happened to reach
            -- first. Anything with more than one candidate goes to a submenu so
            -- the player names the item they're giving up.
            local installText = getTextOrFallback("UI_SaucedCarts_InstallFlashlight", "Install Flashlight")

            -- Check attachment material requirements
            local hasMaterial, materialInfo = hasAttachmentMaterial(playerObj)

            -- Stable ordering so the list doesn't reshuffle between openings
            table.sort(flashlights, function(a, b)
                local an, bn = a:getDisplayName() or "", b:getDisplayName() or ""
                if an == bn then return a:getID() < b:getID() end
                return an < bn
            end)

            --- Attach the install handler + requirements tooltip to one option
            local function configureInstallOption(option, flashlight, flashlightName)
                option.iconTexture = flashlight:getTexture() or getTexture("Item_Torch")

                local tooltip = ISWorldObjectContextMenu.addToolTip()
                tooltip:setVisible(false)
                tooltip.description = buildRequirementsTooltip(playerObj, flashlightName)
                option.toolTip = tooltip

                if not hasMaterial then
                    option.notAvailable = true
                end
            end

            if #flashlights == 1 then
                local flashlight = flashlights[1]
                local flashlightName = flashlight:getDisplayName() or "Flashlight"
                local option = flashlightSubmenu:addOption(
                    installText .. " (" .. flashlightName .. ")",
                    {}, onInstallFlashlight, playerObj:getPlayerNum(), cart, flashlight, materialInfo)
                configureInstallOption(option, flashlight, flashlightName)
            else
                local parentOption = flashlightSubmenu:addOption(installText)
                parentOption.iconTexture = getTexture("Item_Torch")
                local pickSubmenu = ISContextMenu:getNew(flashlightSubmenu)
                flashlightSubmenu:addSubMenu(parentOption, pickSubmenu)

                for _, flashlight in ipairs(flashlights) do
                    local flashlightName = flashlight:getDisplayName() or "Flashlight"
                    local option = pickSubmenu:addOption(flashlightName, {}, onInstallFlashlight,
                        playerObj:getPlayerNum(), cart, flashlight, materialInfo)
                    configureInstallOption(option, flashlight, flashlightName)
                end
            end
        end
    elseif canHaveFlashlight then
        -- Can have flashlight but no flashlight available - show greyed option
        local flashlightText = getTextOrFallback("UI_SaucedCarts_Flashlight", "Flashlight")
        local flashlightOption = submenu:addOption(flashlightText)
        flashlightOption.notAvailable = true
        flashlightOption.iconTexture = getTexture("Item_Torch")
        local tooltip = ISWorldObjectContextMenu.addToolTip()
        tooltip:setVisible(false)
        tooltip.description = "<RGB:0.7,0.7,0.7>" .. (getText("UI_SaucedCarts_NoFlashlightAvailable") or "No flashlight in inventory")
        flashlightOption.toolTip = tooltip
    end
end

SaucedCarts.debug("ContextMenu/FlashlightMenu loaded")

return FlashlightMenu
