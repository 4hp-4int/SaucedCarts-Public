--[[
    SaucedCarts/Tests/OfflineCorpseStorageTests.lua
    ================================================

    Coverage for CorpseStorage — the module that lets a dragged corpse be
    loaded into a cart's inventory. Vanilla has the machinery but gates it
    on a 19-string hardcoded container-type allowlist (no carts). Our
    pipeline owns the move end-to-end, bypassing the allowlist, and relies
    on vanilla's IsoDeadBody.getItem <-> loadCorpseFromByteData pair for
    lossless corpse serialization.

    Scope:
      * isCorpseItem: detects Base.CorpseMale/Female/Animal, rejects others
      * canLoadCorpseIntoCart: weight-capacity gate, owned entirely by us
      * handleLoadCorpseToCart: full server-handler flow
          - validates args + isDraggingCorpse
          - resolves grappled target (IsoDeadBody direct / IsoGameCharacter
            via becomeCorpseSilently)
          - calls deadBody:getItem() to serialize
          - AddItem to cart container + sendAddItemToContainer broadcast
          - removeCorpse from old square + invalidateCorpse
          - LetGoOfGrappled on success
      * In-flight guard: double-invocation is a no-op on the second call
      * Gate rejection does NOT release grapple (player still holds body)

    Out of scope:
      * IsoDeadBody.getItem <-> loadCorpseFromByteData round-trip — that's
        Java bytecode. Live probe covers it.
      * Context menu wiring — ISCartLoadCorpseAction queueing is covered
        by the smoke tests' "does the action construct" check.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/CorpseStorage"

local CS = SaucedCarts.CorpseStorage

-- ============================================================================
-- TEST FIXTURES
-- ============================================================================

local TEST_CART_TYPE = "SaucedCarts.TestCorpseCart"

if not SaucedCarts.isRegistered(TEST_CART_TYPE) then
    SaucedCarts.registerCart(TEST_CART_TYPE, {
        name             = "TestCorpseCart",
        capacity         = 150,  -- enough for a corpse
        weightReduction  = 50,
        runSpeedModifier = 0.85,
        conditionMax     = 20,
    })
end

--- Make a cart fixture whose inner container safeIsCart accepts.
local function makeRegisteredCart(opts)
    opts = opts or {}
    local cart = F.item({
        id       = opts.id,
        fullType = opts.fullType or TEST_CART_TYPE,
        weight   = opts.weight or 2.0,
    })
    cart._type = "InventoryContainer"
    cart._innerContainer = F.container({
        containingItem = cart,
        typeName       = "ShoppingCart",
        parent         = opts.parent,
        capacity       = opts.capacity or 150,
    })
    cart.getItemContainer = function(self) return self._innerContainer end
    return cart
end

-- Patch safeIsCart so our Lua-table mocks pass the cart check. Additive —
-- real userdata items still flow through the original implementation.
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table"
        and item._type == "InventoryContainer"
        and item.getFullType
        and (item:getFullType() or ""):find("^SaucedCarts%.") then
        return true
    end
    return origSafeIsCart(item)
end

--- Mock a corpse InventoryItem — behaves like Base.CorpseMale.
local function makeCorpseItem(opts)
    opts = opts or {}
    local it = F.item({
        id       = opts.id,
        fullType = opts.fullType or "Base.CorpseMale",
        weight   = opts.weight or 60.0,
    })
    it.isHumanCorpse  = function(self)
        local ft = self:getFullType()
        return ft == "Base.CorpseMale" or ft == "Base.CorpseFemale"
    end
    it.isAnimalCorpse = function(self) return self:getFullType() == "Base.CorpseAnimal" end
    return it
end

--- Mock an IsoDeadBody — minimum surface the handler calls:
---   getItem(), getSquare(), invalidateCorpse()
local function makeDeadBody(opts)
    opts = opts or {}
    local priv = {
        id           = opts.id or 42,
        square       = opts.square,
        invalidated  = 0,
        corpseItem   = opts.corpseItem or makeCorpseItem({ weight = opts.corpseWeight or 60.0 }),
    }
    local b = { _type = "IsoDeadBody" }
    b.getID             = function(self) return priv.id end
    b.getItem           = function(self) return priv.corpseItem end
    b.getSquare         = function(self) return priv.square end
    b.invalidateCorpse  = function(self) priv.invalidated = priv.invalidated + 1 end
    b.getWeightAsCorpse = function(self)
        return priv.corpseItem:getActualWeight()
    end
    b._private = priv
    return b
end

--- Mock a living grappled character (zombie / NPC) whose becomeCorpseSilently
--- produces a fresh dead body.
local function makeLivingGrappled(opts)
    opts = opts or {}
    local deadBody = opts.deadBody or makeDeadBody({ square = opts.square })
    local c = { _type = "IsoGameCharacter" }
    c._becomeCorpseSilentlyCount = 0
    c.becomeCorpseSilently = function(self)
        self._becomeCorpseSilentlyCount = self._becomeCorpseSilentlyCount + 1
        return deadBody
    end
    c._deadBody = deadBody
    return c
end

--- Attach a setDoGrappleLetGo counter directly to the player. Vanilla's
--- API for releasing a grapple is character:setDoGrappleLetGo() (per
--- ISDropCorpseAction). Returns a handle with letGoCount for assertions.
local function attachGrappleable(player)
    local stats = { letGoCount = 0 }
    player.setDoGrappleLetGo = function(self)
        stats.letGoCount = stats.letGoCount + 1
    end
    player.getGrappleable = function(self) return stats end  -- back-compat alias
    return stats
end

--- Make a player that is currently dragging a corpse whose target is `target`.
--- `target` can be a dead body or a living grappled character.
local function makeDraggingPlayer(target, square)
    local p = F.player({ square = square })
    p.isDraggingCorpse   = function(self) return true end
    p.getGrapplingTarget = function(self) return target end
    attachGrappleable(p)
    -- Stick the cart in the player's inventory for findCartNearPlayer lookup.
    return p
end

--- Install a minimum-viable instanceof that recognizes our mocks AND
--- delegates to any pre-existing instanceof for real types used by other
--- tests loaded into the same VM. Restored at teardown.
local function patchInstanceof()
    local orig = _G.instanceof
    _G.instanceof = function(obj, type)
        if obj == nil then return false end
        if type == "IsoDeadBody"     and obj._type == "IsoDeadBody"     then return true end
        if type == "IsoGameCharacter" and obj._type == "IsoGameCharacter" then return true end
        if type == "IsoPlayer"        and obj._type == "IsoPlayer"        then return true end
        if type == "InventoryItem"    and obj._type == "InventoryItem"    then return true end
        if type == "InventoryContainer" and obj._type == "InventoryContainer" then return true end
        if type == "IsoWorldInventoryObject" and obj._type == "IsoWorldInventoryObject" then return true end
        if orig then return orig(obj, type) end
        return false
    end
    return orig
end

local tests = {}

-- ============================================================================
-- isCorpseItem
-- ============================================================================

tests["isCorpseItem_accepts_Base_CorpseMale"] = function()
    local it = makeCorpseItem({ fullType = "Base.CorpseMale" })
    return Assert.isTrue(CS.isCorpseItem(it), "CorpseMale item recognized")
end

tests["isCorpseItem_accepts_Base_CorpseFemale"] = function()
    local it = makeCorpseItem({ fullType = "Base.CorpseFemale" })
    return Assert.isTrue(CS.isCorpseItem(it), "CorpseFemale item recognized")
end

tests["isCorpseItem_accepts_Base_CorpseAnimal"] = function()
    local it = makeCorpseItem({ fullType = "Base.CorpseAnimal" })
    return Assert.isTrue(CS.isCorpseItem(it), "CorpseAnimal item recognized")
end

tests["isCorpseItem_rejects_other_item_types"] = function()
    local it = F.item({ fullType = "Base.Stone" })
    return Assert.isTrue(not CS.isCorpseItem(it), "Stone is not a corpse")
end

tests["isCorpseItem_rejects_nil"] = function()
    return Assert.isTrue(not CS.isCorpseItem(nil), "nil is not a corpse")
end

-- ============================================================================
-- canLoadCorpseIntoCart
-- ============================================================================

tests["canLoad_allows_corpse_under_capacity"] = function()
    local cart = makeRegisteredCart({ capacity = 150 })
    local ok, reason = CS.canLoadCorpseIntoCart(cart, 60.0)
    return Assert.isTrue(ok, "60kg corpse fits in 150kg cart (reason=" .. tostring(reason) .. ")")
end

tests["canLoad_rejects_corpse_over_capacity"] = function()
    local cart = makeRegisteredCart({ capacity = 50 })
    local ok, reason = CS.canLoadCorpseIntoCart(cart, 80.0)
    if not Assert.isTrue(not ok, "80kg corpse rejected by 50kg cart") then return false end
    return Assert.equal(reason, "cart full", "reason is 'cart full'")
end

tests["canLoad_rejects_non_cart"] = function()
    local bag = F.item({ fullType = "Base.Bag_BigHikingBag" })
    bag._type = "InventoryContainer"
    bag._innerContainer = F.container({ containingItem = bag, typeName = "Bag", capacity = 100 })
    bag.getItemContainer = function(self) return self._innerContainer end
    local ok, reason = CS.canLoadCorpseIntoCart(bag, 60.0)
    if not Assert.isTrue(not ok, "non-cart rejected") then return false end
    return Assert.equal(reason, "not a cart", "reason is 'not a cart'")
end

tests["canLoad_rejects_nil_cart"] = function()
    local ok, reason = CS.canLoadCorpseIntoCart(nil, 60.0)
    if not Assert.isTrue(not ok, "nil cart rejected") then return false end
    return Assert.equal(reason, "no cart", "reason is 'no cart'")
end

tests["canLoad_rejects_bad_weight"] = function()
    local cart = makeRegisteredCart()
    local ok1, reason1 = CS.canLoadCorpseIntoCart(cart, -5)
    if not Assert.isTrue(not ok1, "negative weight rejected") then return false end
    if not Assert.equal(reason1, "invalid weight", "reason matches") then return false end

    local ok2, reason2 = CS.canLoadCorpseIntoCart(cart, "heavy")
    if not Assert.isTrue(not ok2, "string weight rejected") then return false end
    return Assert.equal(reason2, "invalid weight", "reason matches")
end

tests["canLoad_ignores_weight_reduction"] = function()
    -- PZ ItemContainer.getWeightReduction reduces encumbrance on the
    -- carrying CHARACTER, not the container's capacity accounting.
    -- So a 60kg corpse consumes 60kg of cap even with 95% reduction.
    -- Regression guard: don't apply reduction to the gate.
    local cart = makeRegisteredCart({ capacity = 50 })
    cart:getItemContainer():setWeightReduction(95)
    local ok, reason = CS.canLoadCorpseIntoCart(cart, 60.0)
    if not Assert.isTrue(not ok,
        "60kg corpse still rejected by 50kg cart despite 95% weight reduction") then return false end
    return Assert.equal(reason, "cart full", "reason matches")
end

tests["canLoad_accounts_for_existing_cart_weight"] = function()
    local cart = makeRegisteredCart({ capacity = 100 })
    -- Pre-fill the cart with 50kg of stuff. Only 50kg should be available.
    local heavy = F.item({ fullType = "Base.Stone", weight = 50.0 })
    cart:getItemContainer():AddItem(heavy)

    local ok1 = CS.canLoadCorpseIntoCart(cart, 40.0)
    if not Assert.isTrue(ok1, "40kg corpse fits in remaining 50kg") then return false end

    local ok2 = CS.canLoadCorpseIntoCart(cart, 60.0)
    return Assert.isTrue(not ok2, "60kg corpse does NOT fit in remaining 50kg")
end

-- ============================================================================
-- handleLoadCorpseToCart — server handler happy path
-- ============================================================================

tests["handle_happy_path_grapple_body_via_id_lookup"] = function()
    -- C2: grapple-mode "body" kind resolves an IsoDeadBody by (sq, id).
    -- Client sends ghostKind="body" + ghostId/X/Y/Z; server finds the body,
    -- moves it into the cart, calls invalidateCorpse + sq:removeCorpse.
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)

    local corpseItem = makeCorpseItem({ weight = 55.0 })
    local deadBody = makeDeadBody({ square = sq, corpseItem = corpseItem, id = 501 })
    local bodiesList = { body = deadBody }
    bodiesList.size = function(self) return 1 end
    bodiesList.get  = function(self, i) return self.body end
    sq.getDeadBodys = function(self) return bodiesList end
    sq.removeCorpse = function(self, body, remote) self._removedBody = body end

    local player = makeDraggingPlayer(deadBody, sq)
    local cart = makeRegisteredCart({ capacity = 150 })
    player:getInventory():AddItem(cart)

    local ok = CS.handleLoadCorpseToCart(player, {
        cartId    = cart:getID(),
        ghostId   = 501,
        ghostKind = "body",
        ghostX    = 0, ghostY = 0, ghostZ = 0,
    })

    _G.instanceof = origIO

    local cartContainer = cart:getItemContainer()

    if not Assert.isTrue(ok, "handler returned success") then w:teardown(); return false end
    if not Assert.isTrue(cartContainer:contains(corpseItem),
        "corpse item is now in the cart container") then w:teardown(); return false end
    if not Assert.equal(deadBody._private.invalidated, 1,
        "deadBody:invalidateCorpse() called exactly once") then w:teardown(); return false end
    if not Assert.equal(sq._removedBody, deadBody,
        "sq:removeCorpse(body) called with the original body") then w:teardown(); return false end

    local addBroadcasts = w.network:count("sendAddItemToContainer")
    w:teardown()
    return Assert.equal(addBroadcasts, 1,
        "exactly one sendAddItemToContainer broadcast (no double-send)")
end

tests["handle_happy_path_grapple_zombie_via_onlineId_lookup"] = function()
    -- C2: grapple-mode resolves by zombie onlineId via cell.getZombieList
    -- (not by live grapple state). Happy path: client sends ghostKind="zombie"
    -- + ghostId=<onlineId>; server finds the zombie, calls becomeCorpseSilently.
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    sq.removeCorpse = function(self, body) self._removedBody = body end

    local deadBody = makeDeadBody({
        square = sq,
        corpseItem = makeCorpseItem({ weight = 70.0 }),
    })
    local living = makeLivingGrappled({ square = sq, deadBody = deadBody })
    -- Zombie lookup needs an onlineId + cell's zombie list to contain it.
    living.getOnlineID = function(self) return 77 end
    living.isReanimatedForGrappleOnly = function(self) return true end
    living.getCurrentSquare = function(self) return sq end

    -- Mock cell.getZombieList to contain our zombie.
    local origGetCell = _G.getCell
    local zomList = {}
    zomList.size = function(self) return 1 end
    zomList.get  = function(self, i) return living end
    _G.getCell = function()
        return {
            getZombieList = function(self) return zomList end,
            getGridSquare = function(self, x, y, z) return (x == 0 and y == 0 and z == 0) and sq or nil end,
        }
    end

    local player = makeDraggingPlayer(living, sq)
    local cart = makeRegisteredCart({ capacity = 150 })
    player:getInventory():AddItem(cart)

    local ok = CS.handleLoadCorpseToCart(player, {
        cartId    = cart:getID(),
        ghostId   = 77,
        ghostKind = "zombie",
        ghostX    = 0, ghostY = 0, ghostZ = 0,
    })

    _G.instanceof = origIO
    _G.getCell = origGetCell
    w:teardown()

    if not Assert.isTrue(ok, "handler returned success") then return false end
    if not Assert.equal(living._becomeCorpseSilentlyCount, 1,
        "becomeCorpseSilently called exactly once on living target") then return false end
    return Assert.isTrue(cart:getItemContainer():contains(deadBody:getItem()),
        "corpse item landed in cart")
end

tests["handle_accepts_load_even_without_live_dragging_state_C2"] = function()
    -- C2 regression: MP race — client released grapple locally + sent
    -- server command; server's replicated grapple state may already read
    -- isDraggingCorpse()=false by the time the handler runs. Previously
    -- that silently failed; C2 removes the live-state check entirely and
    -- resolves by client-supplied id. This test uses GRAPPLE mode (not
    -- direct) with a body-kind payload — exactly the path the old check
    -- would have bailed on.
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)

    local corpseItem = makeCorpseItem({ weight = 55.0 })
    local deadBody = makeDeadBody({ square = sq, corpseItem = corpseItem, id = 601 })
    -- Body lookup by coords + id for ghostKind="body" branch.
    local bodiesList = { body = deadBody }
    bodiesList.size = function(self) return 1 end
    bodiesList.get  = function(self, i) return self.body end
    sq.getDeadBodys = function(self) return bodiesList end
    sq.removeCorpse = function(self, body) end

    local player = makeDraggingPlayer(deadBody, sq)
    -- Simulate post-release state: isDraggingCorpse is false, getGrapplingTarget is nil.
    player.isDraggingCorpse = function(self) return false end
    player.getGrapplingTarget = function(self) return nil end

    local cart = makeRegisteredCart({ capacity = 150 })
    player:getInventory():AddItem(cart)

    local ok = CS.handleLoadCorpseToCart(player, {
        cartId    = cart:getID(),
        -- mode defaults to "grapple" — the path whose isDraggingCorpse
        -- check C2 removed
        ghostId   = 601,
        ghostKind = "body",
        ghostX    = 0, ghostY = 0, ghostZ = 0,
    })

    _G.instanceof = origIO
    local contains = cart:getItemContainer():contains(corpseItem)
    w:teardown()

    if not Assert.isTrue(ok,
        "handler succeeds in GRAPPLE mode even though isDraggingCorpse()=false — " ..
        "C2 removes the live-state dependency, resolution uses client-supplied id")
    then return false end
    return Assert.isTrue(contains, "corpse item landed in cart")
