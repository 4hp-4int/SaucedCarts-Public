--[[
    SaucedCarts — Client packet guard regressions
    =============================================

    Locks the 2026-08-07 anti-cheat kick fix. MP timed actions run on BOTH
    client and server VMs; on a client, sendRemoveItemFromContainer sends
    PacketType.SyncItemDelete, whose PacketSetting declares
    requiredCapability = Capability.EditItem (SyncItemDeletePacket.java:8) —
    an admin capability. The server rejects it (PacketTypes.java:293) and
    AntiCheatPermission kicks the player ("suspicious activity"). Reported
    live: every player installing a flashlight on a dedicated server was
    kicked at action completion.

    Contract enforced here: the consume-and-send blocks in our actions run
    ONLY where authoritative (server / SP). A client VM must never call
    sendRemoveItemFromContainer. The equip action's local container moves
    still happen on the client (the hand-equip needs the cart in playerInv
    immediately) — only the sends are server-side.

    The spy/restore pattern pcall-wraps the body and ALWAYS restores
    globals — a spy leaked on throw poisons whichever test runs next
    (Kahlua pairs order is arbitrary).
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"
require "SaucedCarts/TimedActions/ISInstallFlashlightAction"
require "SaucedCarts/TimedActions/ISCartEquipAction"

-- Vanilla ISBaseTimedAction:perform logs via ISLogSystem (absent offline).
ISLogSystem = ISLogSystem or { logAction = function() end }

local TEST_CART_TYPE = "SaucedCarts.TestPacketGuardCart"
if not SaucedCarts.isRegistered(TEST_CART_TYPE) then
    SaucedCarts.registerCart(TEST_CART_TYPE, {
        name = "TestPacketGuardCart",
        capacity = 50,
        conditionMax = 100,
    })
end

-- =============================================================================
-- MOCKS — explicit essentials + auto-noop for the long tail of PZ methods
-- =============================================================================

local function autoNoop(t)
    -- Synthesize no-op METHODS for the long tail of PZ calls, but leave
    -- data fields (underscore-prefixed by convention here) nil — a noop
    -- closure standing in for a data field is truthy and poisons guards.
    return setmetatable(t, { __index = function(_, k)
        if type(k) == "string" and k:sub(1, 1) == "_" then return nil end
        return function() end
    end })
end

local nextId = 20000
local function takeId() nextId = nextId + 1 return nextId end

local function makeContainer()
    local c = { _items = {} }
    c.getItems = function(self)
        local list = { _items = self._items }
        list.size = function(s) return #s._items end
        list.get = function(s, i) return s._items[i + 1] end
        return list
    end
    c.getItemById = function(self, id)
        for _, it in ipairs(self._items) do
            if it:getID() == id then return it end
        end
        return nil
    end
    c.contains = function(self, item)
        for _, it in ipairs(self._items) do if it == item then return true end end
        return false
    end
    c.AddItem = function(self, item)
        table.insert(self._items, item)
        item._container = self
        return item
    end
    c.Remove = function(self, item)
        for i, it in ipairs(self._items) do
            if it == item then table.remove(self._items, i) item._container = nil return end
        end
    end
    c.DoRemoveItem = c.Remove
    c.getCapacity = function() return 50 end
    c.getEffectiveCapacity = function() return 50 end
    c.getCapacityWeight = function() return 0 end
    c.getContentsWeight = function() return 0 end
    c.hasRoomFor = function() return true end
    return autoNoop(c)
end

local function makeItem(fullType, container)
    local it = {
        _id = takeId(),
        _fullType = fullType,
        _modData = {},
        _container = container,
    }
    it.getID = function(self) return self._id end
    it.getFullType = function(self) return self._fullType end
    it.getDisplayName = function(self) return self._fullType end
    it.getModData = function(self) return self._modData end
    it.getContainer = function(self) return self._container end
    it.getWorldItem = function(self) return nil end
    it.getStaticModel = function(self) return self._staticModel end
    it.getLightStrength = function(self) return 1.8 end
    it.getLightDistance = function(self) return 15 end
    it.isTorchCone = function(self) return true end
    it.getTorchDot = function(self) return 0.5 end
    it._uses = 0.8
    it.getCurrentUsesFloat = function(self) return self._uses end
    it.setCurrentUsesFloat = function(self, v) self._uses = v end
    it.getCondition = function(self) return 100 end
    it.getConditionMax = function(self) return 100 end
    it.getWeight = function(self) return 8 end
    it.getActualWeight = function(self) return 8 end
    it.getUnequippedWeight = function(self) return 8 end
    it._inner = makeContainer()
    it.getItemContainer = function(self) return self._inner end
    if container then container:AddItem(it) end
    return autoNoop(it)
end

local function makeCharacter(inv, primary)
    local ch = { _inv = inv, _primary = primary }
    ch.getInventory = function(self) return self._inv end
    ch.getPrimaryHandItem = function(self) return self._primary end
    ch.getSecondaryHandItem = function(self) return nil end
    ch.getOnlineID = function(self) return 1 end
    return autoNoop(ch)
end

-- =============================================================================
-- VM harness: stub isClient, spy the sends, silence events; always restore
-- =============================================================================

local function withVM(clientVM, fn)
    local counters = { remove = 0, add = 0 }
    local origIsClient = _G.isClient
    local origRemove = _G.sendRemoveItemFromContainer
    local origAdd = _G.sendAddItemToContainer
    local origFire = SaucedCarts._fireEvent
    local origIsCart = SaucedCarts.isCart
    local origSafeIsCart = SaucedCarts.safeIsCart
    -- Vanilla ISBaseTimedAction:perform ends in
    -- ISTimedActionQueue.getTimedActionQueue(character):onCompleted(self);
    -- mock characters have no queue — hand back a noop one.
    local origGetQueue = ISTimedActionQueue and ISTimedActionQueue.getTimedActionQueue
    if ISTimedActionQueue then
        ISTimedActionQueue.getTimedActionQueue = function()
            return { onCompleted = function() end }
        end
    end

    _G.isClient = function() return clientVM end
    _G.sendRemoveItemFromContainer = function() counters.remove = counters.remove + 1 end
    _G.sendAddItemToContainer = function() counters.add = counters.add + 1 end
    SaucedCarts._fireEvent = nil  -- skip MP event listeners (guarded call sites)
    SaucedCarts.isCart = function(item)
        if type(item) == "table" and item._fullType == TEST_CART_TYPE then return true end
        return origIsCart(item)
    end
    SaucedCarts.safeIsCart = SaucedCarts.isCart

    local ok, err = pcall(fn, counters)

    _G.isClient = origIsClient
    _G.sendRemoveItemFromContainer = origRemove
    _G.sendAddItemToContainer = origAdd
    SaucedCarts._fireEvent = origFire
    SaucedCarts.isCart = origIsCart
    SaucedCarts.safeIsCart = origSafeIsCart
    if ISTimedActionQueue then
        ISTimedActionQueue.getTimedActionQueue = origGetQueue
    end

    if not ok then error(err) end
    return counters
end

local function buildInstallScenario()
    local inv = makeContainer()
    local cart = makeItem(TEST_CART_TYPE, nil)
    local flashlight = makeItem("Base.Torch", inv)
    local tape = makeItem("Base.DuctTape", inv)
    tape.getCurrentUses = function(self) return 4 end
    local ch = makeCharacter(inv, cart)
    local action = ISInstallFlashlightAction:new(
        ch, cart:getID(), flashlight:getID(), "Base.Torch", "Base.DuctTape", 1)
    return action, inv, cart, flashlight, ch
end

-- =============================================================================
-- TESTS
-- =============================================================================

local tests = {}

tests["install_client_vm_never_sends_remove"] = function()
    -- The reported kick: a client VM running :complete() (it runs on BOTH
    -- sides under replication) must send no SyncItemDelete-class packet and
    -- must not consume authoritatively -- only mirror ModData locally.
    local action, inv, cart, flashlight = buildInstallScenario()
    local counters = withVM(true, function()
        action:complete()
        action:perform()  -- presentation-only; must also send nothing
    end)
    if not Assert.equal(counters.remove, 0,
        "client VM must NEVER call sendRemoveItemFromContainer "
        .. "(SyncItemDelete requires Capability.EditItem -> anti-cheat kick)") then
        return false
    end
    return Assert.isTrue(inv:contains(flashlight),
        "client defers consumption to the server's copy of the action")
end

tests["install_server_vm_consumes_and_sends"] = function()
    -- Sensitivity twin: the authoritative VM still consumes and broadcasts.
    local action, inv, cart, flashlight = buildInstallScenario()
    local ok
    local counters = withVM(false, function()
        ok = action:complete()
    end)
    if not Assert.isTrue(ok == true,
        "complete() returns true on success (NetTimedAction contract)") then
        return false
    end
    if not Assert.isTrue(counters.remove >= 1,
        "server/SP VM broadcasts the removal") then return false end
    if not Assert.isFalse(inv:contains(flashlight),
        "server/SP VM consumed the flashlight") then return false end
    return Assert.equal(cart:getModData().SaucedCarts_hasFlashlight, true,
        "install landed in ModData")
end

tests["equip_client_vm_moves_locally_without_sends"] = function()
    -- The equip transfer branch: local container moves MUST still happen on
    -- the client (hand-equip needs the cart in playerInv immediately), but
    -- neither send may fire there.
    local playerInv = makeContainer()
    local bag = makeContainer()
    local cart = makeItem(TEST_CART_TYPE, bag)
    local ch = makeCharacter(playerInv, nil)
    local action = ISCartEquipAction:new(ch, cart:getID())
    action.findCart = function() return cart end
    local counters = withVM(true, function()
        action:complete()
    end)
    if not Assert.equal(counters.remove, 0,
        "client VM must not send remove") then return false end
    if not Assert.equal(counters.add, 0,
        "client VM must not send add") then return false end
    if not Assert.isTrue(playerInv:contains(cart),
        "local move into playerInv still happened on the client") then
        return false
    end
    return Assert.isFalse(bag:contains(cart), "cart left the source container")
end

tests["equip_server_vm_sends_both"] = function()
    local playerInv = makeContainer()
    local bag = makeContainer()
    local cart = makeItem(TEST_CART_TYPE, bag)
    local ch = makeCharacter(playerInv, nil)
    local action = ISCartEquipAction:new(ch, cart:getID())
    action.findCart = function() return cart end
    local counters = withVM(false, function()
        action:complete()
    end)
    if not Assert.isTrue(counters.remove >= 1, "server broadcasts remove") then
        return false
    end
    return Assert.isTrue(counters.add >= 1, "server broadcasts add")
end

tests["install_broadcast_carries_install_payload"] = function()
    -- Ground carts never receive syncItemModData, so the upgradeInstalled
    -- broadcast must carry the install state for clients to mirror. A
    -- payload-less broadcast reproduces the "eats the flashlight, shows
    -- nothing until you push the cart" report (2026-08-08).
    local action, inv, cart, flashlight = buildInstallScenario()
    local captured
    local origIsServer = _G.isServer
    local origSyncMD, origSyncF = _G.syncItemModData, _G.syncItemFields
    local origNet = SaucedCarts.Network
    local counters = withVM(false, function()
        _G.isServer = function() return true end
        _G.syncItemModData = function() end
        _G.syncItemFields = function() end
        SaucedCarts.Network = { broadcast = function(cmd, args)
            if cmd == "upgradeInstalled" then captured = args end
        end }
        action:complete()
    end)
    _G.isServer, _G.syncItemModData, _G.syncItemFields = origIsServer, origSyncMD, origSyncF
    SaucedCarts.Network = origNet
    if not Assert.notNil(captured, "upgradeInstalled broadcast fired") then
        return false
    end
    if not Assert.equal(captured.upgradeType, "flashlight",
        "broadcast type") then return false end
    return Assert.notNil(captured.flashlightData,
        "broadcast carries flashlightData for ground-cart client mirroring")
end

local function buildBatteryScenario(cartCharge, batteryUses)
    require "SaucedCarts/TimedActions/ISInsertBatteryAction"
    local inv = makeContainer()
    local cart = makeItem(TEST_CART_TYPE, nil)
    cart:getModData().SaucedCarts_hasFlashlight = true
    cart:getModData().SaucedCarts_flashlightData = { originalType = "Base.Torch" }
    cart:getModData().SaucedCarts_batteryCharge = cartCharge
    local battery = makeItem("Base.Battery", inv)
    battery._uses = batteryUses
    local ch = makeCharacter(inv, cart)
    local action = ISInsertBatteryAction:new(ch, cart:getID(), battery:getID())
    return action, inv, cart, battery
end

tests["battery_partial_drain_keeps_the_battery"] = function()
    -- Drain-what-fits: cart at 50%, full battery -> tank tops to 100%,
    -- battery keeps the remainder, item NOT consumed, nothing removed.
    local action, inv, cart, battery = buildBatteryScenario(0.5, 1.0)
    local counters = withVM(false, function() action:complete() end)
    if not Assert.equal(cart:getModData().SaucedCarts_batteryCharge, 1.0,
        "tank filled to cap") then return false end
    if not Assert.isTrue(math.abs(battery._uses - 0.5) < 0.01,
        "battery keeps the remainder (~0.5)") then return false end
    if not Assert.isTrue(inv:contains(battery),
        "partially drained battery stays in inventory") then return false end
    return Assert.equal(counters.remove, 0, "no removal for a partial drain")
end

tests["battery_fully_drained_is_consumed"] = function()
    -- Battery smaller than the deficit: fully drained -> consumed (server).
    local action, inv, cart, battery = buildBatteryScenario(0.5, 0.3)
    local counters = withVM(false, function() action:complete() end)
    if not Assert.isTrue(math.abs(cart:getModData().SaucedCarts_batteryCharge - 0.8) < 0.01,
        "tank gained the battery's full charge") then return false end
    if not Assert.isFalse(inv:contains(battery),
        "emptied battery consumed") then return false end
    return Assert.isTrue(counters.remove >= 1, "server broadcasts the removal")
end

tests["battery_insert_invalid_when_tank_full"] = function()
    local action = buildBatteryScenario(1.0, 1.0)
    local valid
    withVM(false, function() valid = action:isValid() end)
    return Assert.isFalse(valid,
        "isValid rejects insertion at full charge (canInsertBattery gate)")
end

tests["all_replicated_actions_define_complete"] = function()
    -- THE replication opt-in contract. LuaTimedActionNew.java:77-79: a Lua
    -- action class whose metatable lacks `complete` is flagged
    -- useCustomRemoteTimedActionSync and is NEVER SENT to the server. Through
    -- v2.1.18 the flashlight/battery actions had no complete -- dedis never
    -- consumed items, never wrote server ModData, and client/server diverged.
    -- Any action that mutates authoritative state MUST appear here.
    require "SaucedCarts/TimedActions/ISRemoveFlashlightAction"
    require "SaucedCarts/TimedActions/ISInsertBatteryAction"
    require "SaucedCarts/TimedActions/ISRemoveBatteryAction"
    require "SaucedCarts/TimedActions/ISCartRepairAction"
    local classes = {
        ISInstallFlashlightAction = ISInstallFlashlightAction,
        ISRemoveFlashlightAction = ISRemoveFlashlightAction,
        ISInsertBatteryAction = ISInsertBatteryAction,
        ISRemoveBatteryAction = ISRemoveBatteryAction,
        ISCartRepairAction = ISCartRepairAction,
        ISCartEquipAction = ISCartEquipAction,
    }
    for name, cls in pairs(classes) do
        if not Assert.equal(type(rawget(cls, "complete")), "function",
            name .. " must define :complete() directly -- without it the "
            .. "action is silently client-only (never replicated)") then
            return false
        end
    end
    return true
end

return tests
