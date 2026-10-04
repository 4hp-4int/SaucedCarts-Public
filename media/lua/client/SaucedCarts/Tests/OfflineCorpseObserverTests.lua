--[[
    SaucedCarts — Corpse / cart cross-VM observer tests
    ====================================================

    Locks the OBSERVABLE side of corpse + cart mutations. For each mutation
    a player can perform (load, unload, ghost-cleanup), we verify two
    halves of the cross-VM contract:

      A) Server-side authoritative actions broadcast the right commands
         (captured via Network.enableTestMode()).
      B) Client-side handlers, when invoked with the captured payload,
         produce the expected local mutations.

    Together these prove: a remote client connected to the same dedi sees
    the same end-state after any mutation, without standing up a full
    PZTestKit.Sim. Vanilla item replication (cart contents, modData) and
    vanilla addCorpse/sendCorpse propagation are trusted (they're tested
    by PZ's own QA) — we just verify our side correctly drives them.

    Scope:
      * removeGhostCorpse broadcast (server) → ghost purge (client)
      * Cart→ground unload server-side path: silent-drop (no body broadcast)
        vs. fresh materialization (sendCorpse fires)
      * Load handler stamps deathTime modData (observable to client via
        vanilla item replication)

    This file complements OfflineCorpseStorageTests.lua: those test the
    handler in isolation; these test the cross-VM observer contract.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"
require "SaucedCarts/CartTransferInterceptor"
require "SaucedCarts/Network"
require "SaucedCarts/CorpseStorage"

local CS = SaucedCarts.CorpseStorage
local Net = SaucedCarts.Network

local TEST_CART_TYPE = "SaucedCarts.ObserverTestCart"
if not SaucedCarts.isRegistered(TEST_CART_TYPE) then
    SaucedCarts.registerCart(TEST_CART_TYPE, {
        name = "ObserverTestCart", capacity = 200,
        weightReduction = 50, runSpeedModifier = 0.85, conditionMax = 20,
    })
end

-- ============================================================================
-- FIXTURES (deliberately minimal — observers don't need full PZ surface)
-- ============================================================================

local function makeRegisteredCart(opts)
    opts = opts or {}
    local cart = F.item({
        id = opts.id, fullType = opts.fullType or TEST_CART_TYPE, weight = opts.weight or 2.0,
    })
    cart._type = "InventoryContainer"
    cart._innerContainer = F.container({
        containingItem = cart, typeName = "ShoppingCart",
        capacity = opts.capacity or 200,
    })
    cart.getItemContainer = function(self) return self._innerContainer end
    return cart
end

local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item.getFullType and (item:getFullType() or ""):find("^SaucedCarts%.") then
        return true
    end
    return origSafeIsCart(item)
end

local function makeCorpseItem(opts)
    opts = opts or {}
    local it = F.item({
        id = opts.id, fullType = opts.fullType or "Base.CorpseMale",
        weight = opts.weight or 60.0,
    })
    it.isHumanCorpse  = function(self)
        local ft = self:getFullType()
        return ft == "Base.CorpseMale" or ft == "Base.CorpseFemale"
    end
    it.isAnimalCorpse = function(self) return self:getFullType() == "Base.CorpseAnimal" end
    it._modData = it._modData or {}
    it.getModData = function(self) return self._modData end
    return it
end

local function makeDeadBody(opts)
    opts = opts or {}
    local priv = {
        id = opts.id or 4242,
        square = opts.square,
        invalidated = 0,
        corpseItem = opts.corpseItem or makeCorpseItem({ weight = 60 }),
        deathTime = opts.deathTime or 0,
    }
    local b = { _type = "IsoDeadBody", _private = priv }
    b.getID            = function(self) return priv.id end
    b.getItem          = function(self) return priv.corpseItem end
    b.getSquare        = function(self) return priv.square end
    b.getCurrentSquare = function(self) return priv.square end
    b.invalidateCorpse = function(self) priv.invalidated = priv.invalidated + 1 end
    b.getDeathTime     = function(self) return priv._private and priv.deathTime or priv.deathTime end
    b.setDeathTime     = function(self, t) priv.deathTime = t end
    return b
end

local function makeDraggingPlayer(target, square)
    local p = F.player({ square = square })
    p.isDraggingCorpse   = function(self) return true end
    p.getGrapplingTarget = function(self) return target end
    p.setDoGrappleLetGo  = function(self) end
    return p
end

local function patchInstanceof()
    local orig = _G.instanceof
    _G.instanceof = function(obj, t)
        if obj == nil then return false end
        if t == "IsoDeadBody"        and obj._type == "IsoDeadBody"        then return true end
        if t == "IsoZombie"          and obj._type == "IsoZombie"          then return true end
        if t == "IsoGameCharacter"   and obj._type == "IsoGameCharacter"   then return true end
        if t == "IsoPlayer"          and obj._type == "IsoPlayer"          then return true end
        if t == "InventoryItem"      and obj._type == "InventoryItem"      then return true end
        if t == "InventoryContainer" and obj._type == "InventoryContainer" then return true end
        if orig then return orig(obj, t) end
        return false
    end
    return orig
end

local function installSandbox(opts)
    opts = opts or {}
    local hoursForRemoval = opts.hoursForRemoval or 216
    local now = opts.now or 0
    local prevSb, prevGt = _G.SandboxOptions, _G.GameTime
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
            return { getWorldAgeHours = function() return now end }
        end,
    }
    return function()
        _G.SandboxOptions = prevSb
        _G.GameTime = prevGt
    end
end

local tests = {}

-- ============================================================================
-- A) removeGhostCorpse: server broadcasts → clients purge local ghost
-- ============================================================================