end

-- ============================================================================
-- handleLoadCorpseToCart — gates + failure modes
-- ============================================================================

-- handle_rejects_when_not_dragging: REMOVED by C2 (2026-04-24).
-- The handler no longer short-circuits on !isDraggingCorpse. Instead,
-- resolution is by client-supplied id — which means a client that
-- released grapple before the server command landed still succeeds.
-- The new test `handle_accepts_load_even_without_live_dragging_state_C2`
-- above locks the opposite invariant.

tests["handle_rejects_when_cart_not_found"] = function()
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    local deadBody = makeDeadBody({ square = sq })
    local player = makeDraggingPlayer(deadBody, sq)
    -- No cart in inventory, no cart on ground.

    local ok = CS.handleLoadCorpseToCart(player, { cartId = 99999 })

    _G.instanceof = origIO
    w:teardown()
    return Assert.isTrue(not ok, "handler returned false when cart absent")
end

tests["handle_rejects_over_capacity_and_keeps_grapple"] = function()
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    sq.removeCorpse = function(self, body) self._removedBody = body end

    -- Handler pre-gates with vanilla's static IsoGameCharacter.getWeightAsCorpse
    -- (20kg in B42). Stub it into the handler's global so the gate resolves to
    -- a value we control — a cart smaller than that guarantees rejection.
    local origIGC = _G.IsoGameCharacter
    _G.IsoGameCharacter = { getWeightAsCorpse = function() return 20.0 end }

    local deadBody = makeDeadBody({
        square = sq,
        corpseItem = makeCorpseItem({ weight = 80.0 }),
    })
    local player = makeDraggingPlayer(deadBody, sq)
    local cart = makeRegisteredCart({ capacity = 10 })  -- 10kg cart, 20kg gate
    player:getInventory():AddItem(cart)

    local ok = CS.handleLoadCorpseToCart(player, { cartId = cart:getID() })

    local grappleable = player:getGrappleable()
    local containsCorpse = cart:getItemContainer():contains(deadBody:getItem())
    _G.instanceof = origIO
    _G.IsoGameCharacter = origIGC
    w:teardown()

    if not Assert.isTrue(not ok, "handler returned false — over capacity") then return false end
    if not Assert.isTrue(not containsCorpse, "cart still empty") then return false end
    if not Assert.equal(deadBody._private.invalidated, 0,
        "deadBody NOT invalidated on rejection") then return false end
    return Assert.equal(grappleable.letGoCount, 0,
        "grapple NOT released — player still holds the body, can try another cart")
