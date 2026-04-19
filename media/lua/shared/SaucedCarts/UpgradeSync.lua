-- ============================================================================
-- SaucedCarts/UpgradeSync.lua
-- ============================================================================
-- PURPOSE: MP network synchronization for cart flashlight upgrade states.
--          Handles toggle commands, state broadcasting, battery drain, and
--          late-joiner sync.
--
-- CONTEXT: SHARED (client + server)
--          Both contexts register their respective handlers.
--
-- COMMANDS:
--   toggleCartLight     - Client → Server: Toggle flashlight on/off
--   cartLightUpdate     - Server → All: Broadcast light state change
--   flashlightInstalled - Client → Server: Flashlight was installed
--   upgradeInstalled    - Server → All: Broadcast upgrade installed
--   batteryDepleted     - Server → Client: Battery depleted notification
--   requestUpgradeSync  - Client → Server: Late-joiner sync request
--   fullUpgradeSync     - Server → Client: Full upgrade state response
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/Upgrades"

SaucedCarts.UpgradeSync = {}

-- =============================================================================
-- CONSTANTS
-- =============================================================================

-- Battery check interval in ticks (~60 = 1 second)
local BATTERY_CHECK_INTERVAL = SaucedCarts.Config.BATTERY_CHECK_INTERVAL

-- Rate limiting for toggle requests
local TOGGLE_COOLDOWN = 0.5  -- seconds
local lastToggleTime = {}  -- [playerOnlineId] = gameTime

-- Active flashlight tracking (server-side optimization)
-- Instead of iterating all players for battery drain, track only active lights
-- Format: [onlineId] = { cartId = number }
local activeFlashlights = {}

-- =============================================================================
-- LOCAL/SP TOGGLE WRAPPERS (for singleplayer or direct calls)
-- =============================================================================
-- These wrappers handle both the actual toggle AND the tracking table updates.
-- Use these in SP or when called directly (not via network).

--- Toggle flashlight state and handle activeFlashlights tracking
---@param cart InventoryItem The cart with flashlight
---@param player IsoPlayer The player
---@return boolean newState The new flashlight state
---@return boolean success Whether toggle succeeded
function SaucedCarts.UpgradeSync.toggleFlashlightLocal(cart, player)
    if not cart or not player then
        return false, false
    end

    if not SaucedCarts.Upgrades.hasFlashlight(cart) then
        SaucedCarts.debug("UpgradeSync: toggleFlashlightLocal - no flashlight installed")
        return false, false
    end

    -- Toggle flashlight
    local newState, success = SaucedCarts.Upgrades.toggleFlashlight(cart, player)

    if success then
        local onlineId = player:getOnlineID()

        -- Track active flashlight for battery drain
        if newState then
            activeFlashlights[onlineId] = { cartId = cart:getID() }
            SaucedCarts.debug(function() return "Started tracking flashlight for player " .. onlineId .. " (local)" end)
        else
            activeFlashlights[onlineId] = nil
            SaucedCarts.debug(function() return "Stopped tracking flashlight for player " .. onlineId .. " (local)" end)
        end
    end

    return newState, success
end

-- =============================================================================
-- RATE LIMITING (Server)
-- =============================================================================

--- Check if a player can toggle (rate limit check)
--- Exposed as _canPlayerToggle for unit testing
---@param player IsoPlayer
---@param currentTime number|nil Optional override for current time (for testing)
---@return boolean canToggle
local function canPlayerToggle(player, currentTime)
    if not player then return false end
    local playerId = player:getOnlineID()
    currentTime = currentTime or (getGameTime():getWorldAgeHours() * 3600)

    local lastTime = lastToggleTime[playerId] or 0
    if currentTime - lastTime < TOGGLE_COOLDOWN then
        return false
    end

    lastToggleTime[playerId] = currentTime
    return true
end

-- Expose for unit testing
SaucedCarts.UpgradeSync._canPlayerToggle = canPlayerToggle
SaucedCarts.UpgradeSync._TOGGLE_COOLDOWN = TOGGLE_COOLDOWN