tests["server_load_handler_broadcasts_removeGhostCorpse_with_ghost_id"] = function()
    -- After loading via grapple-zombie path, the server fires
    -- removeGhostCorpse with the captured zombie onlineId so each client
    -- can purge its stale local IsoZombie wrapper.
    local origIO = patchInstanceof()
    local restoreSb = installSandbox({ now = 1000 })
    Net.enableTestMode()
    Net.clearCapturedMessages()

    local w = F.world()
    local sq = w:square(0, 0, 0)
    sq.removeCorpse = function(self, body) self._removed = body end

    local deadBody = makeDeadBody({
        square = sq, deathTime = 990, id = 7777,
        corpseItem = makeCorpseItem({ weight = 60.0 }),
    })

    -- Mock zombie (grapple wrapper) discoverable via cell.zombieList by onlineId.
    local zombie = {
        _type = "IsoZombie",
        getOnlineID = function() return 12345 end,
        isReanimatedForGrappleOnly = function() return true end,
        getCurrentSquare = function() return sq end,
        becomeCorpseSilently = function(self) return deadBody end,
    }
    local zomList = {}
    zomList.size = function() return 1 end
    zomList.get  = function() return zombie end

    local prevGetCell = _G.getCell
    _G.getCell = function()
        return {
            getZombieList = function() return zomList end,
            getGridSquare = function(self, x, y, z)
                return (x == 0 and y == 0 and z == 0) and sq or nil
            end,
        }
    end

    local player = makeDraggingPlayer(zombie, sq)
    local cart = makeRegisteredCart()
    player:getInventory():AddItem(cart)

    local ok = CS.handleLoadCorpseToCart(player, {
        cartId = cart:getID(), ghostId = 12345, ghostKind = "zombie",
        ghostX = 0, ghostY = 0, ghostZ = 0,
    })

    -- Read captured broadcasts. Select the ZOMBIE-kind purge explicitly: the
    -- handler now also emits a body-kind purge for the corpse it publishes at
    -- the load site, so "last removeGhostCorpse wins" would grab the wrong one.
    local broadcasts = Net.getCapturedBroadcasts()
    local removeGhostBroadcast = nil
    for _, b in ipairs(broadcasts) do
        if b.command == "removeGhostCorpse" and b.args.kind == "zombie" then
            removeGhostBroadcast = b
        end
    end

    Net.disableTestMode()
    _G.getCell = prevGetCell
    _G.instanceof = origIO
    restoreSb()
    w:teardown()

    if not Assert.isTrue(ok, "load handler succeeded") then return false end
    -- INVERTED 2026-08-29. The server used to broadcast a zombie-kind purge so
    -- every client would destroy its grapple wrapper. That wrapper is the id
    -- carrier vanilla needs to clean up each client's own stale body, so the
    -- broadcast was asking clients to break their own cleanup. It is gone.
    -- kind="body" is still broadcast (no wrapper, no vanilla carrier) and is
    -- covered by the body-purge tests below.
    return Assert.isTrue(removeGhostBroadcast == nil,
        "no zombie-kind purge is broadcast — vanilla owns wrapper cleanup")