end

tests["handle_rejects_nil_args"] = function()
    local player = F.player()
    local ok1 = CS.handleLoadCorpseToCart(player, nil)
    if not Assert.isTrue(not ok1, "nil args rejected") then return false end
    local ok2 = CS.handleLoadCorpseToCart(player, {})
    if not Assert.isTrue(not ok2, "empty args rejected") then return false end
    local ok3 = CS.handleLoadCorpseToCart(nil, { cartId = 123 })
    return Assert.isTrue(not ok3, "nil player rejected")
end

-- ============================================================================
-- In-flight guard (double-perform dupe prevention)
-- ============================================================================
-- If the same player sends loadCorpseToCart twice while the first call is
-- still executing, the second call must bail before any mutation. Proves
-- V4-style dupe (double-perform over same logical op) is impossible.

tests["handle_in_flight_guard_rejects_reentry"] = function()
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    sq.removeCorpse = function(self, body) self._removedBody = body end

    local deadBody = makeDeadBody({ square = sq })
    local player = makeDraggingPlayer(deadBody, sq)
    local cart = makeRegisteredCart()
    player:getInventory():AddItem(cart)

    local onlineId = player:getOnlineID()
    -- Manually seed the in-flight flag to simulate being mid-call.
    CS._inFlight[onlineId] = true

    local ok = CS.handleLoadCorpseToCart(player, { cartId = cart:getID() })

    local containsCorpse = cart:getItemContainer():contains(deadBody:getItem())
    CS._inFlight[onlineId] = nil  -- cleanup
    _G.instanceof = origIO
    w:teardown()

    if not Assert.isTrue(not ok, "re-entry returned false") then return false end
    return Assert.isTrue(not containsCorpse, "cart unchanged — no mutation on re-entry")
