-- ============================================================================
-- SaucedCarts/Restrictions/TransferRestrictions.lua
-- ============================================================================
-- PURPOSE: Block cart transfers to bags/furniture via drag-and-drop in inventory UI.
--          Allows transfers to ground and vehicle containers. Shows notification when blocked.
--
-- CONTEXT: CLIENT ONLY
--
-- MULTIPLAYER SAFETY:
--   These hooks run client-side only and provide UX (notifications).
--   The ACTUAL blocking happens server-side via isItemAllowed in
--   ContainerRestrictions.lua (shared). Even if a hacked client bypasses
--   these hooks, the server will reject the transfer.
--
-- DESIGN: These hooks are DEFENSIVE - they exist to:
--         1. Filter carts from transfers before actions are created
--         2. Show user-friendly notifications
--         3. Server-side isItemAllowed is the final safeguard
--
-- SAFETY: All hooks are wrapped in pcall. If our code errors, vanilla
--         behavior continues unaffected. We never return nil from hooks
--         that expect return values.
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Notifications"
require "ISUI/ISInventoryPane"

---@class SaucedCartsTransferRestrictions
local TransferRestrictions = {}

-- ============================================================================
-- PENDING TRANSFER TRACKING
-- ============================================================================
-- Track carts with pending valid transfers (to vehicle/ground).
-- Used by ContainerRestrictions.lua to skip force-drop during unequip
-- when the user is intentionally transferring to a valid destination.

-- Format: { [cartId] = expiryTimestamp }
-- Entries auto-expire after 2 seconds (cleanup on check)
local pendingValidTransfers = {}
local PENDING_TRANSFER_EXPIRY_MS = 2000

-- Track recent notifications to avoid spam (cart ID -> timestamp)
-- Module-scoped for cleanup on game end
local recentNotifications = {}
local NOTIFICATION_COOLDOWN_MS = 1500

--- Mark a cart as having a pending valid transfer
---@param cartId number The cart's item ID
function TransferRestrictions.markPendingTransfer(cartId)
    if not cartId then return end
    pendingValidTransfers[cartId] = getTimestampMs() + PENDING_TRANSFER_EXPIRY_MS
    SaucedCarts.debug(function() return "Marked cart " .. tostring(cartId) .. " as pending valid transfer" end)
end

--- Check if a cart has a pending valid transfer (and clean up expired entries)
---@param cartId number The cart's item ID
---@return boolean True if cart has a pending valid transfer
function TransferRestrictions.hasPendingTransfer(cartId)
    if not cartId then return false end

    local now = getTimestampMs()

    -- Clean up expired entries while we're here
    for id, expiry in pairs(pendingValidTransfers) do
        if now > expiry then
            pendingValidTransfers[id] = nil
        end
    end

    local expiry = pendingValidTransfers[cartId]
    if expiry and now <= expiry then
        return true
    end

    return false
end

--- Clear a pending transfer (call after transfer completes or is cancelled)
---@param cartId number The cart's item ID
function TransferRestrictions.clearPendingTransfer(cartId)
    if not cartId then return end
    pendingValidTransfers[cartId] = nil
end

-- ============================================================================
-- SAFE HELPER FUNCTIONS
-- ============================================================================

-- Note: SaucedCarts.safeIsCart() is now centralized in Core.lua as SaucedCarts.SaucedCarts.safeIsCart()

--- Check if vehicle container has room for cart (client-side UX)
--- This is for immediate feedback - server validates authoritatively
---@param container ItemContainer
---@param item InventoryItem
---@return boolean True if there's room
local function vehicleContainerHasRoomClient(container, item)
    if not container or not item then return true end  -- Fail-safe: allow

    local success, hasRoom = pcall(function()
        local cartWeight = item:getUnequippedWeight()
        local usedCapacity = container:getCapacityWeight()
        local maxCapacity = container:getCapacity()
        local wouldExceed = (cartWeight + usedCapacity) > maxCapacity

        SaucedCarts.debug(function() return string.format(
            "Client capacity check: cart=%.1f, used=%.1f, max=%d - %s",
            cartWeight, usedCapacity, maxCapacity,
            wouldExceed and "BLOCKED" or "OK"
        ) end)

        return not wouldExceed
    end)

    return not success or hasRoom  -- Fail-safe: allow on error
end