end

--- Build a getCell() mock exposing one grapple-wrapper zombie plus an
--- optional stranded IsoDeadBody parked on a specific square.
---@return table env { removed, restore, ghostBody, removedRemote }
local function installGhostCell(opts)
    opts = opts or {}
    local env = { removed = { fromWorld = false, fromSquare = false } }

    local zombie = {
        _type = "IsoZombie",
        getOnlineID      = function() return opts.onlineId or 999 end,
        removeFromWorld  = function() env.removed.fromWorld = true end,
        removeFromSquare = function() env.removed.fromSquare = true end,
    }
    local zomList = { size = function() return 1 end, get = function() return zombie end }

    -- Stranded body sits on its OWN square, deliberately offset from the
    -- broadcast centre — the ghost is where the corpse was grabbed, not
    -- where the cart was, so the sweep has to actually sweep.
    local ghostSq
    if opts.bodyId then
        env.ghostBody = { _type = "IsoDeadBody", getID = function() return opts.bodyId end }
        local live = true
        ghostSq = {
            getDeadBodys = function()
                return {
                    size = function() return live and 1 or 0 end,
                    get  = function() return env.ghostBody end,
                }
            end,
            removeCorpse = function(self, b, bRemote)
                env.removedBody, env.removedRemote = b, bRemote
                live = false
            end,
        }
    end

    local prevGetCell = _G.getCell
    _G.getCell = function()
        return {
            getZombieList = function() return zomList end,
            getObjectList = function() return { remove = function() end } end,
            getGridSquare = function(self, x, y, z)
                if ghostSq and x == (opts.bodyX or 0) and y == (opts.bodyY or 0) and z == 0 then
                    return ghostSq
                end
                return nil
            end,
        }
    end
    env.restore = function() _G.getCell = prevGetCell end
    return env
end

tests["client_never_touches_the_grapple_wrapper"] = function()
    -- THE CONTRACT, as settled by live measurement 2026-08-29. We do not
    -- remove the grapple wrapper. Ever. Not synchronously, not on a deferral.
    --
    -- The wrapper carries the original body's ObjectID in its replicated
    -- reanimatedBodyId (IsoDeadBody.java:2045 -> NetworkZombieAI:182 ->
    -- ZombiePacket), and every client uses it to clean up its OWN stale copy
    -- via IsoDeadBody.removeDeadBody once the wrapper reaches
    -- ZombieOnGroundState (:56-57, :115-116). Destroying the wrapper destroys
    -- that carrier, so the body we were trying to clear gets stranded instead.
    --
    -- v2.1.16 tried to solve this with a 60-tick deferral. That did not make
    -- it safe, only less likely: across live runs the wrapper was sometimes
    -- gone by tick 60 and sometimes still present, so it was a race with a
    -- varying outcome. A dry run had BOTH clients still holding the wrapper at
    -- expiry — meaning the live purge would have destroyed the carrier on the
    -- observer, the one client that actually had a stale body.
    --
    -- Verified with the purge removed: nothing leaks. Server showed zero
    -- wrappers and zero bodies near the grab site; both players confirmed
    -- nothing visible. Vanilla clears the body AND retires the wrapper.
    --
    -- If this test fails, someone re-added the purge. Read the block in
    -- CorpseStorage.lua before "fixing" it.
    local env = installGhostCell({ onlineId = 999 })

    CS.handleRemoveGhostCorpse({ bodyId = 999, kind = "zombie",
        x = 0, y = 0, z = 0 })
    CS._flushGhostPurges()   -- production drains via Events.OnTick
    env.restore()

    if not Assert.isFalse(env.removed.fromWorld,
        "wrapper is never removed from the world") then return false end
    if not Assert.isFalse(env.removed.fromSquare,
        "wrapper is never removed from its square") then return false end
    return Assert.equal(#CS._pendingGhostPurges, 0,
        "and nothing is left queued against it")