end

tests["handle_in_flight_cleared_after_success"] = function()
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    sq.removeCorpse = function(self, body) self._removedBody = body end

    local deadBody = makeDeadBody({ square = sq })
    local player = makeDraggingPlayer(deadBody, sq)
    local cart = makeRegisteredCart()
    player:getInventory():AddItem(cart)
    local onlineId = player:getOnlineID()

    CS.handleLoadCorpseToCart(player, { cartId = cart:getID() })

    local stillFlagged = CS._inFlight[onlineId]
    _G.instanceof = origIO
    w:teardown()
    return Assert.isTrue(not stillFlagged,
        "in-flight flag cleared — player can load a new corpse next call")
end

tests["handle_in_flight_cleared_after_gate_rejection"] = function()
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    local deadBody = makeDeadBody({
        square = sq,
        corpseItem = makeCorpseItem({ weight = 999.0 }),
    })
    local player = makeDraggingPlayer(deadBody, sq)
    local cart = makeRegisteredCart({ capacity = 10 })
    player:getInventory():AddItem(cart)
    local onlineId = player:getOnlineID()

    CS.handleLoadCorpseToCart(player, { cartId = cart:getID() })

    local stillFlagged = CS._inFlight[onlineId]
    _G.instanceof = origIO
    w:teardown()
    return Assert.isTrue(not stillFlagged,
        "in-flight flag cleared even after gate rejection (so player can retry)")
