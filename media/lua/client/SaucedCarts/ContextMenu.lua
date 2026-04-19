-- ============================================================================
-- SaucedCarts/ContextMenu.lua
-- ============================================================================
-- PURPOSE: Adds right-click menu options for picking up and dropping carts.
--          Handles world object context (carts on ground) and inventory
--          context (equipped carts).
--
-- CONTEXT: CLIENT ONLY
--          Context menus are client-side UI elements.
--
-- NOTE: Cart restriction hooks are in separate modules:
--       - Restrictions/GrabRestrictions.lua - Blocks grab from ground
--       - Restrictions/TransferRestrictions.lua - Blocks drag/drop transfers
--       - ContainerRestrictions.lua (shared) - Server-authoritative blocking
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"
require "SaucedCarts/CartData"
require "SaucedCarts/CartVisuals"
require "SaucedCarts/Upgrades"
require "SaucedCarts/TimedActions/ISCartPickupAction"
require "SaucedCarts/TimedActions/ISCartEquipAction"
require "SaucedCarts/TimedActions/ISCartRepairAction"
require "SaucedCarts/TimedActions/ISInstallFlashlightAction"
require "SaucedCarts/TimedActions/ISInsertBatteryAction"
require "SaucedCarts/TimedActions/ISRemoveBatteryAction"
require "SaucedCarts/OrphanRecovery"
require "TimedActions/ISDropWorldItemAction"

-- Load restriction modules (they self-initialize on OnGameStart)
require "SaucedCarts/Restrictions/GrabRestrictions"
require "SaucedCarts/Restrictions/TransferRestrictions"

-- Import context menu submodules
local FlashlightMenu = require "SaucedCarts/ContextMenu/FlashlightMenu"
local CartSubmenu = require "SaucedCarts/ContextMenu/CartSubmenu"

---@class SaucedCartsContextMenu
local ContextMenu = {}

-- ============================================================================
-- CART PICKUP HANDLERS
-- ============================================================================
-- Note: Cart dropping uses vanilla "Drop" action - no custom handler needed.

--- Handle pushing a cart (picking up from ground and equipping)
--- Uses timed action with MP sync
---@param worldObjects table Array of world objects from context
---@param player number Player index (0-3)
---@param worldObject IsoWorldInventoryObject The cart world object to pick up
local function onPushCartFromWorld(worldObjects, player, worldObject)
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end

    -- Queue the timed action (use FromWorldItem to extract serializable data)
    ISTimedActionQueue.add(ISCartPickupAction.FromWorldItem(playerObj, worldObject))
end

--- Handle equipping a cart from a container (player inventory or vehicle)
--- Uses timed action with MP sync for consistency with ground pickup
---@param items table Array of inventory items from context
---@param player number Player index (0-3)
---@param cart InventoryItem The cart item to equip
local function onPushCart(items, player, cart)
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end

    -- Queue the timed action (use FromCart to extract serializable data)
    ISTimedActionQueue.add(ISCartEquipAction.FromCart(playerObj, cart))
end

--- Handle picking up a cart from the loot panel (ground or vehicle container)
--- Routes to appropriate timed action based on cart location
---@param items table Array of inventory items from context
---@param player number Player index (0-3)
---@param cart InventoryItem The cart item to pick up
local function onPickupCartFromLoot(items, player, cart)
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    local cartId = cart:getID()

    -- First: check if cart is on the ground (has world item reference)
    local worldObj = cart:getWorldItem()
    if worldObj then
        SaucedCarts.debug(function() return "Cart on ground - using ISCartPickupAction for cart ID " .. tostring(cartId) end)
        onPushCartFromWorld(nil, player, worldObj)
        return
    end

    -- Second: check if cart is in a container (vehicle or other)
    local cartContainer = cart:getContainer()
    if cartContainer then
        local parent = cartContainer:getParent()
        if parent and instanceof(parent, "BaseVehicle") then
            -- Cart is in vehicle - ISCartEquipAction handles transfer + equip
            SaucedCarts.debug(function() return "Cart in vehicle - using ISCartEquipAction for cart ID " .. tostring(cartId) end)
            onPushCart(items, player, cart)
            return
        end
    end

    -- Fallback: Search nearby squares for world item (in case getWorldItem() failed)
    local playerSquare = playerObj:getCurrentSquare()
    if not playerSquare then return end

    local cx = playerSquare:getX()
    local cy = playerSquare:getY()
    local cz = playerSquare:getZ()

    for dy = -1, 1 do
        for dx = -1, 1 do
            local square = getCell():getGridSquare(cx + dx, cy + dy, cz)
            if square and playerSquare:canReachTo(square) then
                local worldObjects = square:getWorldObjects()
                for i = 0, worldObjects:size() - 1 do
                    local obj = worldObjects:get(i)
                    if instanceof(obj, "IsoWorldInventoryObject") then
                        local worldItem = obj:getItem()
                        if worldItem and worldItem:getID() == cartId then
                            SaucedCarts.debug(function() return "Found world item via grid search for cart ID " .. tostring(cartId) end)
                            onPushCartFromWorld(nil, player, obj)
                            return
                        end
                    end
                end
            end
        end
    end

    SaucedCarts.error("Could not find cart location for cart ID " .. tostring(cartId))