end

tests["client_defers_regardless_of_extra_payload_fields"] = function()
    -- v2.1.16 briefly shipped an ObjectID-ish sweep driven by extra payload
    -- fields, dropped because IsoMovingObject.getID() is a per-VM counter and
    -- could never match cross-VM (see ROAD NOT TAKEN in CorpseStorage.lua).
    -- A server still sending those fields must not change client behavior:
    -- unknown keys are ignored and the deferral still governs.
    local env = installGhostCell({ onlineId = 999, bodyId = 555,
        bodyX = 103, bodyY = 98 })

    CS.handleRemoveGhostCorpse({ bodyId = 999, kind = "zombie",
        originalBodyId = 555, loadedBodyId = 557, x = 100, y = 100, z = 0 })

    local purgedEarly = env.removed.fromWorld
    CS._flushGhostPurges()
    env.restore()

    if not Assert.isTrue(purgedEarly == false,
        "stale id fields do not re-enable a synchronous wrapper purge") then return false end
    if not Assert.isTrue(env.removedBody == nil,
        "no body is removed by id — vanilla owns the grab-site ghost") then return false end
    return Assert.isFalse(env.removed.fromWorld,
        "and the wrapper is still not touched on the deferral either")
end

tests["client_deferral_survives_missing_zombie_at_expiry"] = function()
    -- By the time the timer expires vanilla may have removed the wrapper
    -- itself. Draining must be a safe no-op, not an error, and must not
    -- leave the entry stuck in the queue.
    local zomList = { size = function() return 0 end, get = function() return nil end }
    local prevGetCell = _G.getCell
    _G.getCell = function()
        return {
            getZombieList = function() return zomList end,
            getObjectList = function() return { remove = function() end } end,
            getGridSquare = function() return nil end,
        }
    end

    local ok = pcall(function()
        CS.handleRemoveGhostCorpse({ bodyId = 4242, kind = "zombie", x = 0, y = 0, z = 0 })
        CS._flushGhostPurges()
    end)
    local drained = #CS._pendingGhostPurges

    _G.getCell = prevGetCell

    if not Assert.isTrue(ok, "draining a vanished wrapper does not error") then return false end
    return Assert.equal(drained, 0, "queue is emptied even when the wrapper is already gone")
end

--- Build a getCell() mock with one square holding one body, where the body's
--- per-VM getID() and its network-stable ObjectID deliberately DISAGREE.
--- `appearsAfter` delays the body's arrival by N purge attempts, standing in
--- for an AddCorpseToMapPacket that has not been processed yet.
local function installBodyCell(opts)
    local env = { attempts = 0 }
    local live, appearsAfter = true, opts.appearsAfter or 0

    env.body = {
        _type = "IsoDeadBody",
        getID              = function() return opts.legacyId or -999 end,
        getObjectIDAsLong  = function() return opts.objectId end,
    }
    local sq = {
        getDeadBodys = function()
            env.attempts = env.attempts + 1
            local present = live and env.attempts > appearsAfter
            return {
                size = function() return present and 1 or 0 end,
                get  = function() return env.body end,
            }
        end,
        removeCorpse = function(self, b, bRemote)
            env.removedBody, env.removedRemote = b, bRemote
            live = false
        end,
    }

    local prevGetCell = _G.getCell
    _G.getCell = function()
        return {
            getZombieList = function()
                return { size = function() return 0 end, get = function() return nil end }
            end,
            getObjectList = function() return { remove = function() end } end,
            getGridSquare = function(self, x, y, z)
                return (x == 7 and y == 8 and z == 0) and sq or nil
            end,
        }
    end
    env.restore = function() _G.getCell = prevGetCell end
    return env
