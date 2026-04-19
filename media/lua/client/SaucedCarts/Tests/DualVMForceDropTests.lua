--[[
    SaucedCarts — Dual-VM cart-dupe reproduction
    =============================================

    Companion to OfflineForceDropDupeTests.lua. That file proved the raw
    mechanism — vanilla forceDropHeavyItems dupes when the hand reference
    is stale. This file exercises the full MP command flow through
    PZTestKit.Sim so we can observe WHICH code paths actually leave the
    hand ref stale in a realistic client/server topology.

    Sim topology: 1 server + 1 wielder client. Each endpoint runs its own
    forceDropHeavyItems, its own ISEnterVehicle:start() port, its own
    cart-in-hand state, connected only through the sim's command bus
    (sendServerCommand / sendClientCommand / OnClientCommand / OnServerCommand
    match real PZ semantics).

    Test matrix:
      1. Baseline: clean MP dual-fire (server's own start() + client's
         onDropHeavyItem command arriving after) should NOT dupe — the
         first forceDropHeavyItems clears hands, the second sees nil.
      2. Preconditioned: cart already in world on server when the command
         arrives → the command's forceDropHeavyItems call dupes. This is
         the actual bug surface; documents the necessary precondition.
      3. With guard installed on the server: precondition #2 is neutralized.

    OFFLINE-ONLY: depends on PZTestKit.Sim (kit-only). Auto-skips in-game.
]]

if isServer() and not isClient() then return end

-- Offline-only: PZTestKit is the pz-test-kit harness, absent in real PZ.
-- When loaded in-game at startup, no-op cleanly — these tests are meant
-- to run under `pztest`, not via PZ's auto-loader.
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local HAS_SIM = _pz_module_sources ~= nil and PZTestKit and PZTestKit.Sim ~= nil

local tests = {}

-- ============================================================================
-- ENV BUILDER — shared across endpoints
-- ============================================================================
-- The sim's endpoints each need their own faithful vanilla surface:
--   - A mock square that records AddWorldInventoryItem calls so we can
--     count world objects afterwards.
--   - A mock inventory + character + cart with matching IDs on every
--     endpoint (so ID-based lookups agree across the bus).
--   - A reimplementation of vanilla forceDropHeavyItems matching
--     ISEquipWeaponAction.lua:75–99.
--   - Commands.player.onDropHeavyItem mirroring server/ClientCommands.lua:613
--     so the server's OnClientCommand handler calls forceDropHeavyItems on
--     incoming drop commands (the routing PZ does under the hood).