--- Check if a container is a vehicle container
---@param container ItemContainer
---@return boolean
local function isVehicleContainer(container)
    if not container then return false end

    local success, result = pcall(function()
        local parent = container:getParent()
        if parent then
            if instanceof(parent, "BaseVehicle") or instanceof(parent, "VehiclePart") then
                return true
            end
        end
        -- Fallback: check container type
        local containerType = container:getType()
        if containerType and SaucedCarts.isVehicleContainerType(containerType) then
            return true
        end
        return false
    end)

    return success and result == true
end

--- Check if an item is currently equipped by a player
--- Equipped items can always be dropped (vanilla Drop), so skip notifications
---@param item InventoryItem The item to check
---@param character IsoPlayer The player to check (optional, checks all local players if nil)
---@return boolean True if the item is equipped
local function isItemEquipped(item, character)
    if not item then return false end

    local success, result = pcall(function()
        -- If character provided, check just that character
        if character then
            local primary = character:getPrimaryHandItem()
            return primary and primary:getID() == item:getID()
        end

        -- Otherwise check all local players
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player then
                local primary = player:getPrimaryHandItem()
                if primary and primary:getID() == item:getID() then
                    return true
                end
            end
        end
        return false
    end)

    if not success then
        return false
    end

    return result == true
end

--- Check if container destination would block carts
--- Carts can be transferred to:
---   1. On the ground (IsoGridSquare parent) - ALLOWED
---   2. Vehicle containers (BaseVehicle parent) - ALLOWED (trunk/glovebox)
--- Block: player inventory via drag-drop, bags, backpacks, furniture, etc.
--- Note: Equipping uses custom action, not drag-drop.
---@param container ItemContainer The destination container
---@return boolean True if this destination should block cart transfers
local function isBlockedDestination(container)
    if not container then return false end

    local success, result = pcall(function()
        local parent = container:getParent()
        if not parent then
            -- No parent - check container type as fallback (for mods that modify ItemContainer)
            local containerType = container:getType()
            if containerType then
                local typeLower = string.lower(containerType)
                -- Check for ground container or vehicle container types
                if typeLower == SaucedCarts.ContainerTypes.FLOOR or
                   SaucedCarts.isVehicleContainerType(containerType) then
                    return false  -- Vehicle/ground container detected by type
                end
            end
            return true  -- Block unknown containers
        end

        -- Allow ground/floor containers (IsoGridSquare parent)
        if instanceof(parent, "IsoGridSquare") then
            return false  -- Ground is allowed
        end

        -- Allow vehicle containers (BaseVehicle parent)
        if instanceof(parent, "BaseVehicle") then
            return false  -- Vehicle trunk/glovebox is allowed
        end

        -- Allow vehicle part containers (fallback for mods)
        if instanceof(parent, "VehiclePart") then
            return false  -- Vehicle part container is allowed
        end

        -- Fallback: check container type for vehicle-related names
        local containerType = container:getType()
        if containerType and SaucedCarts.isVehicleContainerType(containerType) then
            return false  -- Vehicle container detected by type
        end

        -- Block everything else: player inventory, bags, backpacks, furniture, etc.
        return true
    end)

    if not success then
        return false  -- Fail-safe: allow transfer on error
    end

    return result == true
end

--- Safely show notification
---@param player IsoPlayer|number The player or player index
local function safeNotify(player)
    pcall(function()
        local playerObj = player
        if type(player) == "number" then
            playerObj = getSpecificPlayer(player)
        end
        if playerObj and SaucedCarts.Notifications then
            SaucedCarts.Notifications.cantDragCart(playerObj)
        end
    end)
end

--- Safely iterate over items collection (handles both Lua tables and Java ArrayLists)
--- Calls callback(item, index) for each item
---@param items any The items collection (table or ArrayList)
---@param callback function Function to call for each item
---@return boolean success True if iteration completed
local function safeIterateItems(items, callback)
    if not items then return false end

    -- Try as Lua table first
    if type(items) == "table" then
        for i, item in ipairs(items) do
            callback(item, i)
        end
        return true
    end

    -- Try as Java ArrayList
    if type(items) == "userdata" then
        local success = pcall(function()
            local size = items:size()
            for i = 0, size - 1 do
                callback(items:get(i), i + 1)
            end
        end)
        return success
    end

    return false
end