end

tests["client_body_purge_matches_object_id_not_per_vm_id"] = function()
    -- IsoMovingObject.getID() is a static per-VM counter (IsoMovingObject.java:
    -- 95, :161), so the server's id for a body means nothing on a client.
    -- ObjectID is the key vanilla itself uses for corpse packets and the one
    -- AddCorpseToMapPacket (:55, :85) stamps onto the client's copy.
    --
    -- Sensitivity: against the old getID()-only match this fails — the body's
    -- getID() is -999 and the broadcast carries 4321.
    local env = installBodyCell({ objectId = 4321, legacyId = -999 })

    CS.handleRemoveGhostCorpse({ bodyId = 4321, kind = "body", x = 7, y = 8, z = 0 })
    CS._flushGhostPurges()
    env.restore()

    if not Assert.equal(env.removedBody, env.body,
        "body matched by ObjectID and removed") then return false end
    return Assert.isTrue(env.removedRemote,
        "removed with bRemote=true — we are the end of the chain, no re-broadcast")
end

tests["client_body_purge_is_deferred_not_inline"] = function()
    -- The corpse being deleted is one the server published with sendCorpse a
    -- moment earlier. AddCorpseToMap travels on its own ordered channel and
    -- this command on another, so an inline attempt can run before the corpse
    -- exists locally. The purge therefore rides the same ~1s deferral the
    -- wrapper purge uses — long enough that the add has landed, without
    -- introducing a retry loop.
    local env = installBodyCell({ objectId = 4322, legacyId = -998 })

    CS.handleRemoveGhostCorpse({ bodyId = 4322, kind = "body", x = 7, y = 8, z = 0 })
    local removedInline = env.removedBody
    CS._flushGhostPurges()
    env.restore()

    if not Assert.isNil(removedInline,
        "nothing removed inline — the corpse may not have arrived yet") then return false end
    if not Assert.equal(env.removedBody, env.body,
        "removed once the deferral expires") then return false end
    return Assert.equal(#CS._pendingGhostPurges, 0, "queue drained after the attempt")
end

tests["client_body_purge_missing_target_drains_without_error"] = function()
    -- A corpse that never materializes locally (this client was never near the
    -- load site) is the common case, not a failure. One attempt, log the miss,
    -- drop the entry — it must not error and must not pin the queue.
    local env = installBodyCell({ objectId = 4323, legacyId = -997, appearsAfter = 9999 })

    local ok = pcall(function()
        CS.handleRemoveGhostCorpse({ bodyId = 4323, kind = "body", x = 7, y = 8, z = 0 })
        CS._flushGhostPurges()
    end)
    env.restore()

    if not Assert.isTrue(ok, "a missed purge does not error") then return false end
    if not Assert.isNil(env.removedBody, "nothing was removed") then return false end
    if not Assert.equal(env.attempts, 1,
        "exactly one attempt — no retry loop") then return false end
    return Assert.equal(#CS._pendingGhostPurges, 0, "entry dropped after its single attempt")
end

tests["client_body_purge_without_coords_is_a_safe_noop"] = function()
    -- Guard the enqueue path: a malformed payload must not queue an entry
    -- that can never resolve.
    local before = #CS._pendingGhostPurges
    local ok = pcall(function()
        CS.handleRemoveGhostCorpse({ bodyId = 4324, kind = "body" })
    end)
    if not Assert.isTrue(ok, "missing coords does not error") then return false end
    return Assert.equal(#CS._pendingGhostPurges, before,
        "nothing queued for a body purge with no square")
end

tests["client_receiving_removeGhostCorpse_with_unknown_id_is_safe_noop"] = function()
    -- Robustness: broadcast carrying an id no client knows about must
    -- not crash. Used to happen on late-joiners where the original zombie
    -- was never spawned client-side.
    local zomList = { size = function() return 0 end, get = function() return nil end }
    local prevGetCell = _G.getCell
    _G.getCell = function()
        return { getZombieList = function() return zomList end }
    end

    local ok = pcall(function()
        CS.handleRemoveGhostCorpse({ bodyId = 99999, kind = "zombie",
            x = 1, y = 2, z = 0 })
        -- Drain so the deferred entry can't bleed into a later test.
        CS._flushGhostPurges()
    end)

    _G.getCell = prevGetCell
    return Assert.isTrue(ok, "handler is no-op when zombie list is empty")
end

-- ============================================================================
-- B) Load handler stamps deathTime modData → client observes via item replication
-- ============================================================================

tests["server_load_stamps_deathTime_for_cross_vm_rot_observability"] = function()
    -- Stamp lives in InventoryItem modData → vanilla replicates the item
    -- to clients on AddItem broadcast. So the deathTime stamp set on the
    -- server's corpse-item is observable to remote clients without us
    -- broadcasting anything ourselves. Test: stamp value matches the
    -- live body's getDeathTime() at the moment of load.
    local origIO = patchInstanceof()
    local restoreSb = installSandbox({ now = 5000 })

    local w = F.world()
    local sq = w:square(0, 0, 0)
    sq.removeCorpse = function() end

    local corpseItem = makeCorpseItem({ id = 8001 })
    local deadBody = makeDeadBody({
        square = sq, corpseItem = corpseItem,
        deathTime = 4900, id = 8001,  -- 100h old at moment of load
    })
    local bodiesList = { body = deadBody }
    bodiesList.size = function() return 1 end
    bodiesList.get  = function() return deadBody end
    sq.getDeadBodys = function(self) return bodiesList end

    local player = makeDraggingPlayer(deadBody, sq)
    local cart = makeRegisteredCart({ capacity = 200 })
    player:getInventory():AddItem(cart)

    CS.handleLoadCorpseToCart(player, {
        cartId = cart:getID(), ghostId = 8001, ghostKind = "body",
        ghostX = 0, ghostY = 0, ghostZ = 0,
    })

    _G.instanceof = origIO
    restoreSb()
    w:teardown()

    local stamped = corpseItem:getModData()[CS._CORPSE_DEATHTIME_KEY]
    if not Assert.isTrue(stamped ~= nil,
        "deathTime stamp written to modData for cross-VM observation") then return false end
    return Assert.equal(stamped, 4900,
        "stamp matches body's deathTime — clients see same effective_age computation")
end

-- ============================================================================
-- C) Cart→ground unload: server-side observer behavior
-- ============================================================================
-- For these we directly invoke performCartTransfer and inspect the side
-- effects (sendCorpse capture, halo capture, item removal) to verify
-- what a remote client would observe.