local ENDPOINT_SETUP = [[
    _pz_world_objects = {}  -- tracked world items on the shared test square

    if not sendRemoveItemFromContainer then
        function sendRemoveItemFromContainer(container, item) end
    end
    if not sendAddItemToContainer then
        function sendAddItemToContainer(container, item) end
    end

    local function makeSquare()
        local sq = { _type = "IsoGridSquare", _worldObjects = _pz_world_objects }
        sq.getWorldObjects = function(self)
            local list = self._worldObjects
            return {
                size = function() return #list end,
                get = function(_, i) return list[i + 1] end,
            }
        end
        sq.AddWorldInventoryItem = function(self, item, x, y, z, transmit)
            local wo = {
                _type = "IsoWorldInventoryObject",
                _item = item,
                getItem = function(me) return me._item end,
            }
            table.insert(self._worldObjects, wo)
            if item and item.setWorldItem then item:setWorldItem(wo) end
            -- Vanilla's 4-arg overload bytecode delegates to the 5-arg with
            -- transmit=true. Mirror that so the server-side add propagates
            -- to observer clients on flush, matching real PZ behaviour.
            if _pz_is_server and (transmit == nil or transmit == true) then
                sendServerCommand("__sim_world", "add", {
                    itemId = item and item.getID and item:getID() or 0,
                })
            end
            return item
        end
        sq.getX = function(self) return 0 end
        sq.getY = function(self) return 0 end
        sq.getZ = function(self) return 0 end
        return sq
    end

    local function makeInventory()
        local inv = { _items = {} }
        inv.AddItem = function(self, item) table.insert(self._items, item); return item end
        inv.Remove = function(self, item)
            for i, it in ipairs(self._items) do
                if it == item then table.remove(self._items, i); return end
            end
        end
        inv.contains = function(self, item)
            for _, it in ipairs(self._items) do if it == item then return true end end
            return false
        end
        return inv
    end

    local function makeCart(id)
        local c = { _type = "InventoryContainer", _id = id, _worldItem = nil, _isForceDrop = true }
        c.getID = function(self) return self._id end
        c.getFullType = function(self) return "SaucedCarts.ShoppingCart" end
        c.isForceDropHeavyItem = function(self) return self._isForceDrop end
        c.getWorldItem = function(self) return self._worldItem end
        c.setWorldItem = function(self, w) self._worldItem = w end
        c.hasTag = function(self, tag) return tag == "HEAVY_ITEM" end
        return c
    end

    local function makeCharacter(sq, inv)
        local ch = { _type = "IsoPlayer", _primary = nil, _secondary = nil, _sq = sq, _inv = inv }
        ch.getCurrentSquare = function(self) return self._sq end
        ch.getInventory = function(self) return self._inv end
        ch.getPrimaryHandItem = function(self) return self._primary end
        ch.getSecondaryHandItem = function(self) return self._secondary end
        ch.setPrimaryHandItem = function(self, i) self._primary = i end
        ch.setSecondaryHandItem = function(self, i) self._secondary = i end
        ch.isPrimaryHandItem = function(self, i) return i ~= nil and self._primary == i end
        ch.isSecondaryHandItem = function(self, i) return i ~= nil and self._secondary == i end
        ch.removeFromHands = function(self, item)
            if self:isPrimaryHandItem(item) then self:setPrimaryHandItem(nil) end
            if self:isSecondaryHandItem(item) then self:setSecondaryHandItem(nil) end
            return true
        end
        ch.getOnlineID = function(self) return 12345 end
        return ch
    end

    _pz_sq = makeSquare()
    _pz_inv = makeInventory()
    _pz_cart = makeCart(777777)  -- shared cart ID across endpoints
    _pz_char = makeCharacter(_pz_sq, _pz_inv)

    -- Vanilla forceDropHeavyItems faithful reimplementation
    function forceDropHeavyItems(character)
        if not character or not character:getCurrentSquare() then return end
        local primary = character:getPrimaryHandItem()
        if primary and primary.isForceDropHeavyItem and primary:isForceDropHeavyItem() then
            character:getInventory():Remove(primary)
            sendRemoveItemFromContainer(character:getInventory(), primary)
            character:getCurrentSquare():AddWorldInventoryItem(primary, 0.5, 0.5, 0)
            character:removeFromHands(primary)
        end
        local secondary = character:getSecondaryHandItem()
        if secondary and secondary.isForceDropHeavyItem and secondary:isForceDropHeavyItem() then
            character:getInventory():Remove(secondary)
            sendRemoveItemFromContainer(character:getInventory(), secondary)
            character:getCurrentSquare():AddWorldInventoryItem(secondary, 0.5, 0.5, 0)
            character:setSecondaryHandItem(nil)
        end
    end

    -- Server-side command handler mirroring Commands.player.onDropHeavyItem
    -- in PZ's server/ClientCommands.lua:613. Fires on OnClientCommand.
    if _pz_is_server then
        Events.OnClientCommand.Add(function(module, command, player, args)
            if module == "player" and command == "onDropHeavyItem" then
                forceDropHeavyItems(_pz_char)
            end
        end)
    end

    -- Client-side: listen for __sim_world add broadcasts and track observed
    -- world additions. Mirrors how real PZ transmits world-item adds to
    -- clients within the cell radius.
    if not _pz_is_server then
        _pz_observed_world_adds = 0
        Events.OnServerCommand.Add(function(module, command, args)
            if module == "__sim_world" and command == "add" then
                _pz_observed_world_adds = _pz_observed_world_adds + 1
            end
        end)
    end

    -- Port of ISEnterVehicle:start()'s heavy-item block. Runs in both
    -- endpoints, branches on isClient() like vanilla does.
    function runEnterVehicleStart()
        local primary = _pz_char:getPrimaryHandItem()
        local secondary = _pz_char:getSecondaryHandItem()
        local hasHeavy = (primary and primary.hasTag and primary:hasTag("HEAVY_ITEM"))
            or (secondary and secondary.hasTag and secondary:hasTag("HEAVY_ITEM"))
        if not hasHeavy then return end
        if isClient() then
            sendClientCommand(_pz_char, "player", "onDropHeavyItem", { id = _pz_char:getOnlineID() })
        else
            forceDropHeavyItems(_pz_char)
        end
    end
]]

-- Flag set so the endpoint knows whether it's server or client during setup.
local function setupSim(sim)
    sim.server:exec("_pz_is_server = true\n" .. ENDPOINT_SETUP)
    for _, client in ipairs(sim.clients) do
        client:exec("_pz_is_server = false\n" .. ENDPOINT_SETUP)
    end
end

-- ============================================================================
-- TESTS
-- ============================================================================

local function dualVM(name, fn)
    tests[name] = function()
        if not HAS_SIM then return true end  -- skip in-game / no sim
        return fn()
    end
end