end

-- ============================================================================
-- resolveDeadBody — direct coverage of the kind-dispatch helper
-- ============================================================================

tests["resolveDeadBody_deadbody_returns_same"] = function()
    local origIO = patchInstanceof()
    local body = makeDeadBody()
    local resolved = CS._resolveDeadBody(body)
    _G.instanceof = origIO
    return Assert.equal(resolved, body, "IsoDeadBody resolves to itself")
end

tests["resolveDeadBody_living_calls_becomeCorpseSilently"] = function()
    local origIO = patchInstanceof()
    local deadBody = makeDeadBody()
    local living = makeLivingGrappled({ deadBody = deadBody })
    local resolved = CS._resolveDeadBody(living)
    _G.instanceof = origIO
    if not Assert.equal(resolved, deadBody, "resolved to freshly-spawned body") then return false end
    return Assert.equal(living._becomeCorpseSilentlyCount, 1,
        "becomeCorpseSilently invoked exactly once")
end

tests["resolveDeadBody_nil_returns_nil"] = function()
    return Assert.isNil(CS._resolveDeadBody(nil), "nil target → nil body")
end

tests["resolveDeadBody_unknown_type_returns_nil"] = function()
    local origIO = patchInstanceof()
    local weird = { _type = "UnknownGrappleable" }
    local resolved = CS._resolveDeadBody(weird)
    _G.instanceof = origIO
    return Assert.isNil(resolved, "unknown grappleable type → nil body (safe fallback)")
end

-- ============================================================================
-- reconcile(cart, targetSq) — per-cart modData state tracking
-- ============================================================================
-- After the v2.1.5 stink-strip, reconcile is pure modData accounting. It
-- doesn't emit to vanilla CorpseCount anymore (CorpseCount isn't even
-- Lua-exposed). These tests lock the modData state machine: cart's
-- (regSq, regCount) reflects current container contents + last seen tile.

--- Make a cart whose inner container has `n` corpse items in it.
local function makeCartWithCorpses(n, cartOpts)
    local cart = makeRegisteredCart(cartOpts)
    local c = cart:getItemContainer()
    for i = 1, n do c:AddItem(makeCorpseItem({ id = 7000 + i })) end
    return cart
end

--- Read the cart's reconcile-state modData. Returns (sq, count) where sq
--- is the {x,y,z} table or nil.
local function readReconcileState(cart)
    local md = cart:getModData()
    return md[CS._RECONCILE_MOD_KEY_SQ], md[CS._RECONCILE_MOD_KEY_COUNT]
end

tests["reconcile_first_register_writes_modData"] = function()
    local cart = makeCartWithCorpses(3)
    local sq = { getX = function() return 10 end, getY = function() return 20 end, getZ = function() return 0 end }

    CS.reconcile(cart, sq)

    local stamped, count = readReconcileState(cart)
    if not Assert.isTrue(stamped ~= nil, "regSq stamped") then return false end
    if not Assert.equal(stamped.x, 10, "regSq.x") then return false end
    if not Assert.equal(stamped.y, 20, "regSq.y") then return false end
    if not Assert.equal(stamped.z, 0,  "regSq.z") then return false end
    return Assert.equal(count, 3, "regCount = 3 corpses in cart")
end

tests["reconcile_is_idempotent_state"] = function()
    local cart = makeCartWithCorpses(2)
    local sq = { getX = function() return 5 end, getY = function() return 5 end, getZ = function() return 0 end }

    CS.reconcile(cart, sq)
    local sq1, n1 = readReconcileState(cart)
    CS.reconcile(cart, sq)
    local sq2, n2 = readReconcileState(cart)

    if not Assert.equal(n1, 2, "first reconcile sets count=2") then return false end
    if not Assert.equal(n2, 2, "second reconcile keeps count=2 (idempotent)") then return false end
    return Assert.isTrue(sq1.x == sq2.x and sq1.y == sq2.y, "regSq unchanged across calls")
end

tests["reconcile_updates_count_when_container_changes"] = function()
    local cart = makeCartWithCorpses(2)
    local sq = { getX = function() return 8 end, getY = function() return 9 end, getZ = function() return 0 end }

    CS.reconcile(cart, sq)
    local _, before = readReconcileState(cart)

    cart:getItemContainer():AddItem(makeCorpseItem({ id = 9999 }))
    CS.reconcile(cart, sq)
    local _, after = readReconcileState(cart)

    if not Assert.equal(before, 2, "pre-add count") then return false end
    return Assert.equal(after, 3, "post-add count tracks current container state")
end

tests["reconcile_swap_overwrites_regSq_on_tile_change"] = function()
    local cart = makeCartWithCorpses(2)
    local sqA = { getX = function() return 1 end, getY = function() return 1 end, getZ = function() return 0 end }
    local sqB = { getX = function() return 5 end, getY = function() return 5 end, getZ = function() return 0 end }

    CS.reconcile(cart, sqA)
    CS.reconcile(cart, sqB)
    local stamped, count = readReconcileState(cart)

    if not Assert.equal(stamped.x, 5, "regSq overwritten to new tile X") then return false end
    if not Assert.equal(stamped.y, 5, "regSq overwritten to new tile Y") then return false end
    return Assert.equal(count, 2, "regCount preserved across tile swap")