--- Find a cart by ID, checking hands, inventory, and optionally ground
---@param player IsoPlayer The player who might have the cart
---@param cartId number The cart's item ID
---@param squareX number|nil X coordinate if cart is on ground
---@param squareY number|nil Y coordinate if cart is on ground
---@param squareZ number|nil Z coordinate if cart is on ground
---@return InventoryItem|nil cart The cart item or nil if not found
local function findCartByIdAndLocation(player, cartId, squareX, squareY, squareZ)
    if not player or not cartId then return nil end

    -- Check equipped hands first
    local primary = player:getPrimaryHandItem()
    if primary and primary:getID() == cartId then
        return primary
    end

    local secondary = player:getSecondaryHandItem()
    if secondary and secondary:getID() == cartId then
        return secondary
    end

    -- Check player inventory
    local inv = player:getInventory()
    if inv then
        local cart = inv:getItemById(cartId)
        if cart then return cart end
    end

    -- Check ground if coords provided
    if squareX then
        local square = getCell():getGridSquare(squareX, squareY, squareZ)
        if square then
            local objects = square:getWorldObjects()
            if objects then
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    if instanceof(obj, "IsoWorldInventoryObject") then
                        local item = obj:getItem()
                        if item and item:getID() == cartId then
                            return item
                        end
                    end
                end
            end
        end
    end

    return nil
end

--- Reset rate limit state (for testing)
function SaucedCarts.UpgradeSync._resetRateLimits()
    lastToggleTime = {}
end

--- Get active flashlights table (for testing)
function SaucedCarts.UpgradeSync._getActiveFlashlights()
    return activeFlashlights
end

-- Clean up tracking when player disconnects
if isServer() and Events and Events.OnPlayerDisconnect then
    Events.OnPlayerDisconnect.Add(function(player)
        if player then
            local onlineId = player:getOnlineID()
            lastToggleTime[onlineId] = nil
            activeFlashlights[onlineId] = nil
        end
    end)
end

-- =============================================================================
-- CLIENT → SERVER: Toggle Cart Light
-- =============================================================================

--- Request toggle of cart flashlight
---@param player IsoPlayer The player making the request
---@param cartId number The cart's item ID
function SaucedCarts.UpgradeSync.requestToggle(player, cartId)
    if not isClient() then return end

    SaucedCarts.Network.sendToServer(player, "toggleCartLight", {
        cartId = cartId,
    })

    SaucedCarts.debug(function() return "UpgradeSync: requested light toggle for cart " .. tostring(cartId) end)
end

-- Server handler: Toggle light and broadcast result
if isServer() then
    SaucedCarts.Network.registerServerHandler("toggleCartLight", function(player, args)
        if not args or not args.cartId then
            SaucedCarts.debug("UpgradeSync: toggleCartLight - invalid args")
            return
        end

        -- Rate limit check
        if not canPlayerToggle(player) then
            SaucedCarts.debug("UpgradeSync: toggleCartLight - rate limited")
            return
        end

        -- Find the cart in player's hands or inventory
        local cart = nil

        -- Check equipped hands first
        local primary = player:getPrimaryHandItem()
        if primary and primary:getID() == args.cartId then
            cart = primary
        end
        if not cart then
            local secondary = player:getSecondaryHandItem()
            if secondary and secondary:getID() == args.cartId then
                cart = secondary
            end
        end

        -- Check inventory
        if not cart then
            local inv = player:getInventory()
            if inv then
                cart = inv:getItemById(args.cartId)
            end
        end

        if not cart then
            SaucedCarts.debug("UpgradeSync: toggleCartLight - cart not found")
            return
        end

        -- Toggle using Upgrades module
        local newState, success = SaucedCarts.Upgrades.toggleFlashlight(cart, player)

        if not success then
            SaucedCarts.debug("UpgradeSync: toggleCartLight - toggle failed")
            return
        end

        -- Update active flashlight tracking for battery drain optimization
        local onlineId = player:getOnlineID()
        if newState then
            activeFlashlights[onlineId] = { cartId = args.cartId }
        else
            activeFlashlights[onlineId] = nil
        end

        -- Broadcast to all clients
        SaucedCarts.Network.broadcast("cartLightUpdate", {
            playerOnlineId = onlineId,
            cartId = args.cartId,
            isActive = newState,
        })

        -- Sync item ModData and fields
        syncItemModData(player, cart)
        syncItemFields(player, cart)

        SaucedCarts.debug(function() return "UpgradeSync: toggled light to " .. tostring(newState) end)
    end)