local function makeCorpseItemWithStamp(opts)
    opts = opts or {}
    local it = makeCorpseItem(opts)
    if opts.stampedDeathTime then
        it:getModData()[CS._CORPSE_DEATHTIME_KEY] = opts.stampedDeathTime
    end
    -- Mock vanilla rematerialize methods so performCartTransfer can run.
    it.loadCorpseFromByteData = opts.loadCorpseFromByteData or function(self, dropSq)
        return makeDeadBody({ square = dropSq, id = self:getID() })
    end
    it.createAndStoreDefaultDeadBody = opts.createAndStoreDefaultDeadBody
        or function(self, dropSq) return makeDeadBody({ square = dropSq, id = self:getID() }) end
    return it
end

tests["unload_past_skeletonAt_silent_drops_no_addCorpse_no_sendCorpse"] = function()
    -- Past sandbox HoursForCorpseRemoval, vanilla updateBodies would
    -- despawn the rematerialized body anyway → we silent-drop. Observable
    -- contract: no addCorpse on the dropSquare, no sendCorpse broadcast.
    local restoreSb = installSandbox({ hoursForRemoval = 24, now = 100 })

    local sq = F.square(5, 5, 0)
    sq.addCorpse = function(self, body, bRemote) self._addedBody = body end

    local item = makeCorpseItemWithStamp({
        id = 9001, stampedDeathTime = 70,  -- effective_age = 30h, past skeletonAt=24
    })
    -- Track sendCorpse / sendRemoveItemFromContainer call counts.
    local sendCorpseCount = 0
    local prevSendCorpse = _G.sendCorpse
    _G.sendCorpse = function(body) sendCorpseCount = sendCorpseCount + 1 end

    -- Build a faux src container holding the item.
    local src = F.container({ typeName = "TestSrc" })
    src:AddItem(item)
    -- Wrap the src as a cart's inner container so containerToCart resolves.
    local cart = makeRegisteredCart({ id = 1234 })
    cart._innerContainer = src
    src.getContainingItem = function() return cart end
    cart.getItemContainer = function(self) return self._innerContainer end

    local player = F.player({ square = sq })

    local ok = SaucedCarts.performCartTransfer(
        player, item, src, nil, sq)

    _G.sendCorpse = prevSendCorpse
    restoreSb()

    if not Assert.isTrue(ok, "performCartTransfer returned true (silent-drop is success)") then return false end
    if not Assert.isNil(sq._addedBody, "no body added to the drop square") then return false end
    if not Assert.equal(sendCorpseCount, 0, "no sendCorpse broadcast — clients see nothing") then return false end
    return Assert.isTrue(not src:contains(item), "item removed from cart container")