--- Get size of items collection safely
---@param items any The items collection
---@return number
local function safeGetSize(items)
    if not items then return 0 end

    if type(items) == "table" then
        return #items
    end

    if type(items) == "userdata" then
        local success, size = pcall(function()
            return items:size()
        end)
        return success and size or 0
    end

    return 0
end

--- True if any entry in the transfer list is (or wraps) a cart.
--- The transferItemsByWeight hook only ever filters/blocks CARTS, so a
--- false result means we can delegate straight to vanilla and skip
--- destination classification, table-building, notifications, and logging.
--- Mirrors the main loop's stack-wrapper unwrap (context-menu format).
---@param items any Lua table or Java ArrayList of items / stack-wrappers
---@return boolean
local function transferInvolvesCart(items)
    local found = false
    safeIterateItems(items, function(rawItem)
        if found then return end
        local item = rawItem
        if type(rawItem) == "table" and not instanceof(rawItem, "InventoryItem") then
            item = rawItem.items and rawItem.items[1] or rawItem
        end
        if SaucedCarts.safeIsCart(item) then found = true end
    end)
    return found
end

-- ============================================================================
-- TRANSFER HOOK
-- ============================================================================
-- Hook ISInventoryPane:transferItemsByWeight to filter carts before transfer.
-- This prevents the action from ever being created for carts.

local transferHookInitialized = false

