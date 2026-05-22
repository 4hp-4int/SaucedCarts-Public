-- ============================================================================
-- SaucedCarts/Sync.lua
-- ============================================================================
-- PURPOSE: Generic per-attribute sync framework for cart (or other entity)
--          state across client/server boundaries. Replaces the per-feature
--          ad-hoc network handler + server registry + late-joiner replay
--          patterns we kept rewriting (cart visual, ghost cleanup, stink,
--          eventually flashlight, equip, etc.).
--
-- USAGE:
--   SaucedCarts.Sync.register({
--       name           = "stink",                       -- network cmd base
--       keyOf          = function(entity) return tostring(entity:getID()) end,
--       compute        = function(entity, ctx)          -- live → desired value
--           return { tile = ..., count = ... }          -- nil = unregister
--       end,
--       applyDelta     = function(key, prevValue, newValue)
--           -- single mutation point — emit deltas to vanilla / Lua state
--       end,
--       validate       = function(player, key, value)   -- optional, server-side
--           return true
--       end,
--       replayOnConnect = true,                          -- default true
--   })
--
--   -- At every state-change site:
--   SaucedCarts.Sync.publish("stink", cart, { player = player })
--
-- ROUTING:
--   * SP        → applyDelta locally; no network
--   * MP-server → server-state mirror update + applyDelta locally + broadcast
--                 (broadcast triggers each client's applyDelta on receipt)
--   * MP-client → sendToServer (server validates + broadcasts; round-trip is
--                 the only mutation path → preserves single-mutation invariant)
--
-- LATE-JOINER:
--   On Events.OnConnected, client requests replay for every registered
--   attribute. Server iterates its mirror and fires sendToClient (targeted)
--   for each known entry. Cheap, bounded by entity count.
--
-- CONTEXT: SHARED. Network handlers register on both client + server VMs;
--          the Network module's role guards (isClient/isServer) gate which
--          handler actually fires.
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/Network"

---@class SaucedCartsSync
local Sync = {}

-- spec table by name. Spec fields documented at the top.
local registrations = {}

-- Per-attribute, per-key client-side state (last applied value). Diff against
-- this drives applyDelta. Persists across the VM's lifetime.
local clientState = {}

-- Server-side authoritative mirror; consulted for late-joiner replay. Wiped
-- on dedi restart (rebuild via OnServerStarted is a Phase B concern).
local serverState = {}

local function valueIsEmpty(v)
    if v == nil then return true end
    -- Convention: a "stink" value where tile=nil OR count=0 means "unregister".
    -- Specs whose values don't have this shape can return nil from compute()
    -- to unregister explicitly.
    if type(v) == "table" then
        if v.tile == nil then return true end
        if v.count ~= nil and v.count <= 0 then return true end
    end
    return false
end

local function changedCmd(name) return name .. "Changed" end
local function applyCmd(name)   return name .. "Apply"   end
local function requestCmd(name) return "request_" .. name .. "_sync" end

--- Register a sync attribute. Idempotent — re-registering with the same name
--- replaces the prior spec but keeps existing state.
---@param spec table see file header
function Sync.register(spec)
    assert(spec and spec.name and type(spec.name) == "string",
        "Sync.register: spec.name (string) required")
    assert(type(spec.keyOf)   == "function", "Sync.register: spec.keyOf required")
    assert(type(spec.compute) == "function", "Sync.register: spec.compute required")
    assert(type(spec.applyDelta) == "function", "Sync.register: spec.applyDelta required")

    local name = spec.name
    registrations[name] = spec
    clientState[name] = clientState[name] or {}
    serverState[name] = serverState[name] or {}

    -- Server: receive client-proposed change, validate, apply locally, relay.
    if SaucedCarts.Network and SaucedCarts.Network.registerServerHandler then
        SaucedCarts.Network.registerServerHandler(changedCmd(name), function(player, args)
            if not args or args.key == nil then return end
            if spec.validate and not spec.validate(player, args.key, args.value) then
                SaucedCarts.log(function()
                    return "Sync(" .. name .. "): rejected proposal from " ..
                        tostring(player and player.getUsername and player:getUsername() or "?") ..
                        " key=" .. tostring(args.key)
                end)
                return
            end
            -- Server registry mirror.
            if valueIsEmpty(args.value) then
                serverState[name][args.key] = nil
            else
                serverState[name][args.key] = args.value
            end
            -- Apply locally + broadcast to clients (incl. originator).
            Sync._applyOnVm(name, args.key, args.value)
            if SaucedCarts.Network.broadcast then
                SaucedCarts.Network.broadcast(applyCmd(name), {
                    key = args.key, value = args.value,
                })
            end
        end)

        -- Late-joiner replay request handler.
        if spec.replayOnConnect ~= false then
            SaucedCarts.Network.registerServerHandler(requestCmd(name), function(player, _args)
                if not player or not SaucedCarts.Network.sendToClient then return end
                local n = 0
                for key, value in pairs(serverState[name]) do
                    if value ~= nil then
                        SaucedCarts.Network.sendToClient(player, applyCmd(name), {
                            key = key, value = value,
                        })
                        n = n + 1
                    end
                end
                SaucedCarts.log(function()
                    return "Sync(" .. name .. "): replayed " .. n ..
                        " entries to " .. tostring(player.getUsername and player:getUsername() or "?")
                end)
            end)
        end
    end

    -- Client: server-broadcast handler → run applyDelta against local state.
    if SaucedCarts.Network and SaucedCarts.Network.registerClientHandler then
        SaucedCarts.Network.registerClientHandler(applyCmd(name), function(args)
            SaucedCarts.log(function()
                return "Sync[client]: received '" .. applyCmd(name) ..
                    "' key=" .. tostring(args and args.key) ..
                    " hasValue=" .. tostring(args and args.value ~= nil)
            end)
            if not args or args.key == nil then return end
            Sync._applyOnVm(name, args.key, args.value)
        end)
    end

    SaucedCarts.debug(function() return "Sync: registered '" .. name .. "'" end)
end

--- Compute current value for an entity and route per VM context.
---@param name string registered attribute name
---@param entity any
---@param ctx table|nil passed through to compute()
function Sync.publish(name, entity, ctx)
    local spec = registrations[name]
    if not spec then
        SaucedCarts.debug(function() return "Sync.publish: no registration for '" .. name .. "'" end)
        return
    end
    if not entity then return end

    ctx = ctx or {}
    local key   = spec.keyOf(entity)
    if key == nil then return end
    local value = spec.compute(entity, ctx)

    SaucedCarts.log(function()
        return string.format("Sync.publish: name=%s key=%s [vmRole=%s]",
            name, tostring(key),
            isServer() and "server" or (isClient() and "client" or "sp"))
    end)

    -- SP: no network. Apply locally.
    if not isClient() and not isServer() then
        Sync._applyOnVm(name, key, value)
        return
    end

    -- MP-server (or self-hosted host where both flags are true): authoritative.
    if isServer() then
        if valueIsEmpty(value) then
            serverState[name][key] = nil
        else
            serverState[name][key] = value
        end
        Sync._applyOnVm(name, key, value)
        if SaucedCarts.Network and SaucedCarts.Network.broadcast then
            SaucedCarts.Network.broadcast(applyCmd(name), { key = key, value = value })
        end
        return
    end

    -- MP-client: propose to server. Round-trip is the sole apply path.
    local p = ctx.player
    if isClient() and p and SaucedCarts.Network and SaucedCarts.Network.sendToServer then
        SaucedCarts.Network.sendToServer(p, changedCmd(name), { key = key, value = value })
    end
end

--- Apply a (name, key, value) update against this VM's local state. Single
--- mutation point — runs spec.applyDelta with the prior value so the spec
--- can compute incremental deltas. Idempotent: identical re-application
--- produces zero delta if applyDelta is correctly written.
function Sync._applyOnVm(name, key, value)
    local spec = registrations[name]
    if not spec then
        SaucedCarts.log(function() return "Sync._applyOnVm: NO SPEC for '" .. name .. "'" end)
        return
    end
    local prev = clientState[name][key]
    SaucedCarts.log(function()
        return "Sync._applyOnVm: name=" .. name .. " key=" .. tostring(key) ..
            " prevHas=" .. tostring(prev ~= nil) ..
            " newHas=" .. tostring(value ~= nil) ..
            " [vmRole=" .. (isServer() and "server" or (isClient() and "client" or "sp")) .. "]"
    end)
    local ok, err = pcall(spec.applyDelta, key, prev, value)
    if not ok then
        SaucedCarts.error("Sync(" .. name .. "):applyDelta threw: " .. tostring(err))
    end
    if valueIsEmpty(value) then
        clientState[name][key] = nil
    else
        clientState[name][key] = value
    end
end

--- OnConnected: client asks server to replay every registered attribute's
--- known state. Idempotent if the client somehow already had values
--- (applyDelta should produce zero delta).
if not isServer() and Events and Events.OnConnected and Events.OnConnected.Add then
    Events.OnConnected.Add(function()
        if not isClient() then return end
        local p = getPlayer and getPlayer()
        if not p or not (SaucedCarts.Network and SaucedCarts.Network.sendToServer) then return end
        for name, spec in pairs(registrations) do
            if spec.replayOnConnect ~= false then
                SaucedCarts.Network.sendToServer(p, requestCmd(name), {})
                SaucedCarts.log(function()
                    return "Sync(" .. name .. "): requested replay on connect"
                end)
            end
        end
    end)
end

-- Test hooks + introspection (used by probes and offline tests).
Sync._registrations = registrations
Sync._clientState   = clientState
Sync._serverState   = serverState
Sync._valueIsEmpty  = valueIsEmpty

SaucedCarts.Sync = Sync

SaucedCarts.debug("Sync module loaded")

return Sync