end

-- =============================================================================
-- SERVER → CLIENT: Light State Update
-- =============================================================================

if isClient() then
    SaucedCarts.Network.registerClientHandler("cartLightUpdate", function(args)
        if not args then return end

        -- Skip if this is our own update
        local localPlayer = getSpecificPlayer(0)
        if localPlayer and args.playerOnlineId == localPlayer:getOnlineID() then
            SaucedCarts.debug("UpgradeSync: skipping own light update")
            return
        end

        -- Find the player who owns this cart
        local targetPlayer = getPlayerByOnlineID(args.playerOnlineId)
        if not targetPlayer then
            SaucedCarts.debug("UpgradeSync: player not found for light update")
            return
        end

        -- Find the cart (check all locations)
        local cart = nil
        local primary = targetPlayer:getPrimaryHandItem()
        if primary and primary:getID() == args.cartId then
            cart = primary
        end
        if not cart then
            local secondary = targetPlayer:getSecondaryHandItem()
            if secondary and secondary:getID() == args.cartId then
                cart = secondary
            end
        end
        if not cart then
            local inv = targetPlayer:getInventory()
            if inv then
                cart = inv:getItemById(args.cartId)
            end
        end

        if not cart then
            SaucedCarts.debug("UpgradeSync: cart not found for light update")
            return
        end

        -- Update local state
        SaucedCarts.Upgrades.setLightActive(cart, args.isActive)

        -- Enable/disable cart light for remote player's cart
        if args.isActive then
            SaucedCarts.Upgrades.enableCartLight(cart)
        else
            SaucedCarts.Upgrades.disableCartLight(cart)
        end

        -- Update visual
        if SaucedCarts.updateCartVisual then
            SaucedCarts.updateCartVisual(cart, targetPlayer)
        end

        SaucedCarts.debug(function() return "UpgradeSync: applied light update - active=" .. tostring(args.isActive) end)
    end)
end

-- =============================================================================
-- CLIENT → SERVER: Flashlight Installed
-- =============================================================================

--- Notify server that flashlight was installed (with data for server-side sync)
---@param player IsoPlayer The player
---@param cartId number The cart's item ID
---@param flashlightData table The flashlight properties to apply
---@param batteryCharge number The battery charge level
---@param squareX number|nil X coordinate if cart is on ground
---@param squareY number|nil Y coordinate if cart is on ground
---@param squareZ number|nil Z coordinate if cart is on ground
function SaucedCarts.UpgradeSync.notifyFlashlightInstalled(player, cartId, flashlightData, batteryCharge, squareX, squareY, squareZ)
    if not isClient() then return end

    SaucedCarts.Network.sendToServer(player, "flashlightInstalled", {
        cartId = cartId,
        flashlightData = flashlightData,
        batteryCharge = batteryCharge or 0,
        squareX = squareX,
        squareY = squareY,
        squareZ = squareZ,
    })
end

