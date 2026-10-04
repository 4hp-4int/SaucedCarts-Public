--[[
    Carts in a REAL world
    =====================
    EngineCartTests proved the cart as an item. These tests put it on the
    ground: a real IsoPlayer standing on a real IsoGridSquare, registered
    where the engine's own getCell():getGridSquare finds it, carts dropped
    as real IsoWorldInventoryObjects -- and VANILLA's Lua (forceDropHeavyItems,
    ISTransferAction) moving them, with SaucedCarts' wrappers in place.

    World mutations run with GameServer.server set: that is the branch a
    dedicated server takes, and it is what makes them headless (the sprite
    and texture work in IsoWorldInventoryObject sits behind
    `!GameServer.server`). It also routes IsoCell.getGridSquare through
    ServerMap, which is where PZEngine.newSquare registers squares.

    The global getCell() stays the kit's mock outside these tests; each test
    swaps the real cell in and restores it.

    Engine-guarded: with no PZ install (CI) this file contributes no tests.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end
if not (PZEngine and PZEngine.available() and PZEngine.newSquare and PZEngine.setServer) then return {} end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartData"
require "SaucedCarts/CartTransferInterceptor"
require "SaucedCarts/ForceDropGuard"

-- ── World harness (shared: Tests/EngineWorld.lua) ─────────────────────────

local World = require "SaucedCarts/Tests/EngineWorld"
local inWorld, cart, holdCart = World.inWorld, World.cart, World.holdCart

--- Vanilla forceDropHeavyItems, loaded from the install, behind the guard.
--- Returns the raw vanilla function too, for the before/after comparison.
local vanillaForceDrop
local function installForceDrop()
    if not vanillaForceDrop then
        forceDropHeavyItems = nil
        local ok, err = PZEngine.loadVanilla("shared/TimedActions/ISEquipWeaponAction")
        assert(ok, "ISEquipWeaponAction: " .. tostring(err))
        vanillaForceDrop = assert(forceDropHeavyItems, "vanilla defines forceDropHeavyItems")
    end
    forceDropHeavyItems = vanillaForceDrop
    SaucedCarts._forceDropGuardInstalled = nil
    SaucedCarts.ForceDropGuard.install()
    assert(forceDropHeavyItems ~= vanillaForceDrop, "ForceDropGuard wrapped it")
    return vanillaForceDrop
end

local tests = {}

-- ── The harness itself ────────────────────────────────────────────────────

tests["world_harness_square_lookup_is_the_engines"] = function()
    return inWorld(function(w)
        if not Assert.isTrue(getCell():getGridSquare(w.sq:getX(), w.sq:getY(), 0) == w.sq,
            "getCell():getGridSquare finds the registered square") then return false end
        if not Assert.isNil(getCell():getGridSquare(w.sq:getX() + 1, w.sq:getY() + 101, 0),
            "an unregistered square is nil, as in an unloaded area") then return false end
        return Assert.isTrue(w.player:getCurrentSquare() == w.sq, "player stands on it")
    end)
end

tests["world_dropped_cart_is_a_real_world_object"] = function()
    return inWorld(function(w)
        local c = cart()
        w.sq:AddWorldInventoryItem(c, 0.5, 0.5, 0)
        local wi = c:getWorldItem()
        if not Assert.notNil(wi, "cart has a world item") then return false end
        if not Assert.equal(w.sq:getWorldObjects():size(), 1, "square lists it") then return false end
        -- Vanilla's bare 4-arg drop does NOT exempt the item from world
        -- cleanup. This is the premise of every exemption fix below.
        return Assert.isFalse(wi:isIgnoreRemoveSandbox(), "a bare drop is not exempt from cleanup")
    end)
end

-- ── 2.1.21: vanilla's forceDropHeavyItems, the sixth drop path ────────────

tests["world_force_drop_marks_the_cart_persistent"] = function()
    installForceDrop()
    return inWorld(function(w)
        local c = cart()
        holdCart(w.player, c)
        forceDropHeavyItems(w.player)
        local wi = c:getWorldItem()
        if not Assert.notNil(wi, "the cart landed on the ground") then return false end
        if not Assert.isTrue(wi:getSquare() == w.sq, "on the player's square") then return false end
        if not Assert.isFalse(w.player:getInventory():contains(c), "out of the inventory") then return false end
        if not Assert.isNil(w.player:getPrimaryHandItem(), "hands empty") then return false end
        return Assert.isTrue(wi:isIgnoreRemoveSandbox(), "guarded force-drop exempts it from world cleanup")
    end)
end

-- The premise, executed: without the guard, vanilla leaves it sweepable.
-- If this ever flips, vanilla fixed it and the guard's marking is redundant.
tests["world_force_drop_unguarded_vanilla_leaves_it_sweepable"] = function()
    local vanilla = installForceDrop()
    return inWorld(function(w)
        local c = cart()
        holdCart(w.player, c)
        vanilla(w.player)
        local wi = c:getWorldItem()
        if not Assert.notNil(wi, "vanilla dropped it") then return false end
        return Assert.isFalse(wi:isIgnoreRemoveSandbox(), "vanilla's force-drop does not exempt it")
    end)
end

-- ── 2.1.21: using a found cart marks it ───────────────────────────────────

tests["world_transfer_into_ground_cart_marks_it"] = function()
    return inWorld(function(w)
        local c = cart()
        w.sq:AddWorldInventoryItem(c, 0.5, 0.5, 0)   -- a loot-spawned cart: unexempt
        local apple = PZEngine.instanceItem("Base.Apple")
        w.player:getInventory():AddItem(apple)
        local moved = SaucedCarts.performCartTransfer(w.player, apple, w.player:getInventory(), c:getInventory())
        if not Assert.isTrue(moved, "transfer succeeded") then return false end
        if not Assert.isTrue(c:getInventory():contains(apple), "apple is in the cart") then return false end
        return Assert.isTrue(c:getWorldItem():isIgnoreRemoveSandbox(), "the cart you loaded is exempt now")
    end)
end

tests["world_transfer_out_of_ground_cart_marks_it"] = function()
    return inWorld(function(w)
        local c = cart()
        w.sq:AddWorldInventoryItem(c, 0.5, 0.5, 0)
        local apple = PZEngine.instanceItem("Base.Apple")
        c:getInventory():AddItem(apple)
        local moved = SaucedCarts.performCartTransfer(w.player, apple, c:getInventory(), w.player:getInventory())
        if not Assert.isTrue(moved, "transfer succeeded") then return false end
        return Assert.isTrue(c:getWorldItem():isIgnoreRemoveSandbox(), "taking from it counts as using it")
    end)
end

tests["world_transfer_drop_to_ground_is_exempt"] = function()
    return inWorld(function(w)
        local c = cart()
        holdCart(w.player, c)
        local apple = PZEngine.instanceItem("Base.Apple")
        c:getInventory():AddItem(apple)
        local moved = SaucedCarts.performCartTransfer(w.player, apple, c:getInventory(), nil, w.sq)
        if not Assert.isTrue(moved, "drop succeeded") then return false end
        local wi = apple:getWorldItem()
        if not Assert.notNil(wi, "apple is on the ground") then return false end
        return Assert.isTrue(wi:isIgnoreRemoveSandbox(), "an item dropped through the pipeline is exempt")
    end)
end

-- ── A cart that breaks as it leaves the hands ─────────────────────────────
-- The MP split, as the engine runs it: a replicating timed action finishes
-- with `act.perform(); if (!GameClient.client) act.complete();`
-- (IsoGameCharacter.java:9764). So on an MP client a drop runs perform() ONLY
-- and the server runs complete(), with its own copy of the cart. Every
-- client-side "delegate the break" branch inside complete() was therefore dead
-- in MP (removed: it was the 2.1.21 "stayed on the server's books" fix, whose
-- premise -- the client removing the cart -- the game never executes). The
-- live UI paths (drag to floor, V, right-click Unequip) all go through
-- requestInstantDrop instead; verified on the dedi 2026-10-04 with a cart
-- rigged to break: the server broke it, took it off the books, the spilled
-- corpse landed interactable on both clients.
--
-- Vanilla's real ISDropWorldItemAction here, SaucedCarts' hook on top.

local dropHookReady = false
local function installDropHook()
    if dropHookReady then return end
    ISDropWorldItemAction = nil
    local ok, err = PZEngine.loadVanilla("shared/TimedActions/ISDropWorldItemAction")
    assert(ok, "ISDropWorldItemAction: " .. tostring(err))
    require "SaucedCarts/ContainerRestrictions"
    SaucedCarts.ContainerRestrictions.initDropActionHook()
    -- Server-only module; its guard reads the context at require time.
    local c, sv = isClient, isServer
    isClient = function() return false end
    isServer = function() return true end
    require "SaucedCarts/AnimationSync"
    isClient, isServer = c, sv
    dropHookReady = true
end

local function wornOutCart()
    local c = cart()
    c:setCondition(1)
    c:getModData().SaucedCarts_distancePushed = 5000
    return c
end

--- Capture SaucedCarts.Network.sendToServer for the duration of fn.
local function captureToServer(fn)
    local got = {}
    local real = SaucedCarts.Network.sendToServer
    SaucedCarts.Network.sendToServer = function(player, command, args)
        got[#got + 1] = { command = command, args = args }
    end
    local ok, err = pcall(fn)
    SaucedCarts.Network.sendToServer = real
    if not ok then error(err, 0) end
    return got
end

tests["world_break_on_drop_mp_client_perform_changes_nothing"] = function()
    installDropHook()
    return inWorld(function(w)
        local c = wornOutCart()
        holdCart(w.player, c)
        local action = ISDropWorldItemAction:new(w.player, c, w.sq, 0.5, 0.5, 0, 0, false)
        -- perform() ends in ISBaseTimedAction.perform, which reports to the
        -- character's action queue and the action log -- bookkeeping that
        -- exists when the action runs through the real queue. Stand-ins for
        -- this one call; the assertions are about the cart.
        local savedQ, savedLog = ISTimedActionQueue, ISLogSystem
        ISTimedActionQueue = { getTimedActionQueue = function()
            return { queue = {}, onCompleted = function() end } end }
        ISLogSystem = { logAction = function() end }
        local ok, err = pcall(function() action:perform() end)   -- all an MP client runs
        ISTimedActionQueue, ISLogSystem = savedQ, savedLog
        if not Assert.isTrue(ok, "perform ran (" .. tostring(err) .. ")") then return false end
        if not Assert.isTrue(w.player:getInventory():contains(c), "the client did not remove the cart") then return false end
        if not Assert.isNil(c:getWorldItem(), "nor drop it") then return false end
        for _, sent in ipairs(w.sent) do
            if not Assert.isFalse(sent:find("^remove") ~= nil, "no delete sent from the client (" .. sent .. ")") then return false end
        end
        return Assert.equal(c:getCondition(), 1, "and applied no wear: the server decides")
    end, { client = true })
end

tests["world_break_on_drop_server_complete_takes_it_off_the_books"] = function()
    installDropHook()
    return inWorld(function(w)
        local c = wornOutCart()
        local apple = PZEngine.instanceItem("Base.Apple")
        c:getInventory():AddItem(apple)
        holdCart(w.player, c)
        ISDropWorldItemAction:new(w.player, c, w.sq, 0.5, 0.5, 0, 0, false):complete()
        if not Assert.isFalse(w.player:getInventory():contains(c), "cart off the server's books") then return false end
        if not Assert.isNil(c:getWorldItem(), "a broken cart does not land as a cart") then return false end
        if not Assert.notNil(apple:getWorldItem(), "its contents spill") then return false end
        local removed = false
        for _, s2 in ipairs(w.sent) do if s2 == "remove SaucedCarts.ShoppingCart" then removed = true end end
        return Assert.isTrue(removed, "and the server told the client")
    end)
end

-- The path the live UI actually takes (drag to floor, V, right-click Unequip).
tests["world_break_on_drop_server_takes_it_off_the_books"] = function()
    installDropHook()
    local handler = SaucedCarts.Network._getServerHandler("requestInstantDrop")
    if not Assert.notNil(handler, "server handler registered") then return false end
    return inWorld(function(w)
        local c = wornOutCart()
        local apple = PZEngine.instanceItem("Base.Apple")
        c:getInventory():AddItem(apple)
        holdCart(w.player, c)
        handler(w.player, { cartId = c:getID(), distancePushed = 5000 })
        if not Assert.isFalse(w.player:getInventory():contains(c), "cart off the server's books") then return false end
        if not Assert.isNil(w.player:getPrimaryHandItem(), "hands cleared") then return false end
        if not Assert.isNil(c:getWorldItem(), "a broken cart does not land as a cart") then return false end
        if not Assert.notNil(apple:getWorldItem(), "its contents spill onto the ground") then return false end
        local removed = false
        for _, s in ipairs(w.sent) do if s == "remove SaucedCarts.ShoppingCart" then removed = true end end
        return Assert.isTrue(removed, "and the server told the client it is gone")
    end)
end

-- Control: a healthy cart still drops through vanilla's own complete().
tests["world_healthy_drop_still_lands_and_is_exempt"] = function()
    installDropHook()
    return inWorld(function(w)
        local c = cart()
        holdCart(w.player, c)
        ISDropWorldItemAction:new(w.player, c, w.sq, 0.5, 0.5, 0, 0, false):complete()
        if not Assert.isFalse(w.player:getInventory():contains(c), "left the inventory") then return false end
        local wi = c:getWorldItem()
        if not Assert.notNil(wi, "on the ground") then return false end
        return Assert.isTrue(wi:isIgnoreRemoveSandbox(), "exempt, as vanilla's drop marks it")
    end)
end

-- ── Distance reaches the server when a cart leaves the hands ──────────────
-- In MP the drop/unequip that applies wear is the server's copy of a vanilla
-- action (complete() runs only where !GameClient.client), reading the
-- server's modData. The client sends its measured distance once, when the
-- action is CREATED -- before it is queued and sent -- instead of every 10
-- tiles while pushing. Real vanilla ISUnequipAction / ISDropWorldItemAction.

local function installUnequipHook()
    -- Vanilla's ISUnequipAction:new asks ISWearClothing.isStopOnWalk(item).
    if not ISWearClothing then
        assert(PZEngine.loadVanilla("shared/TimedActions/ISWearClothing"))
    end
    -- ...and, on a client, getPlayerHotbar (a UI global the harness lacks).
    -- nil = "not from the hotbar", which is true of a cart in the hands.
    getPlayerHotbar = getPlayerHotbar or function() return nil end
    require "SaucedCarts/ContainerRestrictions"
    SaucedCarts.ContainerRestrictions.initUnequipHook()
end

local function sentDistance(sentToServer)
    for _, m in ipairs(sentToServer) do
        if m.command == "syncCartDistance" then return m end
    end
end

tests["world_distance_sent_once_when_an_unequip_is_created"] = function()
    installDropHook(); installUnequipHook()
    return inWorld(function(w)
        local c = cart()
        holdCart(w.player, c)
        c:getModData().SaucedCarts_distancePushed = 37.5
        local got = captureToServer(function() ISUnequipAction:new(w.player, c, 50) end)
        local m = sentDistance(got)
        if not Assert.notNil(m, "syncCartDistance sent") then return false end
        if not Assert.equal(m.args.cartId, c:getID(), "for this cart") then return false end
        if not Assert.equal(m.args.distancePushed, 37.5, "with the measured distance") then return false end
        return Assert.equal(#got, 1, "exactly one command")
    end, { client = true })
end

tests["world_distance_sent_once_when_a_drop_is_created"] = function()
    installDropHook()
    return inWorld(function(w)
        local c = cart()
        holdCart(w.player, c)
        c:getModData().SaucedCarts_distancePushed = 12
        local got = captureToServer(function()
            ISDropWorldItemAction:new(w.player, c, w.sq, 0.5, 0.5, 0, 0, false)
        end)
        local m = sentDistance(got)
        if not Assert.notNil(m, "syncCartDistance sent") then return false end
        return Assert.equal(m.args.distancePushed, 12, "with the measured distance")
    end, { client = true })
end

tests["world_distance_not_sent_for_other_items_or_by_the_server"] = function()
    installDropHook(); installUnequipHook()
    local onClient = inWorld(function(w)
        local axe = PZEngine.instanceItem("Base.Axe")
        w.player:getInventory():AddItem(axe)
        w.player:setPrimaryHandItem(axe)
        local got = captureToServer(function() ISUnequipAction:new(w.player, axe, 50) end)
        return Assert.isNil(sentDistance(got), "a non-cart sends nothing")
    end, { client = true })
    if not onClient then return false end
    return inWorld(function(w)
        local c = cart()
        holdCart(w.player, c)
        c:getModData().SaucedCarts_distancePushed = 99
        -- The server rebuilds the replicated action through the same new().
        local got = captureToServer(function() ISUnequipAction:new(w.player, c, 50) end)
        return Assert.isNil(sentDistance(got), "the server's rebuild of the action sends nothing")
    end)
end

-- ── 2.1.21: findCart's character-anchored fallback ────────────────────────
-- The server's copy of the replicating equip action re-finds the cart from
-- serialized primitives. A cart in a world container (a crate) is labelled
-- "inventory" by the client, so before the ladder the server searched the
-- player's inventory only, failed, and the push the client had already
-- predicted never happened ("it just goes into my inventory"). Now the last
-- rung scans the squares around the CHARACTER. Real crate (an IsoObject with
-- a real ItemContainer) on a real square, found through the engine's lookup.

require "SaucedCarts/TimedActions/ISCartEquipAction"

local function crateAt(sq)
    local obj = IsoObject.new(PZEngine.cell(), sq, nil)
    local container = ItemContainer.new("crate", sq, obj)
    obj:setContainer(container)
    sq:AddSpecialObject(obj)
    return container
end

local function groundAt(dx, dy, w)
    return World.groundAt(w.sq, dx, dy)
end

tests["world_equip_finds_cart_in_a_crate_beside_the_character"] = function()
    return inWorld(function(w)
        local crate = crateAt(groundAt(1, 1, w))
        local c = cart()
        crate:AddItem(c)
        local action = ISCartEquipAction:new(w.player, c:getID(), "inventory")
        return Assert.isTrue(action:findCart() == c, "the server re-finds the cart in the crate")
    end)
end

tests["world_equip_never_resolves_the_wrong_cart"] = function()
    return inWorld(function(w)
        local crate = crateAt(groundAt(-1, 0, w))
        local other = cart()
        crate:AddItem(other)
        local action = ISCartEquipAction:new(w.player, other:getID() + 99999, "inventory")
        return Assert.isNil(action:findCart(), "a different cart within reach is never taken")
    end)
end

tests["world_equip_window_is_bounded"] = function()
    return inWorld(function(w)
        local crate = crateAt(groundAt(3, 0, w))
        local c = cart()
        crate:AddItem(c)
        local action = ISCartEquipAction:new(w.player, c:getID(), "inventory")
        return Assert.isNil(action:findCart(), "three tiles away is out of reach (5x5 window)")
    end)
end

-- The findCart report's own setup, reproduced live 2026-10-04: a cart inside a
-- bag. The server's ladder handled it, but the CLIENT menu never reached it --
-- its inventory check was top-level only (containsID), so a nested cart went
-- to the loot handler and "Could not find cart location".

tests["world_menu_counts_a_cart_in_a_carried_bag_as_in_inventory"] = function()
    require "SaucedCarts/ContextMenu"
    local CM = SaucedCarts.ContextMenu or require "SaucedCarts/ContextMenu"
    local isIn = CM and CM._isInPlayerInventory
    if not Assert.notNil(isIn, "ContextMenu exposes its inventory check") then return false end
    return inWorld(function(w)
        local bag = PZEngine.instanceItem("Base.Bag_DuffelBag")
        local c = cart()
        bag:getItemContainer():AddItem(c)
        w.player:getInventory():AddItem(bag)
        if not Assert.isTrue(isIn(w.player, c), "a cart in a carried duffel is in the player's inventory") then return false end
        local loose = cart()
        w.player:getInventory():AddItem(loose)
        if not Assert.isTrue(isIn(w.player, loose), "a top-level cart still is") then return false end
        local elsewhere = cart()
        return Assert.isFalse(isIn(w.player, elsewhere), "a cart nobody carries is not")
    end)
end

tests["world_equip_finds_cart_in_a_bag_on_the_ground"] = function()
    return inWorld(function(w)
        local bag = PZEngine.instanceItem("Base.Bag_DuffelBag")
        local c = cart()
        bag:getItemContainer():AddItem(c)
        groundAt(1, 0, w):AddWorldInventoryItem(bag, 0.5, 0.5, 0)
        local action = ISCartEquipAction:new(w.player, c:getID(), "inventory")
        return Assert.isTrue(action:findCart() == c, "the server re-finds a cart in a bag set down beside the player")
    end)
end

tests["world_equip_finds_cart_in_a_bag_in_inventory"] = function()
    return inWorld(function(w)
        local bag = PZEngine.instanceItem("Base.Bag_DuffelBag")
        local c = cart()
        bag:getItemContainer():AddItem(c)
        w.player:getInventory():AddItem(bag)
        local action = ISCartEquipAction:new(w.player, c:getID(), "inventory")
        if not Assert.isTrue(action:findCart() == c, "resolved through the bag") then return false end
        action:complete()
        if not Assert.isTrue(w.player:getPrimaryHandItem() == c, "and equipped: in both hands") then return false end
        return Assert.isFalse(bag:getItemContainer():contains(c), "out of the bag")
    end)
end

-- ── 2.1.21: Weight Reduction 100 ──────────────────────────────────────────
-- The sandbox max was 99 while the tooltip promised "100 = items weigh
-- nothing". Executed against the real InventoryContainer: setWeightReduction
-- clamps to 0..100 (InventoryContainer.java:139-144) and getEquippedWeight is
-- own weight * equippedOrWornEncumbranceMultiplier + contents * (1 - WR/100)
-- (:289-295), with ZomboidGlobals loaded from the game's real defines.lua.

local function cartAt(wr, planks)
    local saved = SandboxVars.SaucedCarts.WeightReduction
    SandboxVars.SaucedCarts.WeightReduction = wr
    local c = cart()
    SaucedCarts.applyMultipliers(c)
    for _ = 1, planks do c:getInventory():AddItem(PZEngine.instanceItem("Base.Plank")) end
    SandboxVars.SaucedCarts.WeightReduction = saved
    return c
end

-- What the load adds to what you carry, over the same cart empty.
local function loadCost(wr)
    local loaded, empty = cartAt(wr, 10), cartAt(wr, 0)
    return loaded:getEquippedWeight() - empty:getEquippedWeight(), loaded
end

tests["world_weight_reduction_100_contents_weigh_nothing"] = function()
    local cost, c = loadCost(100)
    if not Assert.equal(c:getWeightReduction(), 100, "the engine keeps 100") then return false end
    if not Assert.isTrue(c:getContentsWeight() > 5, "the planks do weigh something ("
        .. c:getContentsWeight() .. ")") then return false end
    return Assert.isTrue(math.abs(cost) < 1e-4, "at 100 the load adds nothing (" .. cost .. ")")
end

-- The actual 2.1.21 fix: the option's max was 99, so the engine refused 100
-- and kept the old value. Through the engine's own typed option, registered
-- from this mod's real sandbox-options.txt.
tests["world_weight_reduction_option_accepts_100"] = function()
    if not PZEngine.sandboxSet then return true end
    local kept = PZEngine.sandboxSet("SaucedCarts.WeightReduction", 100)
    if not Assert.notNil(kept, "the engine registered SaucedCarts.WeightReduction") then return false end
    local ok = Assert.equal(kept, 100, "the engine accepts 100")
    PZEngine.sandboxSet("SaucedCarts.WeightReduction", 95)
    return ok
end

tests["world_weight_reduction_95_contents_cost_five_percent"] = function()
    local cost, c = loadCost(95)
    local expected = c:getContentsWeight() * 0.05
    return Assert.isTrue(math.abs(cost - expected) < 1e-3,
        "default 95: the load costs 5% (" .. cost .. " ~ " .. expected .. ")")
end

return tests
