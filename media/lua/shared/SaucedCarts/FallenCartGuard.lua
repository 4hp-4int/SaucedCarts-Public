-- ============================================================================
-- SaucedCarts/FallenCartGuard.lua
-- ============================================================================
-- PURPOSE: Exempt a cart the ENGINE drops from world cleanup.
--
-- Java's IsoGameCharacter.dropHeavyItems treats any InventoryContainer as a
-- heavy item and puts it down with a bare AddWorldInventoryItem -- no
-- setIgnoreRemoveSandbox (IsoGameCharacter.java:14950). It runs on:
--   * player death (IsoPlayer.OnDeath -> dropHandItems)
--   * a fall heavier than a light one, a sprint-vault fall, a fence trip
--   * climbing through a window / frame, a sheet rope, over a wall
-- SaucedCarts blocks the contextual climbs while pushing, but death and falls
-- can't be blocked, and the right-click climb menu bypasses the contextual
-- block. A cart dropped any of these ways is unflagged, so on a server whose
-- cleanup config can match carts it is discarded at a later chunk load:
-- "I died / fell, came back for my cart, it was gone". Reproduced against the
-- real engine in EngineWorldCartTests (vanish_java_heavy_item_drop_*).
--
-- HOW: the Java drop fires the Lua event onItemFall(item) on the machine that
-- runs it (LuaEventManager.java:828).
--   * SP / host: the item is already in the world when the event fires
--     (AddWorldInventoryItem precedes the triggerEvent), so mark it now.
--   * MP client: the event fires BEFORE the client sends PlayerDropHeldItems,
--     and the server's drop (IsoGameCharacter.dropHeldItems) fires no Lua
--     event at all. So the client waits one tick -- the drop packet goes out
--     first on the same ordered connection -- then asks the server to mark
--     that cart; the server finds it beside the player and marks it, retrying
--     for a short while in case the drop lands late.
-- Touches only our own object -- never the admin's removal list -- so, like
-- the transfer-time flagging, it needs no opt-in.
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/Network"

local FallenCartGuard = {}

local SEARCH_RADIUS = 2       -- dropHeavyItems drops on the player's own square (or the floor below)
local RETRY_TICKS = 60        -- ~1 s of server ticks to find a late drop

--- Find a cart world item by id around the player, at the player's level and
--- the floors below (dropHeavyItems falls through to the first solid floor).
---@return InventoryItem|nil
function FallenCartGuard.findDroppedCart(player, cartId)
    local sq = player and player.getCurrentSquare and player:getCurrentSquare()
    if not sq or not getCell then return nil end
    local cell = getCell()
    for z = sq:getZ(), 0, -1 do
        for dx = -SEARCH_RADIUS, SEARCH_RADIUS do
            for dy = -SEARCH_RADIUS, SEARCH_RADIUS do
                local s = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, z)
                if s then
                    local objs = s:getWorldObjects()
                    for i = 0, objs:size() - 1 do
                        local it = objs:get(i):getItem()
                        if it and it:getID() == cartId then return it end
                    end
                end
            end
        end
    end
    return nil
end

--- Engine event handler: a heavy item just fell out of someone's hands.
function FallenCartGuard.onItemFall(item)
    if not item or not SaucedCarts.safeIsCart(item) then return end
    if isClient() then
        -- MP client: the server holds the authoritative world item. Wait a
        -- tick so our request trails the engine's own drop packet.
        local player = getPlayer and getPlayer()
        if not player then return end
        local cartId, waited = item:getID(), 0
        local onTick
        onTick = function()
            waited = waited + 1
            if waited < 2 then return end
            Events.OnTick.Remove(onTick)
            SaucedCarts.Network.sendToServer(player, "markFallenCart", { cartId = cartId })
        end
        Events.OnTick.Add(onTick)
        return
    end
    if SaucedCarts.markDropPersistent(item) then
        SaucedCarts.log(function() return "FallenCartGuard: exempted cart " .. tostring(item:getID()) ..
            " dropped by the engine (death / fall / climb)" end)
    end
end

-- Server: mark the cart a client reports as fallen. Retries briefly, because
-- the drop can land after the request.
local pending = {}

local function tryMark(entry)
    local cart = FallenCartGuard.findDroppedCart(entry.player, entry.cartId)
    if cart and SaucedCarts.markDropPersistent(cart) then
        SaucedCarts.log(function() return "FallenCartGuard: exempted fallen cart " .. tostring(entry.cartId) end)
        return true
    end
    return false
end

function FallenCartGuard.handleMarkFallenCart(player, args)
    if not player or not args or type(args.cartId) ~= "number" then return false end
    local entry = { player = player, cartId = args.cartId, ticks = 0 }
    if tryMark(entry) then return true end
    pending[#pending + 1] = entry
    return false
end

function FallenCartGuard._retryTick()
    for i = #pending, 1, -1 do
        local e = pending[i]
        e.ticks = e.ticks + 1
        if tryMark(e) or e.ticks >= RETRY_TICKS then table.remove(pending, i) end
    end
end

function FallenCartGuard._pendingCount() return #pending end

if Events and Events.onItemFall then
    Events.onItemFall.Add(FallenCartGuard.onItemFall)
end
if SaucedCarts.Network and SaucedCarts.Network.registerServerHandler then
    SaucedCarts.Network.registerServerHandler("markFallenCart", FallenCartGuard.handleMarkFallenCart)
end
if isServer() and Events and Events.OnTick then
    Events.OnTick.Add(FallenCartGuard._retryTick)
end

SaucedCarts.FallenCartGuard = FallenCartGuard
return FallenCartGuard