end

tests["unload_fresh_corpse_materializes_via_tryAddCorpseToWorld"] = function()
    -- Fresh corpse (under skeletonAt) -> vanilla's
    -- IsoGridSquare.tryAddCorpseToWorld places it: deserializes, POSITIONS
    -- it on the square, registers it and broadcasts it (GameServer.sendCorpse
    -- in Java). SaucedCarts must not add a Lua sendCorpse of its own -- that
    -- was a second AddCorpseToMap (V11 class). The old shape,
    -- loadCorpseFromByteData(sq) + addCorpse, left the body at the x/y saved
    -- in its byte data: listed on the drop square, uninteractable
    -- (EngineCorpseCartTests proves it against the real engine).
    local restoreSb = installSandbox({ hoursForRemoval = 24, now = 100 })

    local sq = F.square(7, 8, 0)
    local placed, placedItem
    sq.tryAddCorpseToWorld = function(self, it, x, y)
        placedItem = it
        placed = makeDeadBody({ square = self, id = it:getID() })
        return placed
    end
    sq.addCorpse = function(self, body, bRemote) self._addedBody = body end

    local item = makeCorpseItemWithStamp({
        id = 9002, stampedDeathTime = 95,  -- effective_age = 5h, fresh
        loadCorpseFromByteData = function(self, dropSq)
            error("must not deserialize directly: the body would keep its saved x/y")
        end,
    })
    local sendCorpseCount = 0
    local prevSendCorpse = _G.sendCorpse
    _G.sendCorpse = function(body) sendCorpseCount = sendCorpseCount + 1 end
    local prevIsServer = _G.isServer
    _G.isServer = function() return true end

    local src = F.container({ typeName = "TestSrc" })
    src:AddItem(item)
    local cart = makeRegisteredCart({ id = 1235 })
    cart._innerContainer = src
    src.getContainingItem = function() return cart end
    cart.getItemContainer = function(self) return self._innerContainer end

    local player = F.player({ square = sq })

    local ok = SaucedCarts.performCartTransfer(player, item, src, nil, sq)

    _G.isServer = prevIsServer
    _G.sendCorpse = prevSendCorpse
    restoreSb()

    if not Assert.isTrue(ok, "performCartTransfer returned true") then return false end
    if not Assert.isTrue(placed ~= nil, "placed through tryAddCorpseToWorld") then return false end
    if not Assert.equal(placedItem, item, "with the corpse item") then return false end
    if not Assert.isNil(sq._addedBody, "no separate addCorpse (vanilla registers it)") then return false end
    return Assert.equal(sendCorpseCount, 0,
        "no Lua sendCorpse -- the engine broadcast it; a second would double-materialize")
end

return tests
