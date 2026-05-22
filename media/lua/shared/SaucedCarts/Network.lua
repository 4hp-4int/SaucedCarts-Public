-- ============================================================================
-- SaucedCarts/Network.lua
-- ============================================================================
-- PURPOSE: Centralized MP network sync for SaucedCarts.
--          Provides standard patterns for client-server communication.
--
-- CONTEXT: SHARED (client + server)
--          Both contexts register their respective handlers.
--
-- COMMANDS:
--   repairComplete        - Server → Client: Repair condition update
--   syncGroundCartVisual  - Client → Server: Request visual sync
--   updateGroundCartVisual - Server → All: Broadcast visual update
--
-- USAGE:
--   -- Register a handler (call once at module load)
--   SaucedCarts.Network.registerClientHandler("commandName", function(args) ... end)
--   SaucedCarts.Network.registerServerHandler("commandName", function(player, args) ... end)
--
--   -- Send commands
--   SaucedCarts.Network.sendToClient(player, "command", args)  -- Server → Client
--   SaucedCarts.Network.sendToServer(player, "command", args)  -- Client → Server
--   SaucedCarts.Network.broadcast("command", args)             -- Server → All
--
-- SERIALIZABLE TYPES (TableNetworkUtils.java):
--   Keys: String, Double (numbers)
--   Values: String, Double, Boolean, nested Table, InventoryItem, IsoDirections
-- ============================================================================

require "SaucedCarts/Core"

SaucedCarts.Network = {}

-- =============================================================================
-- TEST MODE SUPPORT
-- =============================================================================
-- When test mode is enabled, network calls are captured for inspection
-- instead of (or in addition to) being sent over the network.

SaucedCarts.Network._testMode = false
SaucedCarts.Network._capturedMessages = {
    broadcasts = {},      -- {command, args}
    toClient = {},        -- {player, command, args}
    toServer = {},        -- {player, command, args}
}

--- Enable test mode - captures network messages for inspection
function SaucedCarts.Network.enableTestMode()
    SaucedCarts.Network._testMode = true
    SaucedCarts.Network._capturedMessages = {
        broadcasts = {},
        toClient = {},
        toServer = {},
    }
end

--- Disable test mode
function SaucedCarts.Network.disableTestMode()
    SaucedCarts.Network._testMode = false
end

--- Clear captured messages (useful between tests)
function SaucedCarts.Network.clearCapturedMessages()
    SaucedCarts.Network._capturedMessages = {
        broadcasts = {},
        toClient = {},
        toServer = {},
    }
end

--- Get captured broadcasts
---@return table[] List of {command, args} tables
function SaucedCarts.Network.getCapturedBroadcasts()
    return SaucedCarts.Network._capturedMessages.broadcasts
end

--- Get captured toClient messages
---@return table[] List of {player, command, args} tables
function SaucedCarts.Network.getCapturedToClient()
    return SaucedCarts.Network._capturedMessages.toClient
end

--- Get captured toServer messages
---@return table[] List of {player, command, args} tables
function SaucedCarts.Network.getCapturedToServer()
    return SaucedCarts.Network._capturedMessages.toServer
end

-- =============================================================================
-- GROUND CART LOOKUP HELPER
-- =============================================================================
-- Standard pattern: find cart by coordinates + item ID
-- This avoids serializing object references which don't survive MP transit.

--- Find a ground cart by coordinates and item ID
--- Use this in handlers that receive cart location data
---@param squareX number X coordinate
---@param squareY number Y coordinate
---@param squareZ number Z coordinate
---@param cartId number The cart's item ID
---@return InventoryItem|nil cart The cart item, or nil if not found
---@return IsoWorldInventoryObject|nil worldObj The world object, or nil if not found
function SaucedCarts.Network.findGroundCart(squareX, squareY, squareZ, cartId)
    local square = getCell():getGridSquare(squareX, squareY, squareZ)
    if not square then return nil, nil end

    local objects = square:getWorldObjects()
    if not objects then return nil, nil end

    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if instanceof(obj, "IsoWorldInventoryObject") then
            local item = obj:getItem()
            if item and item:getID() == cartId then
                return item, obj
            end
        end
    end
    return nil, nil
end

--- Find a ground cart's container and return the cart item.
--- This is a helper for server-side logic to reliably identify carts.
---@param container ItemContainer The container to check.
---@return InventoryItem|nil cart The cart item, or nil if not a ground cart container.
function SaucedCarts.Network.getGroundCartFromContainer(container)
    if not container then return nil end

    -- Method 1: Check parent, but only if it's a world item.
    local parent = container:getParent()
    if parent and SaucedCarts.isCart(parent) and parent:getWorldItem() then
        return parent
    end

    -- Method 2: getContainingItem() (more reliable fallback)
    local containingItem = container:getContainingItem()
    if containingItem and SaucedCarts.isCart(containingItem) and containingItem:getWorldItem() then
        return containingItem
    end

    return nil