-- Server handler: Apply upgrade to server's copy, then broadcast
if isServer() then
    SaucedCarts.Network.registerServerHandler("flashlightInstalled", function(player, args)
        if not args or not args.cartId then
            SaucedCarts.debug("UpgradeSync: flashlightInstalled - missing args or cartId")
            return
        end

        SaucedCarts.debug(function() return string.format(
            "UpgradeSync: flashlightInstalled received - cartId=%s, squareX=%s, squareY=%s, squareZ=%s",
            tostring(args.cartId), tostring(args.squareX), tostring(args.squareY), tostring(args.squareZ)
        ) end)

        -- Find the cart on the server
        local cart = nil

        -- Check player inventory first
        cart = player:getInventory():getItemById(args.cartId)
        if cart then
            SaucedCarts.debug("UpgradeSync: found cart in player inventory")
        end

        -- Check equipped hands
        if not cart then
            local primary = player:getPrimaryHandItem()
            if primary and primary:getID() == args.cartId then
                cart = primary
                SaucedCarts.debug("UpgradeSync: found cart in primary hand")
            end
        end

        if not cart then
            local secondary = player:getSecondaryHandItem()
            if secondary and secondary:getID() == args.cartId then
                cart = secondary
                SaucedCarts.debug("UpgradeSync: found cart in secondary hand")
            end
        end

        -- Check world (ground cart) - CRITICAL for install actions on ground carts
        if not cart and args.squareX and args.squareY and args.squareZ then
            local square = getCell():getGridSquare(args.squareX, args.squareY, args.squareZ)
            if square then
                local objects = square:getWorldObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if instanceof(obj, "IsoWorldInventoryObject") then
                            local item = obj:getItem()
                            if item and item:getID() == args.cartId then
                                cart = item
                                SaucedCarts.debug("UpgradeSync: found cart on ground")
                                break
                            end
                        end
                    end
                end
            else
                SaucedCarts.debug("UpgradeSync: square not found at coords")
            end
        end

        if not cart then
            SaucedCarts.debug("UpgradeSync: could not find cart anywhere")
            return
        end

        if args.flashlightData then
            -- Apply the upgrade data to the server's copy
            local modData = cart:getModData()
            modData.SaucedCarts_hasFlashlight = true
            modData.SaucedCarts_flashlightData = args.flashlightData
            modData.SaucedCarts_batteryCharge = args.batteryCharge or 0
            modData.SaucedCarts_isLightActive = false

            -- Sync ModData back to all clients (only for equipped carts)
            -- syncItemModData fails for world items (container not replicated to clients)
            local isOnGround = args.squareX ~= nil
            if not isOnGround then
                syncItemModData(player, cart)
                syncItemFields(player, cart)
            end

            SaucedCarts.debug("UpgradeSync: applied flashlight data to server cart")
        else
            SaucedCarts.debug("UpgradeSync: no flashlightData in args")
        end

        -- Broadcast to all clients for visual update
        SaucedCarts.Network.broadcast("upgradeInstalled", {
            playerOnlineId = player:getOnlineID(),
            cartId = args.cartId,
            upgradeType = "flashlight",
            squareX = args.squareX,
            squareY = args.squareY,
            squareZ = args.squareZ,
        })

        SaucedCarts.debug("UpgradeSync: broadcast flashlight installation")
    end)
end