-- Baseline: clean MP flow. Server's timed-action start() fires FIRST,
-- then the client's onDropHeavyItem command arrives. After server's
-- forceDropHeavyItems call, hands are cleared, so the command handler
-- is a no-op. Expected: 1 world object on server. (Observes that the
-- natural dual-fire path does not, on its own, cause the dupe.)
dualVM("sim_mp_dual_fire_clean_state_no_dupe", function()
    local sim = PZTestKit.Sim.new({ players = 1 })
    setupSim(sim)

    -- Put cart in inventory + both hands on both endpoints
    sim.server:exec([[
        _pz_inv:AddItem(_pz_cart)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])
    sim.clients[1]:exec([[
        _pz_inv:AddItem(_pz_cart)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])

    -- Server's ISEnterVehicle start() runs first (timed-action-synced)
    sim.server:exec("runEnterVehicleStart()")
    -- Client's ISEnterVehicle start() runs, sends command
    sim.clients[1]:exec("runEnterVehicleStart()")
    -- Flush: server receives onDropHeavyItem and runs its handler
    sim:flush()

    local worldCount = sim.server:eval("return #_pz_world_objects")
    return Assert.equal(worldCount, 1,
        "clean dual-fire: exactly 1 world object (got " .. tostring(worldCount) .. ")")
end)

-- Preconditioned: client fires FIRST (command reaches server before the
-- server's own timed-action start() runs). Server handles the command,
-- drops the cart — hands cleared. Server's own start() then sees nil
-- primary, no-op. Expected: 1 world object.
--
-- This exercises the OTHER order. If either order dupes naturally, the
-- test exposes it.
dualVM("sim_mp_client_command_first_no_dupe", function()
    local sim = PZTestKit.Sim.new({ players = 1 })
    setupSim(sim)

    sim.server:exec([[
        _pz_inv:AddItem(_pz_cart)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])
    sim.clients[1]:exec([[
        _pz_inv:AddItem(_pz_cart)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])

    -- Client sends first
    sim.clients[1]:exec("runEnterVehicleStart()")
    -- Flush routes command → server handler runs forceDropHeavyItems
    sim:flush()
    -- Server's own timed-action start() runs AFTER — hands should be nil now
    sim.server:exec("runEnterVehicleStart()")

    local worldCount = sim.server:eval("return #_pz_world_objects")
    return Assert.equal(worldCount, 1,
        "command-first dual-fire: exactly 1 world object (got " .. tostring(worldCount) .. ")")
end)

-- Reproduction: server is in the "stale hand ref" state when the client
-- command arrives. Cart is already on the ground on the server (worldItem
-- set) but the server's hands still reference it — exactly the artificial
-- state our unit test reproduces. Expected WITHOUT guard: 2 world objects
-- (dupe). With guard: 1.
dualVM("sim_mp_stale_hand_ref_reproduces_dupe", function()
    local sim = PZTestKit.Sim.new({ players = 1 })
    setupSim(sim)

    -- Server: cart is already on the ground and hand ref is stale.
    sim.server:exec([[
        _pz_sq:AddWorldInventoryItem(_pz_cart, 0.5, 0.5, 0)  -- cart already in world
        -- Inventory is empty. Hands still point to the cart.
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])
    -- Client view: cart in inventory + hands (hasn't received server's drop yet).
    sim.clients[1]:exec([[
        _pz_inv:AddItem(_pz_cart)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])

    sim.clients[1]:exec("runEnterVehicleStart()")
    sim:flush()

    local worldCount = sim.server:eval("return #_pz_world_objects")
    -- Vanilla dupes: world had 1 object from the artificial precondition,
    -- and the command-triggered forceDropHeavyItems adds a second.
    return Assert.equal(worldCount, 2,
        "stale-ref MP dupe: 2 world objects (got " .. tostring(worldCount) .. ")")
end)

-- Same as above but the server installs the guard before the command
-- arrives. With the guard, the incoming forceDropHeavyItems call detects
-- the stale hand ref (cart in world) and clears the hand instead of
-- re-dropping. Expected: 1 world object.
dualVM("sim_mp_guard_prevents_stale_ref_dupe", function()
    local sim = PZTestKit.Sim.new({ players = 1 })
    setupSim(sim)

    sim.server:exec([[
        _pz_sq:AddWorldInventoryItem(_pz_cart, 0.5, 0.5, 0)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)

        -- Install the guard. Uses a pure-Lua isCart check (the real
        -- SaucedCarts.isCart requires userdata items which the sim mocks).
        local function isCartTest(item)
            return type(item) == "table" and item._type == "InventoryContainer"
                and item._isForceDrop == true
        end
        local originalFn = forceDropHeavyItems
        forceDropHeavyItems = function(character)
            if not character or not character:getCurrentSquare() then
                return originalFn(character)
            end
            pcall(function()
                local p = character:getPrimaryHandItem()
                if p and isCartTest(p) then
                    if p.getWorldItem and p:getWorldItem() then
                        character:removeFromHands(p); return
                    end
                    local inv = character:getInventory()
                    if inv and inv.contains and not inv:contains(p) then
                        character:removeFromHands(p); return
                    end
                end
                local s = character:getSecondaryHandItem()
                if s and isCartTest(s) then
                    if s.getWorldItem and s:getWorldItem() then
                        character:setSecondaryHandItem(nil); return
                    end
                    local inv = character:getInventory()
                    if inv and inv.contains and not inv:contains(s) then
                        character:setSecondaryHandItem(nil); return
                    end
                end
            end)
            return originalFn(character)
        end
    ]])

    sim.clients[1]:exec([[
        _pz_inv:AddItem(_pz_cart)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])

    sim.clients[1]:exec("runEnterVehicleStart()")
    sim:flush()

    local worldCount = sim.server:eval("return #_pz_world_objects")
    return Assert.equal(worldCount, 1,
        "guard neutralizes stale-ref dupe: 1 world object (got " .. tostring(worldCount) .. ")")
end)

-- Observer visibility: with 2 clients (wielder + observer), the dupe
-- produced on the server is broadcast to BOTH clients via the world-item
-- transmit. Observer should see TWO world adds without the guard —
-- confirming the dupe is a real MP exploit visible to other players, not
-- just a server-side artefact.
dualVM("sim_observer_sees_dupe_without_guard", function()
    local sim = PZTestKit.Sim.new({ players = 2 })
    setupSim(sim)

    sim.server:exec([[
        _pz_sq:AddWorldInventoryItem(_pz_cart, 0.5, 0.5, 0)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])
    sim.clients[1]:exec([[
        _pz_inv:AddItem(_pz_cart)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])
    -- Observer (client 2): no cart, just watching.
    sim.clients[1]:exec("runEnterVehicleStart()")
    sim:flush()  -- routes client's onDropHeavyItem → server
    sim:flush()  -- routes server's cascade __sim_world broadcasts → clients

    local observerSawAdds = sim.clients[2]:eval("return _pz_observed_world_adds")
    -- Observer should see 2 world-add transmits: one from the precondition
    -- setup and one from the command-triggered duplicate drop.
    return Assert.equal(observerSawAdds, 2,
        "observer sees 2 world-item adds (dupe visible to other players): got "
        .. tostring(observerSawAdds))
end)

-- With the guard installed, the command's forceDropHeavyItems early-exits
-- before touching the square. Observer sees only the precondition add —
-- no dupe transmitted.
dualVM("sim_observer_sees_no_dupe_with_guard", function()
    local sim = PZTestKit.Sim.new({ players = 2 })
    setupSim(sim)

    sim.server:exec([[
        _pz_sq:AddWorldInventoryItem(_pz_cart, 0.5, 0.5, 0)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)

        local function isCartTest(item)
            return type(item) == "table" and item._type == "InventoryContainer"
                and item._isForceDrop == true
        end
        local originalFn = forceDropHeavyItems
        forceDropHeavyItems = function(character)
            if not character or not character:getCurrentSquare() then
                return originalFn(character)
            end
            pcall(function()
                local p = character:getPrimaryHandItem()
                if p and isCartTest(p) then
                    if p.getWorldItem and p:getWorldItem() then
                        character:removeFromHands(p); return
                    end
                    local inv = character:getInventory()
                    if inv and inv.contains and not inv:contains(p) then
                        character:removeFromHands(p); return
                    end
                end
                local s = character:getSecondaryHandItem()
                if s and isCartTest(s) then
                    if s.getWorldItem and s:getWorldItem() then
                        character:setSecondaryHandItem(nil); return
                    end
                    local inv = character:getInventory()
                    if inv and inv.contains and not inv:contains(s) then
                        character:setSecondaryHandItem(nil); return
                    end
                end
            end)
            return originalFn(character)
        end
    ]])
    sim.clients[1]:exec([[
        _pz_inv:AddItem(_pz_cart)
        _pz_char:setPrimaryHandItem(_pz_cart)
        _pz_char:setSecondaryHandItem(_pz_cart)
    ]])

    sim.clients[1]:exec("runEnterVehicleStart()")
    sim:flush()  -- routes client's onDropHeavyItem → server
    sim:flush()  -- routes server's cascade __sim_world broadcasts → clients

    local observerSawAdds = sim.clients[2]:eval("return _pz_observed_world_adds")
    return Assert.equal(observerSawAdds, 1,
        "observer sees exactly 1 world-item add (guard prevents dupe transmission): got "
        .. tostring(observerSawAdds))
end)

-- Self-register
PZTestKit.registerTests("dualvm_forcedrop_dupe", tests)
print("[SaucedCarts:offline] DualVMForceDropTests registered")

return tests