local function initTransferHook()
    if transferHookInitialized then return end

    -- Ensure ISInventoryPane exists
    if not ISInventoryPane or not ISInventoryPane.transferItemsByWeight then
        SaucedCarts.debug("ISInventoryPane.transferItemsByWeight not found, skipping hook")
        return
    end

    local originalTransferItemsByWeight = ISInventoryPane.transferItemsByWeight

    ISInventoryPane.transferItemsByWeight = function(self, items, container)
        -- Fast path: this hook only filters/blocks CARTS. The overwhelming
        -- majority of transfers contain none — delegate straight to vanilla
        -- with no destination classification, table-building, toast, or log
        -- work. pcall'd so a scan error can't break a vanilla transfer; on
        -- error we fall through to the full (also pcall'd, fail-safe) path.
        local scanOk, hasCart = pcall(transferInvolvesCart, items)
        if scanOk and not hasCart then
            return originalTransferItemsByWeight(self, items, container)
        end

        -- Default: pass through unchanged
        local filteredItems = items
        local didFilter = false
        local notifiedPlayer = false

        -- Debug: log entry into this function
        SaucedCarts.debug(function() return "transferItemsByWeight called - items type: " .. type(items) end)

        -- Wrap filtering in pcall - on ANY error, use original items
        local filterSuccess = pcall(function()
            local itemCount = safeGetSize(items)
            SaucedCarts.debug(function() return "transferItemsByWeight - item count: " .. itemCount end)
            if itemCount == 0 then return end

            local destIsBlocked = isBlockedDestination(container)
            local destIsVehicle = isVehicleContainer(container)

            -- Log destination info for debugging
            local parentType = "nil"
            pcall(function()
                local parent = container:getParent()
                if parent then parentType = tostring(parent) end
            end)
            SaucedCarts.debug(function() return string.format(
                "transferItemsByWeight - blocked=%s, vehicle=%s, parent=%s",
                tostring(destIsBlocked), tostring(destIsVehicle), parentType
            ) end)

            -- Build filtered list, checking each cart for capacity if going to vehicle
            local newItems = {}
            local cartsBlocked = 0
            local capacityBlocked = false

            safeIterateItems(items, function(rawItem)
                -- Unwrap item stack format (like context menus use)
                local item = rawItem
                if type(rawItem) == "table" and not instanceof(rawItem, "InventoryItem") then
                    item = rawItem.items and rawItem.items[1] or rawItem
                end

                if SaucedCarts.safeIsCart(item) then
                    local allowTransfer = true
                    local blockReason = nil

                    if destIsBlocked then
                        -- Destination type is blocked (bags, backpacks, furniture)
                        allowTransfer = false
                        blockReason = "blocked"
                    elseif destIsVehicle and not vehicleContainerHasRoomClient(container, item) then
                        -- Vehicle container but no capacity
                        allowTransfer = false
                        blockReason = "capacity"
                        capacityBlocked = true
                    end

                    if allowTransfer then
                        -- Mark pending valid transfer for unequip hook
                        pcall(function()
                            TransferRestrictions.markPendingTransfer(item:getID())
                        end)
                        table.insert(newItems, rawItem)
                    else
                        cartsBlocked = cartsBlocked + 1
                        SaucedCarts.debug(function() return "Cart blocked: " .. (blockReason or "unknown") end)
                    end
                else
                    -- Non-cart items pass through
                    table.insert(newItems, rawItem)
                end
            end)

            -- Show appropriate notification once
            if cartsBlocked > 0 and not notifiedPlayer and self and self.player then
                local playerObj = type(self.player) == "number" and getSpecificPlayer(self.player) or self.player
                if playerObj and SaucedCarts.Notifications then
                    if capacityBlocked then
                        SaucedCarts.Notifications.vehicleFull(playerObj)
                    else
                        SaucedCarts.Notifications.cantDragCart(playerObj)
                    end
                    notifiedPlayer = true
                end
            end

            -- Only use filtered list if we actually removed items
            if cartsBlocked > 0 then
                filteredItems = newItems
                didFilter = true
                SaucedCarts.debug(function() return string.format("Filtered %d cart(s) from transfer", cartsBlocked) end)
            end
        end)

        -- If filtering failed, use original items (fail-safe)
        if not filterSuccess then
            SaucedCarts.debug("Transfer filter error - using original items")
            filteredItems = items
            didFilter = false
        end

        -- If all items were filtered out, still call original with empty list
        -- This maintains expected behavior (original might do cleanup, return value, etc.)
        -- The original function should handle empty lists gracefully
        return originalTransferItemsByWeight(self, filteredItems, container)
    end

    transferHookInitialized = true
    SaucedCarts.debug("Transfer hook initialized")
end

-- ============================================================================
-- TRANSFER ACTION HOOK
-- ============================================================================
-- Hook ISInventoryTransferAction.new as a safety net.
-- This catches any transfer attempts that bypassed transferItemsByWeight.
--
-- IMPORTANT: We return the original action (not a no-op) but mark the item
-- so isItemAllowed will reject it. This is safer than returning a fake action
-- that might not behave correctly in all queue scenarios.

local transferActionHookInitialized = false

local function initTransferActionHook()
    if transferActionHookInitialized then return end

    -- Ensure ISInventoryTransferAction exists
    if not ISInventoryTransferAction or not ISInventoryTransferAction.new then
        SaucedCarts.debug("ISInventoryTransferAction not found, skipping hook")
        return
    end

    local originalNew = ISInventoryTransferAction.new

    -- Uses module-scoped recentNotifications and NOTIFICATION_COOLDOWN_MS

    ISInventoryTransferAction.new = function(self, character, item, srcContainer, destContainer, time)
        -- Always create the action first - we need a valid return value
        local action = originalNew(self, character, item, srcContainer, destContainer, time)

        -- Show notification if transfer will be blocked
        -- This catches transfers that bypass transferItemsByWeight (context menu, etc.)
        pcall(function()
            -- Check for cart transfer
            if item and SaucedCarts.safeIsCart(item) and destContainer then
                local isVehicle = isVehicleContainer(destContainer)
                local isBlocked = isBlockedDestination(destContainer)
                local capacityBlocked = isVehicle and not vehicleContainerHasRoomClient(destContainer, item)

                -- Common Sense interop (VB_CommonSense 3750253491, field
                -- report 2026-08-18): its ground "Equip" submenu lists every
                -- InventoryContainer and runs transferIfNeeded -> vanilla
                -- transfer of the CART into the player's MAIN inventory (its
                -- follow-up ISWearClothing no-ops on a cart, so the cart just
                -- rests in the pocket). Main inventory is the one destination
                -- our server-side isItemAllowed deliberately permits (our own
                -- equip pipeline transits it — via direct AddItem, never via
                -- vanilla ISInventoryTransferAction, verified), so this hook
                -- is the only gate that can see the foreign path. Kill the
                -- action: a per-instance isValid=false makes the vanilla
                -- queue discard it — the supported rejection path (returning
                -- fake actions breaks queues; see hook design note above).
                local destParent = destContainer:getParent()
                if destParent and instanceof(destParent, "IsoPlayer") then
                    action.isValid = function() return false end
                    SaucedCarts.debug("Transfer action: cart->main-inventory invalidated (foreign equip path)")
                end

                if isBlocked or capacityBlocked then
                    -- Check notification cooldown
                    local cartId = item:getID()
                    local now = getTimestampMs()
                    local lastNotify = recentNotifications[cartId] or 0

                    if (now - lastNotify) > NOTIFICATION_COOLDOWN_MS then
                        recentNotifications[cartId] = now

                        local playerObj = character
                        if playerObj and SaucedCarts.Notifications then
                            if capacityBlocked then
                                SaucedCarts.Notifications.vehicleFull(playerObj)
                                SaucedCarts.debug("Transfer action: vehicle capacity blocked, notification shown")
                            else
                                SaucedCarts.Notifications.cantDragCart(playerObj)
                                SaucedCarts.debug("Transfer action: destination blocked, notification shown")
                            end
                        end
                    end
                end
            end
        end)

        return action
    end

    transferActionHookInitialized = true
    SaucedCarts.debug("Transfer action hook initialized")