end

--------------------------------------------------------------------------------
-- Client-to-Server Command Registration
--------------------------------------------------------------------------------
-- Client sends commands, server registers handlers to respond.


--- Extract location data from a ground cart for network transmission
--- Use this when preparing args to send
---@param cart InventoryItem The cart item (must have worldItem)
---@return table|nil args Table with squareX, squareY, squareZ, cartId; or nil if not a ground cart
function SaucedCarts.Network.getGroundCartLocation(cart)
    if not cart then return nil end
    local worldItem = cart:getWorldItem()
    if not worldItem then return nil end
    local sq = worldItem:getSquare()
    if not sq then return nil end

    return {
        squareX = sq:getX(),
        squareY = sq:getY(),
        squareZ = sq:getZ(),
        cartId = cart:getID(),
    }
end

--- Check if a container belongs to a cart (ground or equipped)
--- Shared helper used by both client and server transfer detection.
---@param container ItemContainer The container to check
---@param player IsoPlayer|nil Optional player to check equipped items
---@return InventoryItem|nil cart The cart item, or nil if not a cart container
function SaucedCarts.Network.getCartFromContainer(container, player)
    if not container then return nil end

    -- Safety check: need these globals to function
    if not SaucedCarts or not SaucedCarts.isCart or not instanceof then
        return nil
    end

    -- Method 1: Check parent if it's an InventoryItem
    if type(container.getParent) == "function" then
        local parent = container:getParent()
        if parent and instanceof(parent, "InventoryItem") and SaucedCarts.isCart(parent) then
            return parent
        end
    end

    -- Method 2: getContainingItem() - most reliable for ground carts
    if type(container.getContainingItem) == "function" then
        local containingItem = container:getContainingItem()
        if containingItem and SaucedCarts.isCart(containingItem) then
            return containingItem
        end
    end

    -- Method 3: For equipped carts, check player's hands
    if player and type(player.getPrimaryHandItem) == "function" then
        local primary = player:getPrimaryHandItem()
        if primary and type(primary.getItemContainer) == "function" then
            if primary:getItemContainer() == container and SaucedCarts.isCart(primary) then
                return primary
            end
        end
    end

    return nil
end

-- =============================================================================
-- SEND WRAPPERS
-- =============================================================================
-- Provide consistent logging and validation for all network operations.

--- Send a command from server to a specific client
---@param player IsoPlayer The player to send to
---@param command string The command name
---@param args table The arguments (primitives only)
---@return boolean success True if sent, false if wrong context or invalid
function SaucedCarts.Network.sendToClient(player, command, args)
    -- Capture in test mode
    if SaucedCarts.Network._testMode then
        table.insert(SaucedCarts.Network._capturedMessages.toClient, {
            player = player,
            command = command,
            args = args,
        })
    end

    if not isServer() then
        -- In test mode, return true to simulate success
        if SaucedCarts.Network._testMode then return true end
        SaucedCarts.debug("Network.sendToClient: not server, ignoring")
        return false
    end
    if not player then
        SaucedCarts.error("Network.sendToClient: player is nil for command " .. tostring(command))
        return false
    end
    sendServerCommand(player, "SaucedCarts", command, args)
    SaucedCarts.debug(function() return "Network: sent " .. command .. " to " .. tostring(player:getUsername()) end)
    return true
end

--- Send a command from client to server
---@param player IsoPlayer The local player sending the command
---@param command string The command name
---@param args table The arguments (primitives only)
---@return boolean success True if sent, false if wrong context or invalid
function SaucedCarts.Network.sendToServer(player, command, args)
    -- Capture in test mode
    if SaucedCarts.Network._testMode then
        table.insert(SaucedCarts.Network._capturedMessages.toServer, {
            player = player,
            command = command,
            args = args,
        })
    end

    if not isClient() then
        -- In test mode, return true to simulate success
        if SaucedCarts.Network._testMode then return true end
        SaucedCarts.debug("Network.sendToServer: not client, ignoring")
        return false
    end
    sendClientCommand(player, "SaucedCarts", command, args)
    SaucedCarts.debug(function() return "Network: sent " .. command .. " to server" end)
    return true
end