end

tests["reconcile_nil_target_clears_modData"] = function()
    -- Cart-broke / unregister path: reconcile(cart, nil) clears state.
    local cart = makeCartWithCorpses(3)
    local sq = { getX = function() return 4 end, getY = function() return 4 end, getZ = function() return 0 end }

    CS.reconcile(cart, sq)
    CS.reconcile(cart, nil)
    local stamped, count = readReconcileState(cart)

    if not Assert.isNil(stamped, "regSq cleared") then return false end
    return Assert.equal(count, 0, "regCount cleared to 0")
end

tests["reconcile_handles_empty_cart"] = function()
    local cart = makeRegisteredCart()
    local sq = { getX = function() return 2 end, getY = function() return 2 end, getZ = function() return 0 end }

    CS.reconcile(cart, sq)
    local stamped, count = readReconcileState(cart)

    if not Assert.equal(count, 0, "empty cart → count 0") then return false end
    return Assert.isTrue(stamped ~= nil, "regSq still stamped for empty-cart at-tile case")
end

tests["reconcile_tracks_count_decrease"] = function()
    local cart = makeCartWithCorpses(3)
    local sq = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }

    CS.reconcile(cart, sq)
    local cont = cart:getItemContainer()
    local items = cont:getItems()
    local toRemove = { items:get(0), items:get(1) }
    for _, it in ipairs(toRemove) do cont:Remove(it) end
    CS.reconcile(cart, sq)
    local _, count = readReconcileState(cart)

    return Assert.equal(count, 1, "after external removal of 2, regCount = 1")
end

tests["reconcile_survives_toctou_iteration_error"] = function()
    -- countCorpseItemsIn's pcall catches a mid-iteration error. The reconcile
    -- call must NOT crash and must return gracefully. We simulate by making
    -- getItems() throw.
    local cart = makeRegisteredCart()
    cart:getItemContainer().getItems = function(self) error("simulated TOCTOU") end

    local ok = pcall(function()
        CS.reconcile(cart, {
            getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
        })
    end)

    return Assert.isTrue(ok, "reconcile doesn't crash when items iteration throws")
end

-- ============================================================================
-- H3: byteData round-trip + reconcile state persistence
-- ============================================================================
-- Vanilla InventoryItem.save/load IS confirmed to persist `byteData` (length-
-- prefixed write at line 1675-1681, length-prefixed read at line 2002-2011 of
-- decompiled InventoryItem.java). These tests lock complementary invariants:
--
--   1. handleLoadCorpseToCart leaves the corpse item in the cart with a
--      non-nil byteData — i.e. our pipeline never strips the serialization.
--   2. reconcile state in modData survives a simulated save/load cycle — when
--      modData is dumped to a table and restored, lastSq + lastCount match.
--
-- Live save/load (running PZ save() across game sessions) is verified
-- manually via tools/probe-corpse-saveload.lua.

tests["loaded_corpse_item_keeps_byteData_in_cart"] = function()
    local origIO = patchInstanceof()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    sq.removeCorpse = function(self, body) end

    local corpseItem = makeCorpseItem({ id = 800 })
    -- Stamp byteData onto the mock — vanilla deadBody:getItem() does this
    -- internally via storeInByteData. Our mock's getItem returns this item.
    local mockBytes = { _id = "fake-buffer-handle" }
    corpseItem._byteData = mockBytes
    corpseItem.getByteData = function(self) return self._byteData end

    local deadBody = makeDeadBody({ square = sq, corpseItem = corpseItem, id = 800 })
    local bodiesList = { body = deadBody }
    bodiesList.size = function(self) return 1 end
    bodiesList.get  = function(self, i) return self.body end
    sq.getDeadBodys = function(self) return bodiesList end

    local player = makeDraggingPlayer(deadBody, sq)
    local cart = makeRegisteredCart({ capacity = 150 })
    player:getInventory():AddItem(cart)

    CS.handleLoadCorpseToCart(player, {
        cartId    = cart:getID(),
        ghostId   = 800,
        ghostKind = "body",
        ghostX    = 0, ghostY = 0, ghostZ = 0,
    })

    _G.instanceof = origIO

    -- Find the corpse item in the cart and verify its byteData is intact.
    local items = cart:getItemContainer():getItems()
    local foundByteData = nil
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and CS.isCorpseItem(it) then
            foundByteData = it.getByteData and it:getByteData() or nil
        end
    end
    w:teardown()

    if not Assert.isTrue(foundByteData ~= nil,
        "corpse item in cart has non-nil byteData (our load pipeline didn't strip it)") then return false end
    return Assert.equal(foundByteData, mockBytes,
        "byteData is the SAME object — never copied or replaced by our code")
end

tests["reconcile_state_survives_modData_serialize_round_trip"] = function()
    -- Simulate save/load by snapshotting modData → re-applying on a fresh
    -- VM. After restore, reconcile sees the prior state and treats a
    -- same-tile/same-count call as a no-op (modData unchanged).
    local cart = makeCartWithCorpses(4)
    local sq = { getX = function() return 12 end, getY = function() return 34 end, getZ = function() return 0 end }

    CS.reconcile(cart, sq)
    local md = cart:getModData()
    local snapshotSq    = { x = md[CS._RECONCILE_MOD_KEY_SQ].x,
                            y = md[CS._RECONCILE_MOD_KEY_SQ].y,
                            z = md[CS._RECONCILE_MOD_KEY_SQ].z }
    local snapshotCount = md[CS._RECONCILE_MOD_KEY_COUNT]

    -- Wipe + re-apply (simulate save→load round-trip).
    md[CS._RECONCILE_MOD_KEY_SQ]    = nil
    md[CS._RECONCILE_MOD_KEY_COUNT] = nil
    md[CS._RECONCILE_MOD_KEY_SQ]    = snapshotSq
    md[CS._RECONCILE_MOD_KEY_COUNT] = snapshotCount

    -- Bootstrap reconcile (simulating OnGameStart). Same tile, same
    -- container contents → modData stays at (sq, 4).
    CS.reconcile(cart, sq)
    local stamped = md[CS._RECONCILE_MOD_KEY_SQ]
    local count   = md[CS._RECONCILE_MOD_KEY_COUNT]

    if not Assert.equal(count, 4, "regCount preserved across save/load + reconcile") then return false end
    return Assert.isTrue(stamped.x == 12 and stamped.y == 34,
        "regSq preserved across save/load + reconcile")