end

-- ============================================================================
-- CONTEXT MENU CLEANUP
-- ============================================================================
-- Remove vanilla grab/transfer options from context menus for carts.
-- This is cosmetic cleanup - actual blocking happens via other mechanisms.

--- Safely remove context menu options by trying multiple key variations
--- Some PZ versions use different key formats
---@param context ISContextMenu The context menu
---@param baseKey string The base translation key (e.g., "ContextMenu_Equip")
local function safeRemoveOption(context, baseKey)
    -- Try the provided key first
    context:removeOptionByName(getText(baseKey))

    -- For equip options, also try raw strings as fallback
    -- (in case getText returns the key itself when translation missing)
    if baseKey:find("Equip") then
        context:removeOptionByName("Equip In Both Hands")
        context:removeOptionByName("Equip in Both Hands")
        context:removeOptionByName("Equip")
        context:removeOptionByName("Unequip")
    end
end

--- Remove grab/transfer context menu options for carts in inventory
---@param player number Player index (0-3)
---@param context ISContextMenu The context menu
---@param items table Array of inventory items
local function removeCartTransferOptions(player, context, items)
    -- Wrap in pcall - never break context menus
    pcall(function()
        if not items or safeGetSize(items) == 0 then return end

        local item = items[1]

        -- Handle item stack format
        if not instanceof(item, "InventoryItem") then
            item = item.items and item.items[1]
        end

        if item and SaucedCarts.safeIsCart(item) then
            -- v2.1.20: Grab is removed for carts EVERYWHERE, including
            -- vehicle containers. The old carve-out ("transfer to player
            -- inventory is OK" for trunk carts) is contradicted by the
            -- isItemAllowed flip — a Grab click would now be a dead option
            -- with a toast. Retrieval from a trunk is "Push Cart" (equip via
            -- ISCartEquipAction) or drag to the floor, both unaffected.
            safeRemoveOption(context, "ContextMenu_Grab")
            safeRemoveOption(context, "ContextMenu_Grab_one")
            safeRemoveOption(context, "ContextMenu_Grab_half")
            safeRemoveOption(context, "ContextMenu_Grab_all")

            safeRemoveOption(context, "ContextMenu_PutItemsInContainer")

            -- Remove vanilla equip options - use Push Cart instead.
            -- ContextMenu_Equip_Two_Hands is vanilla's real key for the
            -- both-hands option; the two below don't exist in B42 and only
            -- matched English clients via safeRemoveOption's literals.
            safeRemoveOption(context, "ContextMenu_Equip_Two_Hands")
            safeRemoveOption(context, "ContextMenu_Equip_both_hands")
            safeRemoveOption(context, "ContextMenu_EquipBothHands")
            safeRemoveOption(context, "ContextMenu_Equip")
            safeRemoveOption(context, "ContextMenu_Unequip")
        end
    end)
end

--- Remove vanilla grab options for carts on the ground
---@param player number Player index (0-3)
---@param context ISContextMenu The context menu
---@param worldObjects table Array of world objects
---@param test boolean If true, just testing
local function removeWorldCartGrabOptions(player, context, worldObjects, test)
    if test then return end

    -- Wrap in pcall - never break context menus
    pcall(function()
        local hasCart = false

        safeIterateItems(worldObjects, function(obj)
            if not hasCart and instanceof(obj, "IsoWorldInventoryObject") then
                local item = obj:getItem()
                if item and SaucedCarts.safeIsCart(item) then
                    hasCart = true
                end
            end
        end)

        if hasCart then
            SaucedCarts.debug("removeWorldCartGrabOptions: found cart, removing options")

            -- Remove grab options
            safeRemoveOption(context, "ContextMenu_Grab")
            safeRemoveOption(context, "ContextMenu_Grab_one")
            safeRemoveOption(context, "ContextMenu_Grab_half")
            safeRemoveOption(context, "ContextMenu_Grab_all")

            -- Remove vanilla equip options (see removeCartTransferOptions for
            -- why ContextMenu_Equip_Two_Hands is the load-bearing key)
            safeRemoveOption(context, "ContextMenu_Equip_Two_Hands")
            safeRemoveOption(context, "ContextMenu_Equip_both_hands")
            safeRemoveOption(context, "ContextMenu_EquipBothHands")
            safeRemoveOption(context, "ContextMenu_Equip")
        end
    end)
end

-- ============================================================================
-- POST-MENU GRAB SWEEP (the "Grab option leak")
-- ============================================================================
-- Vanilla B42 no longer adds any world-menu option wired to
-- ISWorldObjectContextMenu.onGrabWItem / onGrabHalfWItems / onGrabAllWItems —
-- the handlers exist but are dead code (verified: zero addOption call sites in
-- vanilla media/lua). Some QoL mods re-add the B41-style "Grab" option wired
-- to those legacy handlers. removeWorldCartGrabOptions above only wins that
-- fight when OUR OnFillWorldObjectContextMenu handler happens to run AFTER the
-- re-adding mod's (event order = mod load order), and it matches by display
-- name, which any custom label defeats. Field report (prsly, 2026-08): Grab
-- visible on a ground cart, click shows our "can't put a grocery cart in my
-- pocket" block message — option leaked, behavior layer held.
--
-- Fix: wrap ISWorldObjectContextMenu.createMenu. It fires the fill event
-- internally (ISWorldObjectContextMenu.lua:213) and returns the finished
-- context (:222), so a post-call sweep runs after EVERY mod's handler
-- regardless of load order. Options are matched by HANDLER IDENTITY (live
-- field values plus the pre-hook originals recorded in
-- GrabRestrictions.legacyOriginals) — locale-proof and label-proof — and
-- removed only when everything they target is a cart, so a mod's grab option
-- for ordinary loot is never touched. Mixed cart+loot grab-all lists are left
-- in place: the click-time filter in GrabRestrictions grabs the non-carts and
-- notifies about the cart.

local worldMenuSweepInitialized = false

--- Is this function one of the legacy world-grab handlers (in either its
--- current hooked form or the pre-hook original a mod may have captured)?
local function isLegacyGrabHandler(fn)
    if type(fn) ~= "function" then return false end
    if ISWorldObjectContextMenu then
        if fn == ISWorldObjectContextMenu.onGrabWItem
            or fn == ISWorldObjectContextMenu.onGrabHalfWItems
            or fn == ISWorldObjectContextMenu.onGrabAllWItems then
            return true
        end
    end
    local originals = SaucedCarts.GrabRestrictions
        and SaucedCarts.GrabRestrictions.legacyOriginals
    return (originals and originals[fn]) or false
end

--- Does this option target carts and nothing else? param1 of the legacy
--- handlers is either one IsoWorldInventoryObject (onGrabWItem) or a Lua
--- array of them (onGrabHalfWItems / onGrabAllWItems).
local function optionTargetsOnlyCarts(option)
    local ok, result = pcall(function()
        local target = option.param1
        if not target then return false end
        if instanceof(target, "IsoWorldInventoryObject") then
            local item = target:getItem()
            return (item and SaucedCarts.safeIsCart(item)) or false
        end
        if type(target) == "table" then
            local count = 0
            for _, wi in ipairs(target) do
                count = count + 1
                local item = instanceof(wi, "IsoWorldInventoryObject") and wi:getItem() or nil
                if not (item and SaucedCarts.safeIsCart(item)) then
                    return false
                end
            end
            return count > 0
        end
        return false
    end)
    return (ok and result) or false
end

--- Remove options[index], mirroring vanilla removeOptionByName's compaction
--- (ISContextMenu.lua:1016-1036) so ids, numOptions and the option pool stay
--- consistent.
local function removeOptionAt(menu, index)
    local option = menu.options[index]
    if not option then return end
    table.insert(menu.optionPool, option)
    for i = index + 1, #menu.options do
        menu.options[i - 1] = menu.options[i]
        menu.options[i - 1].id = i - 1
    end
    menu.options[#menu.options] = nil
    menu.numOptions = menu.numOptions - 1
    if menu.calcHeight then menu:calcHeight() end
end

--- Sweep one menu (and its submenus, up to two levels down) for cart grab
--- options.
---@return number removed
local function sweepMenuForCartGrabs(menu, depth)
    if type(menu) ~= "table" or type(menu.options) ~= "table" then return 0 end
    depth = depth or 0
    if depth > 2 then return 0 end
    local removed = 0
    local i = 1
    while menu.options[i] do
        local option = menu.options[i]
        if isLegacyGrabHandler(option.onSelect) and optionTargetsOnlyCarts(option) then
            removeOptionAt(menu, i)
            removed = removed + 1
        else
            if option.subOption and menu.getSubMenu then
                local ok, sub = pcall(menu.getSubMenu, menu, option.subOption)
                if ok and sub then
                    removed = removed + sweepMenuForCartGrabs(sub, depth + 1)
                end
            end
            i = i + 1
        end
    end
    return removed
end

local grabSweepReported = false

--- The full post-createMenu pass: sweep, then repeat vanilla's "hide a menu
--- with no real options" check — createMenu runs it BEFORE returning
--- (ISWorldObjectContextMenu.lua:218-220, hides at numOptions == 1), so a
--- menu whose only real option was the leaked Grab would otherwise render as
--- an empty box after our removal. numOptions/setVisible absent (foreign
--- menu framework) simply skips the re-check.
---@return number removed
local function postCreateMenuSweep(context)
    if type(context) ~= "table" or type(context.options) ~= "table" then return 0 end
    local removed = sweepMenuForCartGrabs(context, 0)
    if removed > 0 then
        if context.numOptions == 1 and type(context.setVisible) == "function" then
            context:setVisible(false)
        end
        local msg = "Grab sweep: removed " .. removed
            .. " third-party cart Grab option(s) re-added after our menu cleanup"
            .. " (a mod wires vanilla's legacy onGrabWItem handlers)"
        if grabSweepReported then
            -- Per-removal reporting fires on every menu open while a
            -- conflicting mod is installed — debug-only past the first.
            SaucedCarts.debug(msg)
        else
            -- Once per session ungated, so a plain user log still answers
            -- "why is that mod's Grab missing on carts" without the spam.
            grabSweepReported = true
            SaucedCarts.log(msg .. " — further removals this session log in debug mode only")
        end
    end
    return removed
end

local function initWorldMenuSweep()
    if worldMenuSweepInitialized then return end
    if not (ISWorldObjectContextMenu and ISWorldObjectContextMenu.createMenu) then
        SaucedCarts.debug("ISWorldObjectContextMenu.createMenu not found, skipping grab sweep")
        return
    end

    local originalCreateMenu = ISWorldObjectContextMenu.createMenu
    ISWorldObjectContextMenu.createMenu = function(...)
        local context = originalCreateMenu(...)
        -- test mode returns a boolean, paused/tutorial paths return nil or a
        -- foreign menu — postCreateMenuSweep's type guards no-op all of those.
        pcall(postCreateMenuSweep, context)
        return context
    end

    worldMenuSweepInitialized = true
    SaucedCarts.debug("World-menu grab sweep initialized")
end

-- ============================================================================
-- DOUBLE-CLICK HOOKS
-- ============================================================================
-- Hook double-click handlers to block cart equip attempts.
-- Players should use our "Push Cart" context menu option instead.

local doubleClickHookInitialized = false

local function initDoubleClickHook()
    if doubleClickHookInitialized then return end

    -- Hook doContextualDblClick (for items already in player inventory)
    if ISInventoryPane and ISInventoryPane.doContextualDblClick then
        local originalDoContextualDblClick = ISInventoryPane.doContextualDblClick

        ISInventoryPane.doContextualDblClick = function(self, item)
            local shouldBlock = false

            pcall(function()
                if item and SaucedCarts.safeIsCart(item) then
                    shouldBlock = true
                    SaucedCarts.debug("Blocked double-click equip for cart (inventory)")
                    if self.player then
                        safeNotify(self.player)
                    end
                end
            end)

            if shouldBlock then
                return
            end

            return originalDoContextualDblClick(self, item)
        end

        SaucedCarts.debug("doContextualDblClick hook initialized")
    end

    -- Hook onMouseDoubleClick (for items in loot panel / ground)
    if ISInventoryPane and ISInventoryPane.onMouseDoubleClick then
        local originalOnMouseDoubleClick = ISInventoryPane.onMouseDoubleClick

        ISInventoryPane.onMouseDoubleClick = function(self, x, y)
            -- Check if the item being double-clicked is a cart
            local shouldBlock = false

            pcall(function()
                if self.items and self.mouseOverOption and self.previousMouseUp == self.mouseOverOption then
                    local item = self.items[self.mouseOverOption]

                    -- Handle item stack format (table with .items array)
                    -- Must check type first - strings/other types don't have .items
                    if item and type(item) == "table" and item.items and item.items[1] then
                        item = item.items[1]
                    end

                    -- safeIsCart handles all type checking internally
                    if SaucedCarts.safeIsCart(item) then
                        -- Check if item is NOT in player inventory (i.e., in loot panel)
                        local playerInv = getPlayerInventory(self.player)
                        if playerInv and playerInv.inventory and item:getContainer() ~= playerInv.inventory then
                            shouldBlock = true
                            SaucedCarts.debug("Blocked double-click pickup for cart (loot panel)")
                            safeNotify(self.player)
                        end
                    end
                end
            end)

            if shouldBlock then
                -- Clear state to prevent repeated attempts
                self.previousMouseUp = nil
                return
            end

            return originalOnMouseDoubleClick(self, x, y)
        end

        SaucedCarts.debug("onMouseDoubleClick hook initialized")
    end

    doubleClickHookInitialized = true
    SaucedCarts.debug("Double-click hooks initialized")
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function onGameStart()
    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end

    initTransferHook()
    initTransferActionHook()
    initDoubleClickHook()
    initWorldMenuSweep()

    -- Register context menu cleanup handlers
    Events.OnFillWorldObjectContextMenu.Add(removeWorldCartGrabOptions)
    Events.OnFillInventoryObjectContextMenu.Add(removeCartTransferOptions)

    SaucedCarts.debug("Transfer context menu handlers registered")
end

Events.OnGameStart.Add(onGameStart)

-- ============================================================================
-- DEBUG API
-- ============================================================================

function TransferRestrictions.isInitialized()
    return transferHookInitialized and transferActionHookInitialized and doubleClickHookInitialized
end

SaucedCarts.TransferRestrictions = TransferRestrictions

-- Test hook: pure discriminator that gates the transferItemsByWeight fast-path.
TransferRestrictions._transferInvolvesCart = transferInvolvesCart

-- Test hooks: install the ISInventoryTransferAction.new wrapper against a
-- stubbed class (offline kit has no vanilla actions at file load). The reset
-- clears the once-guard so each test can wrap a fresh stub.
TransferRestrictions._initTransferActionHook = initTransferActionHook
TransferRestrictions._resetTransferActionHook = function()
    transferActionHookInitialized = false
end

-- Test hooks: the post-createMenu grab sweep's pure pieces.
TransferRestrictions._sweepMenuForCartGrabs = sweepMenuForCartGrabs
TransferRestrictions._isLegacyGrabHandler = isLegacyGrabHandler
TransferRestrictions._optionTargetsOnlyCarts = optionTargetsOnlyCarts
TransferRestrictions._postCreateMenuSweep = postCreateMenuSweep
TransferRestrictions._resetGrabSweepReport = function() grabSweepReported = false end

-- ============================================================================
-- CLEANUP ON GAME END
-- ============================================================================
-- Clear state tables when exiting to prevent stale state on save switch.

local function onGameEnd()
    pendingValidTransfers = {}
    recentNotifications = {}
    SaucedCarts.debug("TransferRestrictions: cleared state on game end")
end

if Events and Events.OnGameEnd then
    Events.OnGameEnd.Add(onGameEnd)
end

SaucedCarts.debug("TransferRestrictions module loaded")

return TransferRestrictions