--- Broadcast a command from server to all connected clients
---@param command string The command name
---@param args table The arguments (primitives only)
---@return boolean success True if sent, false if wrong context
function SaucedCarts.Network.broadcast(command, args)
    -- Capture in test mode
    if SaucedCarts.Network._testMode then
        table.insert(SaucedCarts.Network._capturedMessages.broadcasts, {
            command = command,
            args = args,
        })
    end

    if not isServer() then
        -- In test mode, return true to simulate success
        if SaucedCarts.Network._testMode then return true end
        SaucedCarts.debug("Network.broadcast: not server, ignoring")
        return false
    end
    sendServerCommand("SaucedCarts", command, args)
    SaucedCarts.debug(function() return "Network.broadcast: '" .. command .. "' fired to all clients" end)
    return true
end

-- =============================================================================
-- HANDLER REGISTRATION
-- =============================================================================
-- Modules register their handlers here. The dispatcher calls them with pcall.

local serverHandlers = {}  -- command -> function(player, args)
local clientHandlers = {}  -- command -> function(args)

--- Register a handler for commands received BY THE SERVER (from clients)
---@param command string The command name to handle
---@param handler function(player: IsoPlayer, args: table) The handler function
function SaucedCarts.Network.registerServerHandler(command, handler)
    if serverHandlers[command] then
        SaucedCarts.debug(function() return "Network: overwriting server handler for " .. command end)
    end
    serverHandlers[command] = handler
    SaucedCarts.debug(function() return "Network: registered server handler for " .. command end)
end

--- Register a handler for commands received BY THE CLIENT (from server)
---@param command string The command name to handle
---@param handler function(args: table) The handler function
function SaucedCarts.Network.registerClientHandler(command, handler)
    if clientHandlers[command] then
        SaucedCarts.debug(function() return "Network: overwriting client handler for " .. command end)
    end
    clientHandlers[command] = handler
    SaucedCarts.debug(function() return "Network: registered client handler for " .. command end)
end

--- Get a server handler for direct testing
--- Use this to call server handlers directly without actual network
---@param command string The command name
---@return function|nil The handler function, or nil if not registered
function SaucedCarts.Network._getServerHandler(command)
    return serverHandlers[command]
end

--- Get a client handler for direct testing
--- Use this to call client handlers directly without actual network
---@param command string The command name
---@return function|nil The handler function, or nil if not registered
function SaucedCarts.Network._getClientHandler(command)
    return clientHandlers[command]
end

--- Invoke a server handler directly (for testing)
--- Simulates receiving a command from a client
---@param command string The command name
---@param player IsoPlayer The player making the request
---@param args table The command arguments
---@return boolean success, string|nil error
function SaucedCarts.Network._invokeServerHandler(command, player, args)
    local handler = serverHandlers[command]
    if not handler then
        return false, "No handler registered for: " .. tostring(command)
    end
    local success, err = pcall(handler, player, args)
    if not success then
        return false, err
    end
    return true, nil
end

--- Invoke a client handler directly (for testing)
--- Simulates receiving a command from the server
---@param command string The command name
---@param args table The command arguments
---@return boolean success, string|nil error
function SaucedCarts.Network._invokeClientHandler(command, args)
    local handler = clientHandlers[command]
    if not handler then
        return false, "No handler registered for: " .. tostring(command)
    end
    local success, err = pcall(handler, args)
    if not success then
        return false, err
    end
    return true, nil
end

-- =============================================================================
-- DISPATCHERS
-- =============================================================================
-- Central handlers that route to registered handlers with error protection.

--- Server-side dispatcher: handles OnClientCommand
local function onClientCommand(module, command, player, args)
    if module ~= "SaucedCarts" then return end
    SaucedCarts.debug(function()
        return "Network[server]: dispatcher received '" .. tostring(command) ..
            "' from " .. tostring(player and player.getUsername and player:getUsername() or "?") ..
            " (handler=" .. tostring(serverHandlers[command] ~= nil) .. ")"
    end)

    local handler = serverHandlers[command]
    if not handler then
        SaucedCarts.debug(function() return "Network: no server handler for " .. command end)
        return
    end

    local success, err = pcall(handler, player, args)
    if not success then
        SaucedCarts.error("Network: server handler error (" .. command .. "): " .. tostring(err))
    end
end

--- Client-side dispatcher: handles OnServerCommand
local function onServerCommand(module, command, args)
    if module ~= "SaucedCarts" then return end

    SaucedCarts.debug(function()
        return "Network[client]: dispatcher received '" .. tostring(command) ..
            "' (handler=" .. tostring(clientHandlers[command] ~= nil) .. ")"
    end)

    local handler = clientHandlers[command]
    if not handler then
        SaucedCarts.debug(function() return "Network: no client handler for " .. command end)
        return
    end

    local success, err = pcall(handler, args)
    if not success then
        SaucedCarts.error("Network: client handler error (" .. command .. "): " .. tostring(err))
    end
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================
-- Register dispatchers based on execution context.