-- Client handler: Update visual when upgrade installed
-- CRITICAL: Do NOT skip local player - in Build 42 MP, action runs on server,
-- so local client needs this broadcast to refresh their hand model.
if isClient() then
    SaucedCarts.Network.registerClientHandler("upgradeInstalled", function(args)
        if not args then return end

        local localPlayer = getSpecificPlayer(0)
        local isLocalPlayer = localPlayer and args.playerOnlineId == localPlayer:getOnlineID()

        -- Find the player and cart
        local targetPlayer
        if isLocalPlayer then
            targetPlayer = localPlayer
        else
            targetPlayer = getPlayerByOnlineID(args.playerOnlineId)
        end

        if not targetPlayer then return end

        -- Find cart - check ALL locations
        -- BUG FIX: Previously only checked primary hand, missing secondary/inventory
        local cart = nil

        -- Check equipped hands first
        local primary = targetPlayer:getPrimaryHandItem()
        if primary and primary:getID() == args.cartId then
            cart = primary
        end
        if not cart then
            local secondary = targetPlayer:getSecondaryHandItem()
            if secondary and secondary:getID() == args.cartId then
                cart = secondary
            end
        end

        -- Check player inventory (cart might not be equipped)
        if not cart then
            local inv = targetPlayer:getInventory()
            if inv then
                cart = inv:getItemById(args.cartId)
            end
        end

        -- Check ground cart using coords from broadcast
        -- In Build 42, perform() runs on server, so ground carts need this broadcast to update visuals
        if not cart and args.squareX then
            cart = SaucedCarts.Network.findGroundCart(
                args.squareX, args.squareY, args.squareZ, args.cartId)
        end

        if cart then
            local modData = cart:getModData()

            -- Force visual update by clearing previous upgrade key
            -- This ensures updateCartVisual detects a change
            modData.SaucedCarts_upgradeKey = nil

            -- Update visual (includes resetEquippedHandsModels if equipped)
            if SaucedCarts.updateCartVisual then
                SaucedCarts.updateCartVisual(cart, targetPlayer)
            end

            SaucedCarts.debug(function() return "UpgradeSync: upgradeInstalled visual refresh for " ..
                (isLocalPlayer and "local" or "remote") .. " player, upgrade=" .. tostring(args.upgradeType) end)
        end
    end)
end

-- =============================================================================
-- LATE-JOINER SYNC
-- =============================================================================

--- Request full upgrade state sync (called when player joins)
---@param player IsoPlayer The player requesting sync
function SaucedCarts.UpgradeSync.requestSync(player)
    if not isClient() then return end

    SaucedCarts.Network.sendToServer(player, "requestUpgradeSync", {})
    SaucedCarts.debug("UpgradeSync: requested full sync")
end

