-- ============================================================================
-- SaucedCarts/OrphanRecovery.lua
-- ============================================================================
-- PURPOSE: Client-side UI for orphan cart detection and recovery.
--          Shows notifications when orphan carts are found and provides
--          context menu options to recover items from broken carts.
--
-- CONTEXT: CLIENT ONLY
--          UI elements are client-side only.
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"

---@class SaucedCartsOrphanRecovery
SaucedCarts.OrphanRecovery = {}

-- Track orphaned carts by ID for quick lookup
SaucedCarts._orphanedCarts = SaucedCarts._orphanedCarts or {}

-- ============================================================================
-- NOTIFICATION
-- ============================================================================

--- Show notification about orphaned carts found in inventory
--- Called by Migration.lua after detecting orphans
---@param player IsoPlayer The player
---@param orphans table Array of orphaned cart items
function SaucedCarts.OrphanRecovery.notifyOrphans(player, orphans)
    if not orphans or #orphans == 0 then return end

    local count = #orphans

    -- Build message
    local msg
    if count == 1 then
        msg = getText("UI_SaucedCarts_OrphanFound_Single")
    else
        msg = getText("UI_SaucedCarts_OrphanFound_Multi"):gsub("%%1", tostring(count))
    end

    -- Use HaloTextHelper for in-game notification if available
    if HaloTextHelper and HaloTextHelper.addTextWithArrow then
        local color = HaloTextHelper.getColorWarning and HaloTextHelper.getColorWarning() or {r = 1, g = 0.7, b = 0}
        HaloTextHelper.addTextWithArrow(player, msg, true, color)
    end

    -- Always log it
    SaucedCarts.debug("WARNING: " .. msg)

    -- Store cart IDs for context menu access
    for _, cart in ipairs(orphans) do
        SaucedCarts._orphanedCarts[cart:getID()] = true
    end
end

-- ============================================================================
-- ORPHAN DETECTION
-- ============================================================================

--- Check if a cart is orphaned (for context menu)
--- Uses both ModData flag and ID cache
---@param item InventoryItem The item to check
---@return boolean True if item is an orphaned cart
function SaucedCarts.OrphanRecovery.isOrphan(item)
    if not item then return false end

    -- Check ModData flag (primary source)
    local modData = item:getModData()
    if modData.SaucedCarts_isOrphan then
        return true
    end

    -- Check ID cache (fallback for current session)
    if SaucedCarts._orphanedCarts[item:getID()] then
        return true
    end

    return false
end

--- Get information about an orphaned cart for display
---@param item InventoryItem The orphaned cart
---@return table info Cart information for UI display
function SaucedCarts.OrphanRecovery.getOrphanInfo(item)
    if not item then return {} end

    local modData = item:getModData()
    local container = item:getItemContainer()

    return {
        originalType = modData.SaucedCarts_orphanedType or item:getFullType(),
        orphanedAt = modData.SaucedCarts_orphanedAt,
        itemCount = container and container:getItems():size() or 0,
        totalWeight = container and container:getCapacityWeight() or 0,
    }
end

-- ============================================================================
-- CONTEXT MENU INTEGRATION
-- ============================================================================

--- Perform orphan cart recovery
--- Transfers all items to player inventory and removes the cart
---@param item InventoryItem The orphaned cart
---@param player IsoPlayer The player
local function doRecoverOrphanCart(item, player)
    require "SaucedCarts/Migration"

    -- If cart is currently equipped, unequip it first
    local primary = player:getPrimaryHandItem()
    if primary and primary:getID() == item:getID() then
        player:setPrimaryHandItem(nil)
        player:setSecondaryHandItem(nil)
        sendEquip(player)
    end

    local success, result = SaucedCarts.Migration.recoverOrphanCart(item, player)

    if success then
        -- Show success notification
        local msg = getText("UI_SaucedCarts_RecoveredItems"):gsub("%%1", tostring(result))

        if HaloTextHelper and HaloTextHelper.addTextWithArrow then
            local color = HaloTextHelper.getColorGreen and HaloTextHelper.getColorGreen() or {r = 0, g = 1, b = 0}
            HaloTextHelper.addTextWithArrow(player, msg, true, color)
        end

        SaucedCarts.debug(msg)

        -- Remove from orphan cache
        SaucedCarts._orphanedCarts[item:getID()] = nil

        -- Refresh inventory UI
        local pdata = getPlayerData(player:getPlayerNum())
        if pdata then
            pdata.playerInventory:refreshBackpacks()
            pdata.lootInventory:refreshBackpacks()
        end
    else
        -- Show error notification
        local msg = getText("UI_SaucedCarts_RecoveryFailed"):gsub("%%1", tostring(result))

        if HaloTextHelper and HaloTextHelper.addTextWithArrow then
            local color = HaloTextHelper.getColorRed and HaloTextHelper.getColorRed() or {r = 1, g = 0, b = 0}
            HaloTextHelper.addTextWithArrow(player, msg, true, color)
        end

        SaucedCarts.error(msg)
    end
end

