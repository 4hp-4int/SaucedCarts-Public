-- ============================================================================
-- SaucedCarts/Hotkeys.lua
-- ============================================================================
-- PURPOSE: Configurable hotkey to quickly equip/push or drop a cart.
--          Toggle behavior: equip if not holding, drop if holding.
--
-- CONTEXT: CLIENT ONLY
--          Keybinds and key events are client-side.
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/CartData"
require "SaucedCarts/TimedActions/ISCartPickupAction"
require "SaucedCarts/TimedActions/ISCartEquipAction"
require "TimedActions/ISDropWorldItemAction"

---@class SaucedCartsHotkeys
local Hotkeys = {}

-- ============================================================================
-- MOD OPTIONS KEYBIND (registered at file load time so options screen sees it)
-- ============================================================================

local modOptions = PZAPI.ModOptions:create("SaucedCarts", getText("UI_optionscreen_SaucedCarts") or "SaucedCarts")

local pushCartKeybind = modOptions:addKeyBind(
    "PushCart",
    getText("UI_optionscreen_binding_SaucedCarts_PushCart") or "Push/Drop Cart",
    Keyboard.KEY_V,
    getText("UI_optionscreen_binding_SaucedCarts_PushCart_tooltip") or "Quickly push a nearby cart or drop the one you're holding"
)

-- ============================================================================
-- CART FINDING HELPERS
-- ============================================================================

--- Find the nearest reachable cart on the ground
---@param player IsoPlayer
---@return IsoWorldInventoryObject|nil worldObj The world cart object
---@return InventoryItem|nil item The cart item
local function findNearestGroundCart(player)
    local playerSquare = player:getCurrentSquare()
    if not playerSquare then return nil, nil end

    local cx = playerSquare:getX()
    local cy = playerSquare:getY()
    local cz = playerSquare:getZ()

    local nearestCart = nil
    local nearestItem = nil
    local nearestDist = math.huge

    -- Search 5x5 area (2 tiles in each direction)
    for dy = -2, 2 do
        for dx = -2, 2 do
            local square = getCell():getGridSquare(cx + dx, cy + dy, cz)
            if square and playerSquare:canReachTo(square) then
                local objects = square:getWorldObjects()
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    if instanceof(obj, "IsoWorldInventoryObject") then
                        local item = obj:getItem()
                        if item and SaucedCarts.isCart(item) then
                            -- Calculate distance (manhattan for simplicity)
                            local dist = math.abs(dx) + math.abs(dy)
                            if dist < nearestDist then
                                nearestDist = dist
                                nearestCart = obj
                                nearestItem = item
                            end
                        end
                    end
                end
            end
        end
    end

    return nearestCart, nearestItem
end

--- Find a cart in the player's inventory
---@param player IsoPlayer
---@return InventoryItem|nil
local function findInventoryCart(player)
    local inventory = player:getInventory()
    if not inventory then return nil end

    local items = inventory:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if SaucedCarts.isCart(item) then
            -- Skip if already equipped
            local primary = player:getPrimaryHandItem()
            if not primary or primary:getID() ~= item:getID() then
                return item
            end
        end
    end

    return nil
end

-- ============================================================================
-- PLAYER STATE VALIDATION
-- ============================================================================

--- Check if the player can use the hotkey
---@param player IsoPlayer
---@return boolean
local function canPlayerAct(player)
    -- Must be alive
    if player:isDead() then return false end

    -- Must not be in vehicle
    if player:getVehicle() then return false end

    -- Must have a valid square
    if not player:getCurrentSquare() then return false end

    -- Must not be performing a timed action
    local actionQueue = ISTimedActionQueue.getTimedActionQueue(player)
    if actionQueue and actionQueue.queue and #actionQueue.queue > 0 then
        return false
    end

    return true
end

-- ============================================================================
-- HOTKEY HANDLER
-- ============================================================================

--- Handle the push/drop cart hotkey press
---@param key number The key code that was pressed
local function onKeyStartPressed(key)
    -- Must have keybind initialized
    if not pushCartKeybind then return end

    -- Check if this is our keybind
    if key ~= pushCartKeybind:getValue() then return end

    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end

    -- Get the local player (player index 0 for keyboard)
    local player = getSpecificPlayer(0)
    if not player then return end

    -- Validate player state
    if not canPlayerAct(player) then return end

    -- Check if currently holding a cart
    local primary = player:getPrimaryHandItem()
    local holdingCart = primary and SaucedCarts.isCart(primary)

    if holdingCart then
        -- DROP: Player is holding a cart, drop it
        local square = player:getCurrentSquare()
        if not square then return end

        -- Use vanilla drop action (MP-safe)
        -- Parameters: character, item, square, xoffset, yoffset, zoffset, rotation, isMultiple
        local dropAction = ISDropWorldItemAction:new(player, primary, square, 0.5, 0.5, 0.0, 0, false)
        ISTimedActionQueue.add(dropAction)

        SaucedCarts.debug("Hotkey: queued drop action for cart")
    else
        -- EQUIP: Find a cart to push

        -- Priority 1: Ground carts (nearest within 2 tiles)
        local worldCart, groundCartItem = findNearestGroundCart(player)
        if worldCart then
            -- Walk to the cart's square first, then queue pickup
            local cartSquare = worldCart:getSquare()
            if cartSquare and luautils.walkAdj(player, cartSquare, false) then
                ISTimedActionQueue.add(ISCartPickupAction.FromWorldItem(player, worldCart))
                SaucedCarts.debug("Hotkey: queued walk + pickup for ground cart")
            end
            return
        end

        -- Priority 2: Inventory carts
        local invCart = findInventoryCart(player)
        if invCart then
            -- Use timed action with MP sync (extracts serializable data)
            ISTimedActionQueue.add(ISCartEquipAction.FromCart(player, invCart))
            SaucedCarts.debug("Hotkey: queued equip action for inventory cart")
            return
        end

        -- No cart found - silent fail (no notification to avoid spam)
        SaucedCarts.debug("Hotkey: no cart found to push")
    end
end

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

local function onGameStart()
    Events.OnKeyStartPressed.Add(onKeyStartPressed)
    SaucedCarts.debug("Hotkeys: key handler registered")
end

Events.OnGameStart.Add(onGameStart)

SaucedCarts.debug("Hotkeys loaded")

return Hotkeys
