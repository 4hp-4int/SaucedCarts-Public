--[[
    Corpse storage against the REAL engine
    ======================================
    Every rule in CorpseStorage leans on an engine claim -- how a corpse
    becomes an item, what survives serialization, which clock death times
    use, when vanilla despawns a body. Until now those claims were comments
    and mocks. Here they execute:

      * real zombie corpses (IsoDeadBody on a real square, ObjectIDs from
        the real ObjectIDManager), turned into Base.CorpseMale items by the
        engine's own becomeCorpseItem / storeInByteData,
      * the real sandbox (HoursForCorpseRemoval read through the same
        SandboxOptions path the mod uses),
      * ONE clock: the engine's GameTime, which both Lua's rot stamps and
        Java's death times read, moved forward by the test,
      * vanilla's own rot ticker, IsoDeadBody.updateBodies(), deciding
        whether an unloaded body survives.

    Engine-guarded: with no PZ install (CI) this file contributes no tests.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end
if not (PZEngine and PZEngine.available() and PZEngine.newCorpse and PZEngine.gameTime) then return {} end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartData"
require "SaucedCarts/CartTransferInterceptor"
require "SaucedCarts/Durability"
require "SaucedCarts/CorpseStorage"

local World = require "SaucedCarts/Tests/EngineWorld"
local CS = SaucedCarts.CorpseStorage

local START = 500   -- world hours every test starts at

local function inCorpseWorld(fn)
    return World.inWorld(function(w)
        World.setWorldHours(START)
        return fn(w)
    end, { realClock = true })
end

local function zombieCorpse(sq)
    local body, err = PZEngine.newCorpse(sq, true)
    assert(body, "newCorpse: " .. tostring(err))
    return body
end

local function corpsesOn(sq) return sq:getDeadBodys():size() end

local function corpseItemsIn(container)
    local n, items = 0, container:getItems()
    for i = 0, items:size() - 1 do
        if CS.isCorpseItem(items:get(i)) then n = n + 1 end
    end
    return n
end

--- A ground cart beside the player and a zombie body on the other side,
--- then the server's real load handler. Returns cart, body, ok, args.
local function loadOne(w, opts)
    opts = opts or {}
    local c = World.dropOnGround(World.groundAt(w.sq, 1, 0), World.cart())
    local bodySq = World.groundAt(w.sq, opts.bodyDx or -1, 0)
    local body = zombieCorpse(bodySq)
    local args = {
        cartId = c:getID(), ghostKind = "body", ghostId = body:getObjectIDAsLong(),
        ghostX = bodySq:getX(), ghostY = bodySq:getY(), ghostZ = 0,
    }
    local ok = CS.handleLoadCorpseToCart(w.player, args)
    return c, body, ok, args, bodySq
end

local tests = {}

-- ── Engine truths the feature is built on ─────────────────────────────────

tests["corpse_engine_rot_thresholds_read_the_real_sandbox"] = function()
    local skeletonAt, removalAt = CS._getRotThresholds()
    if not Assert.equal(skeletonAt, 216, "HoursForCorpseRemoval default, via SandboxOptions") then return false end
    return Assert.equal(removalAt, 288, "+ one rot stage (216/3)")
end

tests["corpse_engine_item_roundtrip_keeps_identity"] = function()
    return inCorpseWorld(function(w)
        local body = zombieCorpse(w.sq)
        local oid = body:getObjectIDAsLong()
        local item = body:becomeCorpseItem(false)
        if not Assert.isTrue(CS.isCorpseItem(item), "becomes a corpse item") then return false end
        if not Assert.equal(item:getActualWeight(), 20, "20 kg") then return false end
        if not Assert.equal(corpsesOn(w.sq), 0, "and leaves the square") then return false end
        local back = item:loadCorpseFromByteData(w.sq)
        if not Assert.equal(back:getObjectIDAsLong(), oid, "rematerializes with the same ObjectID") then return false end
        return Assert.equal(back:getDeathTime(), START, "and the same death time")
    end)
end

-- The despawn boundary the mod's silent-drop mirrors, executed with vanilla's
-- own ticker. Vanilla is NOT a hard line at 216 h: at rot stage 3 every tick
-- rolls Rand.NextBool(7) (IsoDeadBody.updateRotting), and a body that wins
-- becomes a skeleton, which gets one more stage before removal
-- (updateBodies: age < removal + (isSkeleton ? stage : 0)). So at 216 h a
-- body is gone or a skeleton; at 288 h it is gone, always.
--- Vanilla's ticker; an exception inside it fails the test by name.
local function tick(label)
    local err = PZEngine.updateBodies()
    return Assert.isNil(err, label .. " vanilla updateBodies ran clean (" .. tostring(err) .. ")")
end

local function vanillaDespawnHolds(sq, deathHours, label)
    World.setWorldHours(deathHours + 215)
    if not tick(label) then return false end
    if not Assert.equal(corpsesOn(sq), 1, label .. " 215 h: still there") then return false end
    World.setWorldHours(deathHours + 216)
    if not tick(label) then return false end
    local left = corpsesOn(sq)
    if left == 1 then
        if not Assert.isTrue(sq:getDeadBodys():get(0):isSkeleton(),
            label .. " 216 h: gone, or a skeleton (vanilla's 1-in-7 roll)") then return false end
    end
    World.setWorldHours(deathHours + 288)
    if not tick(label) then return false end
    return Assert.equal(corpsesOn(sq), 0, label .. " 288 h: gone, skeleton or not")
end

tests["corpse_engine_vanilla_despawns_216_to_288h"] = function()
    return inCorpseWorld(function(w)
        zombieCorpse(w.sq)
        return vanillaDespawnHolds(w.sq, START, "on the ground:")
    end)
end

-- ── Loading (server handler -> the one transfer pipeline) ─────────────────

tests["corpse_load_moves_body_into_cart"] = function()
    return inCorpseWorld(function(w)
        local c, body, ok, args, bodySq = loadOne(w)
        if not Assert.isTrue(ok, "handler accepted") then return false end
        if not Assert.equal(corpseItemsIn(c:getInventory()), 1, "one corpse in the cart") then return false end
        if not Assert.equal(corpsesOn(bodySq), 0, "body gone from the ground") then return false end
        local item = c:getInventory():getItems():get(0)
        if not Assert.equal(CS.getStampedDeathTime(item), START, "death time stamped from the body") then return false end
        -- 2.1.21: loading is using the cart.
        if not Assert.isTrue(c:getWorldItem():isIgnoreRemoveSandbox(), "the cart is exempt from cleanup") then return false end
        -- 2.1.21: ghost purge keyed to the ObjectID every machine agrees on.
        local purge = World.sentCommand(w, "removeGhostCorpse")
        if not Assert.notNil(purge, "ghost purge broadcast") then return false end
        return Assert.equal(purge.args.bodyId, args.ghostId, "keyed by ObjectID")
    end)
end

tests["corpse_load_refuses_a_body_out_of_reach"] = function()
    return inCorpseWorld(function(w)
        local c, _, ok, _, bodySq = loadOne(w, { bodyDx = -12 })
        if not Assert.isFalse(ok, "refused (cheat guard)") then return false end
        if not Assert.equal(corpsesOn(bodySq), 1, "body stays on the ground") then return false end
        return Assert.equal(corpseItemsIn(c:getInventory()), 0, "nothing in the cart")
    end)
end

tests["corpse_load_refuses_when_cart_is_full"] = function()
    return inCorpseWorld(function(w)
        local c = World.dropOnGround(World.groundAt(w.sq, 1, 0), World.cart())
        SaucedCarts.applyMultipliers(c)
        local cap = c:getInventory():getCapacity()
        local inner = c:getInventory()
        while inner:getCapacityWeight() < cap - 10 do inner:AddItem(PZEngine.instanceItem("Base.Plank")) end
        local bodySq = World.groundAt(w.sq, -1, 0)
        local body = zombieCorpse(bodySq)
        local ok = CS.handleLoadCorpseToCart(w.player, {
            cartId = c:getID(), ghostKind = "body", ghostId = body:getObjectIDAsLong(),
            ghostX = bodySq:getX(), ghostY = bodySq:getY(), ghostZ = 0,
        })
        if not Assert.isFalse(ok, "refused: less than 20 kg free") then return false end
        return Assert.equal(corpsesOn(bodySq), 1, "body stays on the ground")
    end)
end

-- ── Unloading by dragging to the ground ───────────────────────────────────

tests["corpse_unload_drag_rematerializes_the_same_body"] = function()
    return inCorpseWorld(function(w)
        local c, _, _, args = loadOne(w)
        local item = c:getInventory():getItems():get(0)
        local dropSq = World.groundAt(w.sq, 0, 1)
        local moved = SaucedCarts.performCartTransfer(w.player, item, c:getInventory(), nil, dropSq)
        if not Assert.isTrue(moved, "unload accepted") then return false end
        if not Assert.equal(corpsesOn(dropSq), 1, "a body is on the ground") then return false end
        local body = dropSq:getDeadBodys():get(0)
        if not Assert.equal(body:getObjectIDAsLong(), args.ghostId, "the same body (ObjectID)") then return false end
        return Assert.equal(corpseItemsIn(c:getInventory()), 0, "cart empty")
    end)
end

-- The point of the stamp: a corpse keeps rotting while it rides in the cart.
-- Carried 150 h, unloaded at age 150: vanilla's own ticker must still take
-- it at 216 h total, not 216 h after unloading.
tests["corpse_rot_continues_through_the_cart"] = function()
    return inCorpseWorld(function(w)
        local c = loadOne(w)
        World.setWorldHours(START + 150)
        local item = c:getInventory():getItems():get(0)
        if not Assert.equal(CS.effectiveAge(item), 150, "aged 150 h in the cart") then return false end
        local dropSq = World.groundAt(w.sq, 0, 1)
        SaucedCarts.performCartTransfer(w.player, item, c:getInventory(), nil, dropSq)
        local body = dropSq:getDeadBodys():get(0)
        if not Assert.equal(body:getDeathTime(), START, "death time restored, not reset") then return false end
        return vanillaDespawnHolds(dropSq, START, "carried 150 h, then:")
    end)
end

tests["corpse_unload_past_despawn_age_is_silent"] = function()
    return inCorpseWorld(function(w)
        local c = loadOne(w)
        World.setWorldHours(START + 216)
        local item = c:getInventory():getItems():get(0)
        local dropSq = World.groundAt(w.sq, 0, 1)
        local moved = SaucedCarts.performCartTransfer(w.player, item, c:getInventory(), nil, dropSq)
        if not Assert.isTrue(moved, "handled") then return false end
        if not Assert.equal(corpsesOn(dropSq), 0, "no body materializes (vanilla would despawn it)") then return false end
        return Assert.equal(corpseItemsIn(c:getInventory()), 0, "and it is out of the cart")
    end)
end

-- ── Unloading with vanilla's Grab (ISGrabCorpseItem) ──────────────────────
-- A different vanilla action class from the transfer pipeline, so it has its
-- own wrapper (GrabCorpseInterceptor). Vanilla's real ISGrabCorpseItem here.

local grabReady = false
local function installGrab()
    if grabReady then return end
    ISGrabCorpseItem = nil
    if not forceDropHeavyItems then
        assert(PZEngine.loadVanilla("shared/TimedActions/ISEquipWeaponAction"))
    end
    local ok, err = PZEngine.loadVanilla("shared/TimedActions/ISGrabCorpseItem")
    assert(ok, "ISGrabCorpseItem: " .. tostring(err))
    require "SaucedCarts/GrabCorpseInterceptor"
    grabReady = true
end

tests["corpse_grab_past_despawn_age_is_silent_and_marks_the_cart"] = function()
    installGrab()
    return inCorpseWorld(function(w)
        local c = loadOne(w)
        c:getWorldItem():setIgnoreRemoveSandbox(false)    -- prove the grab itself marks it
        World.setWorldHours(START + 216)
        local item = c:getInventory():getItems():get(0)
        ISGrabCorpseItem:new(w.player, item):complete()
        if not Assert.equal(corpseItemsIn(c:getInventory()), 0, "out of the cart") then return false end
        if not Assert.isNil(w.player:getPrimaryHandItem(), "nothing grabbed: a corpse past 216 h is gone") then return false end
        return Assert.isTrue(c:getWorldItem():isIgnoreRemoveSandbox(), "taking from the cart marks it")
    end)
end

-- Fresh corpse: SaucedCarts marks the cart and hands off to vanilla, whose
-- pickUpCorpseItem rematerializes the body and converts it into a zombie
-- "reanimated for grapple" (IsoDeadBody.reanimate). That conversion needs the
-- animation system and stops partway headless, leaving a body that already
-- gave its container to the half-built zombie -- one the game never has, and
-- one that makes vanilla's rot ticker throw for every body after it. So this
-- test checks SaucedCarts' half of the hand-off and removes that body.
tests["corpse_grab_fresh_leaves_the_cart_and_marks_it"] = function()
    installGrab()
    return inCorpseWorld(function(w)
        local c = loadOne(w)
        c:getWorldItem():setIgnoreRemoveSandbox(false)
        local item = c:getInventory():getItems():get(0)
        pcall(function() ISGrabCorpseItem:new(w.player, item):complete() end)
        local bodies = w.sq:getDeadBodys()
        for i = bodies:size() - 1, 0, -1 do
            local b = bodies:get(i)
            if not b:getContainer() then b:removeFromWorld(); b:removeFromSquare() end
        end
        if not Assert.equal(corpseItemsIn(c:getInventory()), 0, "out of the cart") then return false end
        return Assert.isTrue(c:getWorldItem():isIgnoreRemoveSandbox(), "taking from the cart marks it")
    end)
end

-- ── In-cart purge ─────────────────────────────────────────────────────────

tests["corpse_purge_removes_only_the_expired"] = function()
    return inCorpseWorld(function(w)
        local c = loadOne(w)
        World.setWorldHours(START + 100)
        local body2Sq = World.groundAt(w.sq, -1, 1)
        local body2 = zombieCorpse(body2Sq)
        CS.handleLoadCorpseToCart(w.player, {
            cartId = c:getID(), ghostKind = "body", ghostId = body2:getObjectIDAsLong(),
            ghostX = body2Sq:getX(), ghostY = body2Sq:getY(), ghostZ = 0,
        })
        if not Assert.equal(corpseItemsIn(c:getInventory()), 2, "two corpses aboard") then return false end
        World.setWorldHours(START + 216)   -- first is 216 h old, second 116 h
        local purged = CS.purgeRottedCorpses(c)
        if not Assert.equal(purged, 1, "one purged") then return false end
        return Assert.equal(corpseItemsIn(c:getInventory()), 1, "the fresher one stays")
    end)
end

-- ── A cart breaking with a corpse aboard ──────────────────────────────────

tests["corpse_cart_break_puts_the_body_back_on_the_ground"] = function()
    return inCorpseWorld(function(w)
        local c, _, _, args = loadOne(w)
        local sq = c:getWorldItem():getSquare()
        SaucedCarts.Durability.dropContentsAndDestroy(c, w.player, sq)
        if not Assert.equal(corpsesOn(sq), 1, "the body is back on the ground") then return false end
        return Assert.equal(sq:getDeadBodys():get(0):getObjectIDAsLong(), args.ghostId, "the same body")
    end)
end

-- ── Encumbrance ───────────────────────────────────────────────────────────

tests["corpse_weight_reduction_applies_to_a_carried_corpse"] = function()
    return inCorpseWorld(function(w)
        local c = loadOne(w)
        SaucedCarts.applyMultipliers(c)
        local empty = World.cart()
        SaucedCarts.applyMultipliers(empty)
        local cost = c:getEquippedWeight() - empty:getEquippedWeight()
        return Assert.isTrue(math.abs(cost - 20 * 0.05) < 1e-3,
            "a 20 kg corpse costs 1 kg to push at the default 95 (" .. cost .. ")")
    end)
end

return tests