end

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

--- Check if an item is in the player's main inventory (not loot/ground)
---@param playerObj IsoPlayer The player
---@param item InventoryItem The item to check
---@return boolean
local function isInPlayerInventory(playerObj, item)
    if not playerObj or not item then return false end
    local playerInv = playerObj:getInventory()
    if not playerInv then return false end
    return playerInv:containsID(item:getID())
end

-- ============================================================================
-- WORLD OBJECT CONTEXT MENU
-- ============================================================================

--- Add context menu options for world objects (carts on the ground)
--- Uses a "Carts" submenu when multiple carts are present
---@param player number Player index (0-3)
---@param context ISContextMenu The context menu
---@param worldObjects table Array of IsoObject at cursor position
---@param test boolean If true, just testing if menu should show
local function onFillWorldObjectContextMenu(player, context, worldObjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end

    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end

    -- Check if player is in a vehicle
    if playerObj:getVehicle() then return end

    -- Block sitting/resting while holding a cart
    local primary = playerObj:getPrimaryHandItem()
    local holdingCart = primary and SaucedCarts.isCart(primary)

    if holdingCart then
        context:removeOptionByName(getText("ContextMenu_SitGround"))
        context:removeOptionByName(getText("ContextMenu_Sit"))
        context:removeOptionByName(getText("ContextMenu_Rest"))
    end

    -- First pass: collect all cart options
    local cartOptions = {}  -- {item, worldObj, cartName, cartData}
    local processedCarts = {}

    -- Find carts in clicked objects
    for _, obj in ipairs(worldObjects) do
        if instanceof(obj, "IsoWorldInventoryObject") then
            local item = obj:getItem()
            if item and SaucedCarts.isCart(item) then
                local cartId = item:getID()
                if not processedCarts[cartId] then
                    processedCarts[cartId] = true
                    local cartData = SaucedCarts.getCartData(item)
                    local cartName = cartData and cartData.name or "Cart"
                    table.insert(cartOptions, {
                        item = item,
                        worldObj = obj,
                        cartName = cartName,
                        cartData = cartData,
                    })
                end
            end
        end
    end

    -- If no cart clicked directly and not holding one, check for nearby carts
    if #cartOptions == 0 and not holdingCart then
        local playerSquare = playerObj:getCurrentSquare()
        if playerSquare then
            -- Search 5x5 area (2 tiles in each direction), collect all reachable carts
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
                                    if not processedCarts[cartId] then
                                        processedCarts[cartId] = true
                                        local cartData = SaucedCarts.getCartData(item)
                                        local cartName = cartData and cartData.name or "Cart"
                                        table.insert(cartOptions, {
                                            item = item,
                                            worldObj = obj,
                                            cartName = cartName,
                                            cartData = cartData,
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

    -- Check for flashlights on the ground - add "Install on Cart" option
    -- (Do this before cart options so it works even without nearby carts)
    for _, obj in ipairs(worldObjects) do
        if instanceof(obj, "IsoWorldInventoryObject") then
            local item = obj:getItem()
            if item and FlashlightMenu.isInstallableFlashlight(item) then
                FlashlightMenu.addInstallOnCartOption(context, playerObj, item)
            end
        end
    end

    -- Second pass: add cart options using unified submenu
    if #cartOptions == 0 then
        return
    end

    -- Add cart options submenu for each cart
    for _, opt in ipairs(cartOptions) do
        CartSubmenu.addCartOptionsSubmenu(
            context,
            playerObj,
            opt.item,
            opt.cartName,
            true,  -- isWorldCart
            onPushCartFromWorld,
            { firstArg = worldObjects, restArgs = { player, opt.worldObj } },
            opt.worldObj
        )
    end
end

-- ============================================================================
-- INVENTORY CONTEXT MENU
-- ============================================================================

--- Add context menu options for inventory items (equipped and unequipped carts)
--- Uses a "Carts" submenu when multiple carts are present
---@param player number Player index (0-3)
---@param context ISContextMenu The context menu
---@param items table Array of InventoryItem or item stacks
local function onFillInventoryObjectContextMenu(player, context, items)
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end

    -- Check if player is in a vehicle
    if playerObj:getVehicle() then return end

    -- First pass: collect cart options to add and remove vanilla options
    local cartOptions = {}  -- {item, cartName, cartData, handler, isEquipped}
    local processedCarts = {}
    local primary = playerObj:getPrimaryHandItem()

    for i = 1, #items do
        local item = items[i]

        -- Handle item stacks
        if not instanceof(item, "InventoryItem") then
            if item.items then
                item = item.items[1]
            end
        end

        -- Skip orphan carts (handled by OrphanRecovery.lua)
        local isOrphan = item and SaucedCarts.OrphanRecovery and SaucedCarts.OrphanRecovery.isOrphan(item)
        local looksLikeOrphan = false
        if item and not isOrphan and not SaucedCarts.isCart(item) then
            require "SaucedCarts/Migration"
            if SaucedCarts.Migration and SaucedCarts.Migration.looksLikeCart then
                looksLikeOrphan = SaucedCarts.Migration.looksLikeCart(item)
            end
        end

        if isOrphan or looksLikeOrphan then
            -- Handled by OrphanRecovery.lua
        elseif item and SaucedCarts.isCart(item) then
            local cartId = item:getID()

            -- Skip duplicates
            if not processedCarts[cartId] then
                processedCarts[cartId] = true

                -- Remove vanilla equip options for carts
                context:removeOptionByName(getText("ContextMenu_Equip_both_hands"))
                context:removeOptionByName(getText("ContextMenu_EquipBothHands"))
                context:removeOptionByName(getText("ContextMenu_Equip"))
                context:removeOptionByName(getText("ContextMenu_Unequip"))
                context:removeOptionByName("Equip In Both Hands")
                context:removeOptionByName("Equip in Both Hands")
                context:removeOptionByName("Equip")
                context:removeOptionByName("Unequip")

                local cartData = SaucedCarts.getCartData(item)
                local cartName = cartData and cartData.name or "Cart"
                local isEquipped = primary and (primary:getID() == cartId) or false
                local inPlayerInv = isInPlayerInventory(playerObj, item)

                -- Skip equipped carts (use vanilla Drop)
                if not isEquipped then
                    local handler = inPlayerInv and onPushCart or onPickupCartFromLoot
                    table.insert(cartOptions, {
                        item = item,
                        cartName = cartName,
                        cartData = cartData,
                        handler = handler,
                    })
                end
            end
        end
    end

    -- Check for flashlight items and add "Install on Cart" option
    -- (Must be done BEFORE the early return for no carts, so flashlight menu works)
    local flashlightChecked = {}  -- Avoid duplicate options
    for i = 1, #items do
        local rawItem = items[i]

        -- Handle item stacks - need to check ALL items in the stack
        local itemsToCheck = {}
        if instanceof(rawItem, "InventoryItem") then
            table.insert(itemsToCheck, rawItem)
        elseif type(rawItem) == "table" and rawItem.items then
            -- It's a stack, check all items in it
            for j = 1, #rawItem.items do
                table.insert(itemsToCheck, rawItem.items[j])
            end
        end

        -- Check each item for flashlight
        for _, item in ipairs(itemsToCheck) do
            if item and not flashlightChecked[item:getID()] and FlashlightMenu.isInstallableFlashlight(item) then
                flashlightChecked[item:getID()] = true
                FlashlightMenu.addInstallOnCartOption(context, playerObj, item)
            end
        end
    end

    -- Add options for equipped carts ONLY if the equipped cart was clicked
    if primary and SaucedCarts.isCart(primary) and processedCarts[primary:getID()] then
        local cartData = SaucedCarts.getCartData(primary)
        local cartName = cartData and cartData.name or "Cart"
        -- Equipped cart: no push handler (already equipped), no worldObj
        CartSubmenu.addCartOptionsSubmenu(context, playerObj, primary, cartName, false, nil, nil, nil)
    end

    -- Second pass: add cart options using unified submenu
    if #cartOptions == 0 then
        return
    end

    -- Add cart options submenu for each cart in inventory
    for _, opt in ipairs(cartOptions) do
        CartSubmenu.addCartOptionsSubmenu(
            context,
            playerObj,
            opt.item,
            opt.cartName,
            false,  -- isWorldCart (inventory carts are not world carts)
            opt.handler,
            { firstArg = items, restArgs = { player, opt.item } },
            nil  -- no worldObj for inventory carts
        )
    end
end

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)

SaucedCarts.debug("ContextMenu loaded")

return ContextMenu
