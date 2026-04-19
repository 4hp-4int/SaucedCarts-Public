-- ============================================================================
-- SaucedCarts/Restrictions/GrabRestrictions.lua
-- ============================================================================
-- PURPOSE: Block vanilla "Grab" actions for carts on the ground.
--          Shows notification when blocked.
--
-- CONTEXT: CLIENT ONLY
--
-- DESIGN: These hooks are DEFENSIVE - the primary blocking mechanism is
--         isItemAllowed in ContainerRestrictions.lua. These hooks exist to:
--         1. Filter carts from grab operations before actions are created
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

---@class SaucedCartsGrabRestrictions
local GrabRestrictions = {}

-- ============================================================================
-- SAFE HELPER FUNCTIONS
-- ============================================================================

-- Note: SaucedCarts.safeIsCart() is now centralized in Core.lua as SaucedCarts.SaucedCarts.safeIsCart()

--- Safely get item from world object
--- Returns nil on any error
---@param worldObj any World inventory object
---@return InventoryItem|nil
local function safeGetItem(worldObj)
    if not worldObj then return nil end

    local success, result = pcall(function()
        return worldObj:getItem()
    end)

    if not success then
        return nil
    end

    return result
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
            SaucedCarts.Notifications.cantGrabCart(playerObj)
        end
    end)
end

-- ============================================================================
-- GRAB FUNCTION HOOKS
-- ============================================================================
-- Hook ISWorldObjectContextMenu grab functions to filter carts.
-- These are called when player uses context menu "Grab" options on world items.

local hooksInitialized = false

local function initGrabHooks()
    if hooksInitialized then return end

    -- Hook onGrabWItem (single item grab)
    if ISWorldObjectContextMenu.onGrabWItem then
        local originalOnGrabWItem = ISWorldObjectContextMenu.onGrabWItem
        ISWorldObjectContextMenu.onGrabWItem = function(worldobjects, WItem, player)
            -- Safe check: is this a cart?
            local shouldBlock = false

            pcall(function()
                local item = safeGetItem(WItem)
                if item and SaucedCarts.safeIsCart(item) then
                    shouldBlock = true
                    SaucedCarts.debug("Blocked grab for cart via onGrabWItem")
                    safeNotify(player)
                end
            end)

            if shouldBlock then
                -- Don't call original - cart grab is blocked
                -- isItemAllowed would reject it anyway, but this is cleaner
                return
            end

            -- Chain to original
            return originalOnGrabWItem(worldobjects, WItem, player)
        end
    end

    -- Hook onGrabHalfWItems (grab half)
    if ISWorldObjectContextMenu.onGrabHalfWItems then
        local originalOnGrabHalfWItems = ISWorldObjectContextMenu.onGrabHalfWItems
        ISWorldObjectContextMenu.onGrabHalfWItems = function(worldobjects, WItems, player)
            -- Safe filter: remove carts from list
            local filteredItems = WItems
            local notifiedPlayer = false

            pcall(function()
                if WItems and type(WItems) == "table" and #WItems > 0 then
                    local newItems = {}
                    for _, witem in ipairs(WItems) do
                        local item = safeGetItem(witem)
                        if item and SaucedCarts.safeIsCart(item) then
                            if not notifiedPlayer then
                                safeNotify(player)
                                notifiedPlayer = true
                            end
                            SaucedCarts.debug("Filtered cart from grab half")
                        else
                            table.insert(newItems, witem)
                        end
                    end
                    filteredItems = newItems
                end
            end)

            -- If nothing left after filtering, don't call original
            if type(filteredItems) == "table" and #filteredItems == 0 then
                return
            end

            return originalOnGrabHalfWItems(worldobjects, filteredItems, player)
        end
    end

    -- Hook onGrabAllWItems (grab all)
    if ISWorldObjectContextMenu.onGrabAllWItems then
        local originalOnGrabAllWItems = ISWorldObjectContextMenu.onGrabAllWItems
        ISWorldObjectContextMenu.onGrabAllWItems = function(worldobjects, WItems, player)
            -- Safe filter: remove carts from list
            local filteredItems = WItems
            local notifiedPlayer = false

            pcall(function()
                if WItems and type(WItems) == "table" and #WItems > 0 then
                    local newItems = {}
                    for _, witem in ipairs(WItems) do
                        local item = safeGetItem(witem)
                        if item and SaucedCarts.safeIsCart(item) then
                            if not notifiedPlayer then
                                safeNotify(player)
                                notifiedPlayer = true
                            end
                            SaucedCarts.debug("Filtered cart from grab all")
                        else
                            table.insert(newItems, witem)
                        end
                    end
                    filteredItems = newItems
                end
            end)

            -- If nothing left after filtering, don't call original
            if type(filteredItems) == "table" and #filteredItems == 0 then
                return
            end

            return originalOnGrabAllWItems(worldobjects, filteredItems, player)
        end
    end

    hooksInitialized = true
    SaucedCarts.debug("Grab restriction hooks initialized")
end

-- ============================================================================
-- GRAB ACTION HOOK
-- ============================================================================
-- Hook ISGrabItemAction.new to show notification for grabs initiated via
-- item icons on ground. We don't block here - just notify and let
-- isItemAllowed handle the actual blocking.

local grabActionHookInitialized = false

local function initGrabActionHook()
    if grabActionHookInitialized then return end

    -- Ensure ISGrabItemAction exists
    if not ISGrabItemAction or not ISGrabItemAction.new then
        SaucedCarts.debug("ISGrabItemAction not found, skipping hook")
        return
    end

    local originalNew = ISGrabItemAction.new
    ISGrabItemAction.new = function(self, character, worldItem, time)
        -- Always create the action first - we need a valid return value
        local action = originalNew(self, character, worldItem, time)

        -- Safe check: show notification if this is a cart
        pcall(function()
            local item = safeGetItem(worldItem)
            if item and SaucedCarts.safeIsCart(item) then
                SaucedCarts.debug("Cart grab action created - isItemAllowed will block")
                safeNotify(character)
                -- Note: We don't block here. Let isItemAllowed (server-authoritative) handle it.
                -- The context menu hooks should have already filtered carts, so this is a fallback.
            end
        end)

        return action
    end

    grabActionHookInitialized = true
    SaucedCarts.debug("Grab action hook initialized")
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function onGameStart()
    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end

    initGrabHooks()
    initGrabActionHook()
end

Events.OnGameStart.Add(onGameStart)

-- ============================================================================
-- DEBUG API
-- ============================================================================

function GrabRestrictions.isInitialized()
    return hooksInitialized and grabActionHookInitialized
end

SaucedCarts.GrabRestrictions = GrabRestrictions

SaucedCarts.debug("GrabRestrictions module loaded")

return GrabRestrictions