-- Register BOTH dispatchers unconditionally. We used to gate these on
-- isServer() / isClient() returning true at module-load time, but that
-- breaks when PZ loads SaucedCarts in main-menu context (where both
-- return false) and Lua's require cache prevents Network.lua from
-- re-running when the user later enters MP. Result: client dispatcher
-- never installed → server-broadcast commands silently dropped → the
-- v2.1.5 MP-stink layer's CorpseCount deltas never landed on the
-- originator's client (moodle disappeared on cart-load).
--
-- Vanilla only fires OnServerCommand on connected clients and only
-- fires OnClientCommand on the server, so registering both dispatchers
-- everywhere is functionally equivalent to gating but immune to the
-- main-menu cold-start ordering issue.
if Events and Events.OnClientCommand and Events.OnClientCommand.Add then
    Events.OnClientCommand.Add(onClientCommand)
    SaucedCarts.debug("Network: server dispatcher registered (unconditional)")
end

if Events and Events.OnServerCommand and Events.OnServerCommand.Add then
    Events.OnServerCommand.Add(onServerCommand)
    SaucedCarts.debug("Network: client dispatcher registered (unconditional)")
end

-- =============================================================================
-- GROUND CART VISUAL SYNC HANDLER (Server-side)
-- =============================================================================
-- Client sends: syncGroundCartVisual {squareX, squareY, squareZ, cartId, fillState, modelName}
-- Server broadcasts: updateGroundCartVisual {squareX, squareY, squareZ, cartId, fillState, modelName}
--
-- IMPORTANT: Client pre-calculates fillState and modelName to avoid race conditions.
-- In Build 42 MP, the client runs ISInventoryTransferAction locally for prediction, so its
-- state is correct when the event fires. The server's state may lag behind due to network
-- latency, causing stale visual calculations. By using client-provided values, we get
-- correct visuals without timing issues.
--
-- This avoids transmitCompleteItemToClients() which causes duplication bugs.

if isServer() then
    SaucedCarts.Network.registerServerHandler("syncGroundCartVisual", function(player, args)
        -- Validate args
        if not args or not args.squareX or not args.cartId then
            SaucedCarts.debug(function() return "Network: syncGroundCartVisual - invalid args" end)
            return
        end

        -- Find the cart (validates it exists at the claimed location)
        local cart, worldObj = SaucedCarts.Network.findGroundCart(
            args.squareX, args.squareY, args.squareZ, args.cartId)

        if not cart then
            SaucedCarts.debug(function() return "Network: syncGroundCartVisual - cart not found at " ..
                args.squareX .. "," .. args.squareY .. "," .. args.squareZ end)
            return
        end

        -- Use client-provided values if available (avoids race condition with server state)
        -- Fall back to server calculation for backward compatibility with old clients
        local fillState = args.fillState or SaucedCarts.calculateFillState(cart)
        local modelName = args.modelName or SaucedCarts.buildCartModelName(cart, fillState)

        -- Broadcast lightweight update to ALL clients
        SaucedCarts.Network.broadcast("updateGroundCartVisual", {
            squareX = args.squareX,
            squareY = args.squareY,
            squareZ = args.squareZ,
            cartId = args.cartId,
            fillState = fillState,
            modelName = modelName,
        })

        SaucedCarts.debug(function() return "Network: broadcasted visual update for cart " .. args.cartId ..
            " (fillState: " .. fillState .. ", model: " .. modelName .. ")" end)
    end)
end

-- =============================================================================
-- CART ANIMATION SYNC (for MP)
-- =============================================================================
-- When a player equips/unequips a cart, their local client sets animation vars.
-- But remote clients derive WeaponType from the equipped item, which returns
-- UNARMED for carts (they're containers, not HandWeapons).
--
-- This sync ensures all clients see the correct "cart" animation.
--
-- Flow:
--   Client → Server: syncCartAnimation {playerOnlineId, hasCart}
--   Server → All:    updateCartAnimation {playerOnlineId, hasCart}
--   Client → Server: requestAnimationSync (late-joiner)
--   Server → Client: fullAnimationSync {states = [{id, hasCart}, ...]}
--
-- Server handlers are in: media/lua/server/SaucedCarts/AnimationSync.lua

-- Client handler for fullAnimationSync is in CartStateHandler.lua
-- (needs access to remoteCartPlayers tracking table for continuous re-application)

SaucedCarts.debug("Network module loaded")