end

-- ============================================================================
-- Rot — deathTime stamp/restore + purgeRottedCorpses
-- ============================================================================
-- Vanilla rot timeline:
--   skeletonAt = SandboxOptions.hoursForCorpseRemoval (default 216)
--   removalAt  = skeletonAt + skeletonAt/3            (default 288)
-- Stored corpses freeze in time (byteData is opaque to vanilla updateBodies).
-- We stamp the body's deathTime onto the corpse item's modData on load, and
-- on unload we restore via setDeathTime so vanilla's ticker resumes correctly.
-- Past removalAt, vanilla would have despawned the body — purgeRottedCorpses
-- mirrors that.

--- Install a sandbox + GameTime fixture for rot tests. Returns a handle with
--- :setNow(hours) to simulate world time advancement, and :restore() teardown.
local function installRotFixture(opts)
    opts = opts or {}
    local hoursForRemoval = opts.hoursForRemoval or 216  -- vanilla default
    local startNow = opts.startNow or 0

    local prevSandbox = _G.SandboxOptions
    local prevGameTime = _G.GameTime
    local now = startNow

    -- Match production: getRotThresholds uses
    --   SandboxOptions.instance:getOptionByName("HoursForCorpseRemoval"):getValue()
    -- Direct-field access (.hoursForCorpseRemoval) doesn't work for real Java
    -- options exposed to Lua — bug fixed 2026-04-25 after the live probe
    -- proved no world was ever seeing the sandbox value.
    local opt = { getValue = function(self) return hoursForRemoval end }
    _G.SandboxOptions = {
        instance = {
            getOptionByName = function(self, name)
                if name == "HoursForCorpseRemoval" then return opt end
                return nil
            end,
        },
    }
    _G.GameTime = {
        getInstance = function(self)
            return { getWorldAgeHours = function(self2) return now end }
        end,
    }
    return {
        setNow  = function(h) now = h end,
        restore = function()
            _G.SandboxOptions = prevSandbox
            _G.GameTime       = prevGameTime
        end,
    }
end

--- Make a corpse item that supports modData (Lua-table backing).
local function makeRotCorpseItem(opts)
    local it = makeCorpseItem(opts)
    it._modData = it._modData or {}
    it.getModData = function(self) return self._modData end
    return it
end

--- Make a deadbody mock with getDeathTime/setDeathTime support.
local function makeRotDeadBody(opts)
    opts = opts or {}
    local body = makeDeadBody(opts)
    body._deathTime = opts.deathTime or 0
    body.getDeathTime = function(self) return self._deathTime end
    body.setDeathTime = function(self, t) self._deathTime = t end
    return body
end

tests["stampDeathTime_writes_modData_from_body"] = function()
    local rot = installRotFixture({ startNow = 100 })
    local body = makeRotDeadBody({ deathTime = 50 })
    local item = makeRotCorpseItem()

    CS.stampDeathTime(item, body)
    rot.restore()

    return Assert.equal(item:getModData()[CS._CORPSE_DEATHTIME_KEY], 50,
        "stampDeathTime copies body:getDeathTime() onto item modData")
end

tests["effectiveAge_is_now_minus_deathTime"] = function()
    local rot = installRotFixture({ startNow = 100 })
    local item = makeRotCorpseItem()
    item:getModData()[CS._CORPSE_DEATHTIME_KEY] = 30
    local age = CS.effectiveAge(item)
    rot.restore()
    return Assert.equal(age, 70, "effective_age = currentWorldHours(100) - deathTime(30)")
end

tests["effectiveAge_returns_zero_when_unstamped"] = function()
    -- Legacy corpse items (loaded by pre-rot version) have no stamp.
    -- Treat as fresh — better than guessing wrong.
    local rot = installRotFixture({ startNow = 1000 })
    local item = makeRotCorpseItem()
    local age = CS.effectiveAge(item)
    rot.restore()
    return Assert.equal(age, 0, "no stamp → fresh-treatment, age 0")
end

tests["restoreDeathTime_sets_body_deathTime_from_stamp"] = function()
    local rot = installRotFixture()
    local item = makeRotCorpseItem()
    item:getModData()[CS._CORPSE_DEATHTIME_KEY] = 75
    local body = makeRotDeadBody({ deathTime = 0 })  -- fresh from byteData

    CS.restoreDeathTime(item, body)
    rot.restore()

    return Assert.equal(body:getDeathTime(), 75,
        "restored body's deathTime matches stamp — vanilla rot ticker resumes correctly")
end

tests["restoreDeathTime_noop_when_unstamped"] = function()
    local rot = installRotFixture()
    local item = makeRotCorpseItem()  -- no stamp
    local body = makeRotDeadBody({ deathTime = 999 })

    CS.restoreDeathTime(item, body)
    rot.restore()

    return Assert.equal(body:getDeathTime(), 999,
        "no stamp → body's deathTime untouched (preserves byteData value)")
end