--- Add context menu options for orphan carts in inventory
--- Event handler for OnFillInventoryObjectContextMenu
---@param playerNum number Player index (0-3)
---@param context ISContextMenu The context menu
---@param items table Array of inventory items
local function onFillInventoryContextMenu(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    for _, v in ipairs(items) do
        local item = v

        -- Handle item stacks
        if type(v) == "table" and v.items then
            item = v.items[1]
        end

        -- Check if orphan OR if it looks like a cart but isn't registered
        -- (handles carts that somehow bypassed migration)
        local isOrphan = SaucedCarts.OrphanRecovery.isOrphan(item)
        local looksLikeCart = false
        if not isOrphan and item then
            require "SaucedCarts/Migration"
            if SaucedCarts.Migration and SaucedCarts.Migration.looksLikeCart then
                looksLikeCart = SaucedCarts.Migration.looksLikeCart(item) and not SaucedCarts.isCart(item)
            end
        end

        if item and (isOrphan or looksLikeCart) then
            -- Run migration to ensure orphan status is properly set
            if looksLikeCart and not isOrphan then
                SaucedCarts.Migration.migrateCart(item)
            end

            local info = SaucedCarts.OrphanRecovery.getOrphanInfo(item)

            -- Build option text
            local text = getText("UI_SaucedCarts_RecoverItems"):gsub("%%1", tostring(info.itemCount))

            local option = context:addOption(text, item, doRecoverOrphanCart, player)

            -- Add tooltip explaining the situation
            local tooltip = ISWorldObjectContextMenu.addToolTip()
            tooltip:setName(getText("UI_SaucedCarts_OrphanedCart"))

            local desc = getText("UI_SaucedCarts_OrphanTooltip_Desc") .. "\n"
            desc = desc .. getText("UI_SaucedCarts_OrphanTooltip_Reason") .. "\n\n"

            if info.originalType then
                desc = desc .. getText("UI_SaucedCarts_OrphanTooltip_OriginalType"):gsub("%%1", info.originalType) .. "\n"
            end

            if info.itemCount > 0 then
                local containsText = getText("UI_SaucedCarts_OrphanTooltip_Contains")
                containsText = containsText:gsub("%%1", tostring(info.itemCount))
                containsText = containsText:gsub("%%2", string.format("%.1f", info.totalWeight))
                desc = desc .. containsText .. "\n\n"
            else
                desc = desc .. getText("UI_SaucedCarts_OrphanTooltip_Empty") .. "\n\n"
            end

            desc = desc .. getText("UI_SaucedCarts_OrphanTooltip_Recover")

            tooltip.description = desc
            option.toolTip = tooltip
        end
    end
end

-- ============================================================================
-- WORLD OBJECT CONTEXT MENU (for orphan carts on ground)
-- ============================================================================

--- Perform orphan cart pickup from world
--- Uses ISCartPickupAction timed action for proper MP sync
---@param worldObj IsoWorldInventoryObject The world object to pick up
---@param playerObj IsoPlayer The player
local function doPickupOrphanFromWorld(worldObj, playerObj)
    if not worldObj then
        SaucedCarts.error("Orphan pickup: worldObj is nil")
        return
    end

    -- Use the same timed action as regular cart pickup (MP-safe)
    require "SaucedCarts/TimedActions/ISCartPickupAction"
    ISTimedActionQueue.add(ISCartPickupAction.FromWorldItem(playerObj, worldObj))

    SaucedCarts.debug("Queued orphan cart pickup")
end

--- Add context menu options for orphan carts on the ground
---@param player number Player index
---@param context ISContextMenu The context menu
---@param worldObjects table Array of world objects
---@param test boolean Test mode flag
local function onFillWorldObjectContextMenu(player, context, worldObjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end

    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    -- Don't allow pickup while in vehicle
    if playerObj:getVehicle() then return end

    for _, obj in ipairs(worldObjects) do
        if instanceof(obj, "IsoWorldInventoryObject") then
            local item = obj:getItem()

            -- Check if orphan OR if it looks like a cart but isn't registered
            -- (handles carts placed before migration system existed)
            local isOrphan = SaucedCarts.OrphanRecovery.isOrphan(item)
            local looksLikeCart = false
            if not isOrphan and item then
                require "SaucedCarts/Migration"
                if SaucedCarts.Migration and SaucedCarts.Migration.looksLikeCart then
                    looksLikeCart = SaucedCarts.Migration.looksLikeCart(item) and not SaucedCarts.isCart(item)
                end
            end

            if item and (isOrphan or looksLikeCart) then
                local info = SaucedCarts.OrphanRecovery.getOrphanInfo(item)

                -- For world objects, we need to pick up first then recover
                local text = getText("UI_SaucedCarts_PickupBrokenCart"):gsub("%%1", tostring(info.itemCount))

                -- Use a closure to capture obj and playerObj
                local capturedObj = obj
                local capturedPlayer = playerObj

                local option = context:addOption(text, nil, function()
                    doPickupOrphanFromWorld(capturedObj, capturedPlayer)
                end)

                -- Disable if player is asleep
                if playerObj:isAsleep() then
                    option.notAvailable = true
                end

                -- Add tooltip
                local tooltip = ISWorldObjectContextMenu.addToolTip()
                tooltip:setName(getText("UI_SaucedCarts_OrphanedCart"))
                tooltip.description = getText("UI_SaucedCarts_OrphanWorldTooltip")
                option.toolTip = tooltip
            end
        end
    end
end

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

-- Register context menu handlers
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryContextMenu)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

SaucedCarts.debug("OrphanRecovery module loaded")

return SaucedCarts.OrphanRecovery
