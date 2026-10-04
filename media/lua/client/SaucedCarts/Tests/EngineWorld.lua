--[[
    EngineWorld -- shared real-world harness for the Engine*Tests files
    ===================================================================
    Not a test file (the runner only collects *Tests.lua). Requires engine
    mode; callers guard on PZEngine before requiring it.

    What "real" means here, and where it stops:
      * A real IsoPlayer standing on a real IsoGridSquare, registered in
        ServerMap so the engine's own getCell():getGridSquare finds it.
      * World mutations run with GameServer.server set -- the dedicated-
        server branch, which skips sprite/texture work (no renderer here)
        and routes square lookups through ServerMap. A server with nobody
        connected: broadcasts reach zero clients.
      * Lua-visible network sends (sendAddItemToContainer & co.) are
        recorded, not delivered.
      * opts.client makes mod Lua see an MP client (isClient true). The Java
        server flag stays set, so client-mode tests must stay off drawing
        paths.
      * opts.realClock swaps the Lua GameTime global for the engine's real
        GameTime, so Lua (corpse rot stamps) and Java (IsoDeadBody death
        times, updateBodies) age on ONE clock. W.setWorldHours moves it.
]]

local W = {}

-- Squares persist for the whole process and every Engine* file shares them
-- (each file has its own Lua env, so no counter can be trusted across files).
-- Bases sit on a 30-tile grid and a base is only taken when nothing is in
-- REACH of it -- tests place things up to 12 tiles out -- checked through the
-- engine's own lookup, which never creates squares.
local REACH = 13
local bases = {}
for gy = 20, 230, 30 do
    for gx = 20, 230, 30 do bases[#bases + 1] = { gx, gy } end
end
local nextBase = 1

local function reachIsEmpty(cx, cy)
    local prev = PZEngine.setServer(true)
    local cell = PZEngine.cell()
    local empty = true
    if cell then
        for dx = -REACH, REACH do
            for dy = -REACH, REACH do
                local sq = cell:getGridSquare(cx + dx, cy + dy, 0)
                if sq and (sq:getWorldObjects():size() > 0 or sq:getDeadBodys():size() > 0
                    or sq:getObjects():size() > 0) then
                    empty = false
                    break
                end
            end
            if not empty then break end
        end
    end
    PZEngine.setServer(prev)
    return empty
end

function W.freshGround()
    for _ = 1, #bases do
        local b = bases[nextBase]
        nextBase = nextBase % #bases + 1
        if reachIsEmpty(b[1], b[2]) then
            local sq, err = PZEngine.newSquare(b[1], b[2], 0)
            assert(sq, "newSquare: " .. tostring(err))
            return sq
        end
    end
    error("EngineWorld: no clean ground left (" .. #bases .. " bases all dirty)")
end

--- A real square relative to another (registered if new).
function W.groundAt(base, dx, dy)
    return assert(PZEngine.newSquare(base:getX() + dx, base:getY() + dy, 0))
end

local realGameTimeGlobal
--- Move the engine's world clock to `hours` (world age).
function W.setWorldHours(hours)
    local gt = PZEngine.gameTime()
    local nights = math.floor(hours / 24)
    gt:setNightsSurvived(nights)
    gt:setTimeOfDay(7 + (hours - nights * 24))
    return gt:getWorldAgeHours()
end

--- Run fn(world) as the server. world = { sq, player, sent, broadcasts }.
function W.inWorld(fn, opts)
    opts = opts or {}
    local sq = W.freshGround()
    local player = assert(PZEngine.newPlayer())
    player:setCurrent(sq)
    player:setX(sq:getX() + 0.5)
    player:setY(sq:getY() + 0.5)

    local sent, broadcasts = {}, {}
    local saved = {
        getCell = getCell, isServer = isServer, isClient = isClient,
        add = sendAddItemToContainer, remove = sendRemoveItemFromContainer,
        equip = sendEquip, corpse = sendCorpse, gameTime = GameTime,
        broadcast = SaucedCarts and SaucedCarts.Network and SaucedCarts.Network.broadcast,
        toClient = SaucedCarts and SaucedCarts.Network and SaucedCarts.Network.sendToClient,
    }
    local prevServer = PZEngine.setServer(true)
    getCell = PZEngine.cell
    isServer = function() return not opts.client end
    isClient = function() return opts.client == true end
    sendAddItemToContainer = function(c, it) sent[#sent + 1] = "add " .. it:getFullType() end
    sendRemoveItemFromContainer = function(c, it) sent[#sent + 1] = "remove " .. it:getFullType() end
    sendEquip = function() sent[#sent + 1] = "equip" end
    sendCorpse = function() sent[#sent + 1] = "corpse" end
    if opts.realClock then
        local real = PZEngine.gameTime()
        GameTime = { getInstance = function() return real end }
    end
    if SaucedCarts and SaucedCarts.Network then
        SaucedCarts.Network.broadcast = function(command, args)
            broadcasts[#broadcasts + 1] = { command = command, args = args }
        end
        SaucedCarts.Network.sendToClient = function(p, command, args)
            broadcasts[#broadcasts + 1] = { command = command, args = args, to = p }
        end
    end

    local ok, result = pcall(fn, { sq = sq, player = player, sent = sent, broadcasts = broadcasts })

    PZEngine.setServer(prevServer)
    getCell, isServer, isClient = saved.getCell, saved.isServer, saved.isClient
    sendAddItemToContainer, sendRemoveItemFromContainer = saved.add, saved.remove
    sendEquip, sendCorpse, GameTime = saved.equip, saved.corpse, saved.gameTime
    if SaucedCarts and SaucedCarts.Network then
        SaucedCarts.Network.broadcast, SaucedCarts.Network.sendToClient = saved.broadcast, saved.toClient
    end
    if not ok then error(result, 0) end
    return result
end

-- Vanilla's drop placement (ISTransferAction.GetDropItemOffset) reads one
-- player option off getCore(); the harness has no Core global. Default off,
-- which is the game's default too: items land at a random spot on the tile.
if not getCore then
    local core = { getOptionDropItemsOnSquareCenter = function() return false end }
    getCore = function() return core end
end

function W.cart(fullType)
    return assert(PZEngine.instanceItem(fullType or "SaucedCarts.ShoppingCart"))
end

function W.holdCart(player, c)
    player:getInventory():AddItem(c)
    player:setPrimaryHandItem(c)
    player:setSecondaryHandItem(c)
end

function W.dropOnGround(sq, item)
    sq:AddWorldInventoryItem(item, 0.5, 0.5, 0)
    return item
end

function W.sentCommand(world, name)
    for _, b in ipairs(world.broadcasts) do
        if b.command == name then return b end
    end
    return nil
end

return W