tests["purgeRottedCorpses_removes_past_skeletonAt"] = function()
    -- Threshold = skeletonAt (= hoursForRemoval). Bodies past this can't
    -- survive vanilla's despawn tick anyway, and we can't render skeletons
    -- (setSkeleton isn't Lua-exposed). Purging at skeletonAt matches the
    -- unload silent-drop boundary in CartTransferInterceptor.
    local rot = installRotFixture({ hoursForRemoval = 216, startNow = 500 })
    -- skeletonAt = 216. Anything with deathTime <= 500-216 = 284 is purged.

    local cart = makeRegisteredCart({ capacity = 500 })
    local cont = cart:getItemContainer()

    local fresh   = makeRotCorpseItem({ id = 1 })
    fresh:getModData()[CS._CORPSE_DEATHTIME_KEY] = 400  -- age 100, fresh

    local rotting = makeRotCorpseItem({ id = 2 })
    rotting:getModData()[CS._CORPSE_DEATHTIME_KEY] = 300  -- age 200, mid-rot, kept (under skeletonAt)

    local skeletonAge = makeRotCorpseItem({ id = 3 })
    skeletonAge:getModData()[CS._CORPSE_DEATHTIME_KEY] = 250  -- age 250, PAST skeletonAt(216) → purged

    local gone1  = makeRotCorpseItem({ id = 4 })
    gone1:getModData()[CS._CORPSE_DEATHTIME_KEY] = 100  -- age 400, way past

    local gone2  = makeRotCorpseItem({ id = 5 })
    gone2:getModData()[CS._CORPSE_DEATHTIME_KEY] = 0   -- age 500, ancient

    cont:AddItem(fresh)
    cont:AddItem(rotting)
    cont:AddItem(skeletonAge)
    cont:AddItem(gone1)
    cont:AddItem(gone2)

    local purged = CS.purgeRottedCorpses(cart)
    rot.restore()

    if not Assert.equal(purged, 3, "3 items past skeletonAt purged") then return false end
    if not Assert.isTrue(cont:contains(fresh),    "fresh corpse kept") then return false end
    if not Assert.isTrue(cont:contains(rotting),  "mid-rot corpse kept (under skeletonAt)") then return false end
    if not Assert.isTrue(not cont:contains(skeletonAge), "post-skeletonAt corpse purged") then return false end
    if not Assert.isTrue(not cont:contains(gone1), "ancient corpse purged (id=4)") then return false end
    return Assert.isTrue(not cont:contains(gone2), "ancient corpse purged (id=5)")
end

tests["purgeRottedCorpses_skips_when_sandbox_says_never_decay"] = function()
    -- hoursForRemoval = 0 → vanilla "corpses never decay" → we keep everything.
    local rot = installRotFixture({ hoursForRemoval = 0, startNow = 1e9 })
    local cart = makeRegisteredCart({ capacity = 500 })
    local cont = cart:getItemContainer()
    local ancient = makeRotCorpseItem({ id = 99 })
    ancient:getModData()[CS._CORPSE_DEATHTIME_KEY] = 0  -- age = 1 billion hours
    cont:AddItem(ancient)

    local purged = CS.purgeRottedCorpses(cart)
    rot.restore()

    if not Assert.equal(purged, 0, "sandbox=0 short-circuits the purge entirely") then return false end
    return Assert.isTrue(cont:contains(ancient),
        "ancient corpse retained when sandbox 'never decay' is set")
end

tests["purgeRottedCorpses_ignores_non_corpse_items"] = function()
    -- Non-corpse items in the cart (e.g. loot the player threw in) must NOT
    -- be touched by the rot purge regardless of whether they have modData.
    local rot = installRotFixture({ hoursForRemoval = 216, startNow = 500 })
    local cart = makeRegisteredCart({ capacity = 500 })
    local cont = cart:getItemContainer()
    local loot = F.item({ fullType = "Base.Plank", weight = 1.0 })
    cont:AddItem(loot)

    local purged = CS.purgeRottedCorpses(cart)
    rot.restore()

    if not Assert.equal(purged, 0, "no corpses in cart → nothing purged") then return false end
    return Assert.isTrue(cont:contains(loot), "non-corpse items left untouched")
end

tests["handler_stamps_deathTime_on_load"] = function()
    -- Full handler integration: handleLoadCorpseToCart should stamp the
    -- live body's deathTime onto the corpse item before any other handler
    -- side effects (broadcast, removeCorpse, invalidate).
    local origIO = patchInstanceof()
    local rot = installRotFixture({ startNow = 1000 })
    local w = F.world()
    local sq = w:square(0, 0, 0)
    sq.removeCorpse = function() end

    local corpseItem = makeRotCorpseItem({ weight = 60.0 })
    local deadBody = makeRotDeadBody({
        square      = sq,
        corpseItem  = corpseItem,
        deathTime   = 800,  -- 200h old at the moment of load
        id          = 777,
    })
    local bodiesList = { body = deadBody }
    bodiesList.size = function(self) return 1 end
    bodiesList.get  = function(self, i) return self.body end
    sq.getDeadBodys = function(self) return bodiesList end

    local player = makeDraggingPlayer(deadBody, sq)
    local cart = makeRegisteredCart({ capacity = 500 })
    player:getInventory():AddItem(cart)

    local ok = CS.handleLoadCorpseToCart(player, {
        cartId    = cart:getID(),
        ghostId   = 777,
        ghostKind = "body",
        ghostX    = 0, ghostY = 0, ghostZ = 0,
    })

    _G.instanceof = origIO
    rot.restore()
    w:teardown()

    if not Assert.isTrue(ok, "handler succeeded") then return false end
    return Assert.equal(corpseItem:getModData()[CS._CORPSE_DEATHTIME_KEY], 800,
        "deathTime(800) stamped onto corpse item modData by handler — " ..
        "rot ticker can resume on unload via setDeathTime")
end

return tests