-- Server handler: Send full upgrade state
if isServer() then
    SaucedCarts.Network.registerServerHandler("requestUpgradeSync", function(player, args)
        local states = {}

        local players = getOnlinePlayers()
        for i = 0, players:size() - 1 do
            local otherPlayer = players:get(i)
            local inv = otherPlayer:getInventory()
            if inv then
                local items = inv:getItems()
                for j = 0, items:size() - 1 do
                    local item = items:get(j)
                    if SaucedCarts.isCart(item) then
                        local hasFlashlight = SaucedCarts.Upgrades.hasFlashlight(item)

                        -- Only include carts with flashlight
                        if hasFlashlight then
                            local state = {
                                playerOnlineId = otherPlayer:getOnlineID(),
                                cartId = item:getID(),
                                hasFlashlight = true,
                                isLightActive = SaucedCarts.Upgrades.isLightActive(item),
                                batteryCharge = SaucedCarts.Upgrades.getBatteryCharge(item),
                                flashlightData = SaucedCarts.Upgrades.getFlashlightData(item),
                            }
                            table.insert(states, state)
                        end
                    end
                end
            end
        end

        SaucedCarts.Network.sendToClient(player, "fullUpgradeSync", {
            states = states,
        })

        SaucedCarts.debug(function() return "UpgradeSync: sent full sync with " .. #states .. " cart states" end)
    end)
end

-- Client handler: Apply full sync
if isClient() then
    SaucedCarts.Network.registerClientHandler("fullUpgradeSync", function(args)
        if not args or not args.states then return end

        local localPlayer = getSpecificPlayer(0)
        local localOnlineId = localPlayer and localPlayer:getOnlineID()

        local applied = 0
        for _, cartState in ipairs(args.states) do
            -- Skip our own carts
            if cartState.playerOnlineId ~= localOnlineId then
                local targetPlayer = getPlayerByOnlineID(cartState.playerOnlineId)
                if targetPlayer then
                    local cart = nil
                    local primary = targetPlayer:getPrimaryHandItem()
                    if primary and primary:getID() == cartState.cartId then
                        cart = primary
                    end
                    if not cart then
                        local secondary = targetPlayer:getSecondaryHandItem()
                        if secondary and secondary:getID() == cartState.cartId then
                            cart = secondary
                        end
                    end
                    if not cart then
                        local inv = targetPlayer:getInventory()
                        if inv then
                            cart = inv:getItemById(cartState.cartId)
                        end
                    end

                    if cart then
                        local modData = cart:getModData()

                        -- Apply flashlight state
                        if cartState.hasFlashlight then
                            modData.SaucedCarts_hasFlashlight = true
                            modData.SaucedCarts_isLightActive = cartState.isLightActive
                            modData.SaucedCarts_batteryCharge = cartState.batteryCharge
                            modData.SaucedCarts_flashlightData = cartState.flashlightData

                            -- Enable cart light if active
                            if cartState.isLightActive then
                                SaucedCarts.Upgrades.enableCartLight(cart)
                            end
                        end

                        -- Update visual
                        if SaucedCarts.updateCartVisual then
                            SaucedCarts.updateCartVisual(cart, targetPlayer)
                        end

                        applied = applied + 1
                    end
                end
            end
        end

        SaucedCarts.debug(function() return "UpgradeSync: applied full sync to " .. applied .. " carts" end)
    end)
end

-- =============================================================================
-- AUTO-SYNC ON PLAYER JOIN
-- =============================================================================

if isClient() then
    local syncRequested = false

    Events.OnCreatePlayer.Add(function(playerIndex, player)
        if not syncRequested then
            syncRequested = true
            local function doSyncOnce()
                local localPlayer = getSpecificPlayer(0)
                if localPlayer then
                    SaucedCarts.UpgradeSync.requestSync(localPlayer)
                    Events.OnTick.Remove(doSyncOnce)
                end
            end
            Events.OnTick.Add(doSyncOnce)
        end
    end)
end

-- =============================================================================
-- SERVER BATTERY DRAIN TICK
-- =============================================================================
-- Flashlight battery drain handled on server tick.
-- Active flashlights are tracked in activeFlashlights table.

local batteryCheckTick = 0

-- Helper to check if table is empty (avoid pairs() overhead when possible)
local function tableIsEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

local function onServerTick()
    if isClient() then return end  -- Skip on MP client, run in SP + MP server

    batteryCheckTick = batteryCheckTick + 1
    if batteryCheckTick < BATTERY_CHECK_INTERVAL then
        return
    end
    batteryCheckTick = 0

    -- Fast path: no active flashlights
    if tableIsEmpty(activeFlashlights) then return end

    local deltaTime = BATTERY_CHECK_INTERVAL / 60  -- Convert ticks to seconds

    -- -------------------------------------------------------------------------
    -- FLASHLIGHT BATTERY DRAIN
    -- -------------------------------------------------------------------------
    local toRemove = {}

    for onlineId, data in pairs(activeFlashlights) do
        local player = getPlayerByOnlineID(onlineId)
        if not player then
            -- Singleplayer fallback - only one player
            player = getSpecificPlayer(0)
        end
        if not player then
            -- Player truly disconnected (cleanup missed by event)
            table.insert(toRemove, onlineId)
        else
            local cart = SaucedCarts.getHeldCart(player)

            -- Validate cart is still held and matches tracked ID
            if not cart or cart:getID() ~= data.cartId then
                -- Cart changed (dropped, swapped, etc.) - stop tracking
                table.insert(toRemove, onlineId)
            elseif SaucedCarts.Upgrades.isLightActive(cart) then
                local depleted = SaucedCarts.Upgrades.drainBattery(cart, deltaTime)

                if depleted then
                    -- Battery depleted - turn off light
                    SaucedCarts.debug(function() return "UpgradeSync: flashlight battery depleted for player " .. player:getUsername() end)

                    SaucedCarts.Upgrades.setLightActive(cart, false)
                    SaucedCarts.Upgrades.disableCartLight(cart)

                    -- Stop tracking (light is off)
                    table.insert(toRemove, onlineId)

                    -- Broadcast state change
                    SaucedCarts.Network.broadcast("cartLightUpdate", {
                        playerOnlineId = onlineId,
                        cartId = cart:getID(),
                        isActive = false,
                    })

                    -- Notify player
                    SaucedCarts.Network.sendToClient(player, "batteryDepleted", {
                        cartId = cart:getID(),
                    })

                    -- Sync item state
                    syncItemModData(player, cart)
                    syncItemFields(player, cart)
                end
            else
                -- Light was turned off elsewhere - stop tracking
                table.insert(toRemove, onlineId)
            end
        end
    end

    -- Clean up stale flashlight entries
    for _, onlineId in ipairs(toRemove) do
        activeFlashlights[onlineId] = nil
    end
end

-- Register in SP + MP server (not MP client)
if not isClient() then
    Events.OnTick.Add(onServerTick)
end

-- =============================================================================
-- CLIENT: Battery Depleted Handler
-- =============================================================================

if isClient() then
    SaucedCarts.Network.registerClientHandler("batteryDepleted", function(args)
        if not args then return end

        local localPlayer = getSpecificPlayer(0)
        if not localPlayer then return end

        -- Find the cart
        local cart = nil
        local primary = localPlayer:getPrimaryHandItem()
        if primary and primary:getID() == args.cartId then
            cart = primary
        end
        if not cart then
            local inv = localPlayer:getInventory()
            if inv then
                cart = inv:getItemById(args.cartId)
            end
        end

        if cart then
            -- Disable cart light locally
            SaucedCarts.Upgrades.disableCartLight(cart)

            -- Notify player
            if SaucedCarts.Notifications then
                SaucedCarts.Notifications.warn(localPlayer,
                    getText("UI_SaucedCarts_BatteryDepleted") or "Cart flashlight battery depleted!",
                    "battery_depleted")
            end
        end
    end)
end

-- =============================================================================
-- DEBUG API
-- =============================================================================

--- Get count of active flashlights being tracked (server only)
---@return number
function SaucedCarts.UpgradeSync.getActiveFlashlightCount()
    if not isServer() then return 0 end
    local count = 0
    for _ in pairs(activeFlashlights) do count = count + 1 end
    return count
end

-- =============================================================================
-- EVENT-DRIVEN SYNC
-- =============================================================================
-- Centralized sync logic: events automatically trigger network sync.
-- This ensures sync happens regardless of how the event was triggered.
-- Only fires on client - server receives and applies state.

--- Helper: Get square coordinates from cart if on ground
---@param cart InventoryItem
---@return number|nil, number|nil, number|nil
local function getCartSquareCoords(cart)
    local worldItem = cart:getWorldItem()
    if worldItem then
        local sq = worldItem:getSquare()
        if sq then
            return sq:getX(), sq:getY(), sq:getZ()
        end
    end
    return nil, nil, nil
end

-- Flashlight installed → sync to server
if SaucedCarts.Events and SaucedCarts.Events.onFlashlightInstalled then
    SaucedCarts.Events.onFlashlightInstalled:Add(function(player, cart, flashlightType)
        if not isClient() then return end
        if not cart or not player then return end

        local modData = cart:getModData()
        local squareX, squareY, squareZ = getCartSquareCoords(cart)

        SaucedCarts.Network.sendToServer(player, "flashlightInstalled", {
            cartId = cart:getID(),
            flashlightData = modData.SaucedCarts_flashlightData,
            batteryCharge = modData.SaucedCarts_batteryCharge or 0,
            squareX = squareX,
            squareY = squareY,
            squareZ = squareZ,
        })

        SaucedCarts.debug(function() return "EventSync: flashlightInstalled sent for cart " .. cart:getID() end)
    end)
end

-- Battery inserted → sync to server
if SaucedCarts.Events and SaucedCarts.Events.onBatteryInserted then
    SaucedCarts.Events.onBatteryInserted:Add(function(player, cart, chargeAmount)
        if not isClient() then return end
        if not cart or not player then return end

        local modData = cart:getModData()
        local squareX, squareY, squareZ = getCartSquareCoords(cart)

        SaucedCarts.Network.sendToServer(player, "batteryUpdated", {
            cartId = cart:getID(),
            batteryCharge = modData.SaucedCarts_batteryCharge or 0,
            squareX = squareX,
            squareY = squareY,
            squareZ = squareZ,
        })

        SaucedCarts.debug(function() return "EventSync: batteryInserted sent for cart " .. cart:getID() end)
    end)
end

-- Battery removed → sync to server
if SaucedCarts.Events and SaucedCarts.Events.onBatteryRemoved then
    SaucedCarts.Events.onBatteryRemoved:Add(function(player, cart, chargeAmount)
        if not isClient() then return end
        if not cart or not player then return end

        local squareX, squareY, squareZ = getCartSquareCoords(cart)

        SaucedCarts.Network.sendToServer(player, "batteryUpdated", {
            cartId = cart:getID(),
            batteryCharge = 0,
            squareX = squareX,
            squareY = squareY,
            squareZ = squareZ,
        })

        SaucedCarts.debug(function() return "EventSync: batteryRemoved sent for cart " .. cart:getID() end)
    end)
end

-- Cart visual update → sync to server (for ground carts)
if SaucedCarts.Events and SaucedCarts.Events.onCartVisualUpdate then
    SaucedCarts.Events.onCartVisualUpdate:Add(function(cart, fillState, modelName)
        if not isClient() then return end
        if not cart then return end

        local squareX, squareY, squareZ = getCartSquareCoords(cart)

        -- Only sync ground carts - equipped carts are synced via other mechanisms
        if squareX then
            local player = getPlayer()
            if player then
                SaucedCarts.Network.sendToServer(player, "syncGroundCartVisual", {
                    squareX = squareX,
                    squareY = squareY,
                    squareZ = squareZ,
                    cartId = cart:getID(),
                })
            end
        end
    end)
end

-- Cart repaired → broadcast to all clients (server-side event)
-- This ensures all nearby clients see the condition update, not just the repairer
if SaucedCarts.Events and SaucedCarts.Events.onCartRepair then
    SaucedCarts.Events.onCartRepair:Add(function(player, cart, repairAmount, newCondition)
        -- Only server broadcasts (event fires on server for ground carts)
        if isClient() then return end
        if not cart or not newCondition then return end

        local squareX, squareY, squareZ = getCartSquareCoords(cart)

        -- Only broadcast for ground carts - inventory carts use syncItemFields
        if squareX then
            SaucedCarts.Network.broadcast("repairComplete", {
                cartId = cart:getID(),
                newCondition = newCondition,
                squareX = squareX,
                squareY = squareY,
                squareZ = squareZ,
            })

            SaucedCarts.debug(function() return "EventSync: repairComplete broadcast for cart " .. cart:getID() end)
        end
    end)
end

-- Server handler: Battery update (from event-driven sync)
if isServer() then
    SaucedCarts.Network.registerServerHandler("batteryUpdated", function(player, args)
        if not args or not args.cartId then return end

        local cart = findCartByIdAndLocation(player, args.cartId, args.squareX, args.squareY, args.squareZ)
        if not cart then
            SaucedCarts.debug("UpgradeSync: batteryUpdated - cart not found")
            return
        end

        local modData = cart:getModData()
        modData.SaucedCarts_batteryCharge = args.batteryCharge or 0

        -- Sync ModData (only for equipped carts - ground carts don't need this)
        local isOnGround = args.squareX ~= nil
        if not isOnGround then
            syncItemModData(player, cart)
        end
        SaucedCarts.debug(function() return "UpgradeSync: battery updated to " .. tostring(args.batteryCharge) end)
    end)
end

SaucedCarts.debug("UpgradeSync: Event-driven sync listeners registered")

-- =============================================================================
-- MODULE INITIALIZATION
-- =============================================================================

SaucedCarts.debug("UpgradeSync module loaded")

return SaucedCarts.UpgradeSync
