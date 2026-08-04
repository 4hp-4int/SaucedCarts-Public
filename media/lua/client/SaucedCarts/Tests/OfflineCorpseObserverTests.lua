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

    -- Read captured broadcasts.
    local broadcasts = Net.getCapturedBroadcasts()
    local removeGhostBroadcast = nil
    for _, b in ipairs(broadcasts) do
        if b.command == "removeGhostCorpse" then removeGhostBroadcast = b end
    end

    Net.disableTestMode()
    _G.getCell = prevGetCell
    _G.instanceof = origIO
    restoreSb()
    w:teardown()

    if not Assert.isTrue(ok, "load handler succeeded") then return false end
    if not Assert.isTrue(removeGhostBroadcast ~= nil,
        "server broadcasts removeGhostCorpse after load") then return false end
    if not Assert.equal(removeGhostBroadcast.args.bodyId, 12345,
        "broadcast carries zombie's onlineId so each client can purge") then return false end
    return Assert.equal(removeGhostBroadcast.args.kind, "zombie",
        "broadcast carries kind='zombie' for clients to dispatch via cell.getZombieList")
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

tests["client_purges_stranded_original_body_before_removing_wrapper"] = function()
    -- v2.1.16 regression. The zombie branch used to remove ONLY the wrapper
    -- and return, stranding the pre-grab IsoDeadBody on every client that
    -- hadn't yet run vanilla's ZombieOnGroundState cleanup — which is the
    -- one thing that could have removed it, and which needs the wrapper
    -- alive to run. The stranded body kept counting toward CorpseCount, so
    -- corpse sickness never cleared even though the corpse was in the cart.
    local env = installGhostCell({ onlineId = 999, bodyId = 555,
        bodyX = 103, bodyY = 98 })

    CS.handleRemoveGhostCorpse({ bodyId = 999, kind = "zombie",
        originalBodyId = 555, x = 100, y = 100, z = 0 })

    env.restore()

    if not Assert.isTrue(env.removedBody == env.ghostBody,
        "stranded body located by id and removed from its square") then return false end
    if not Assert.isTrue(env.removedRemote == true,
        "removeCorpse called with bRemote=true (we are the chain terminator)") then return false end
    -- Body gone means vanilla has nothing left to do, so the wrapper can go
    -- immediately — no deferral needed.
    if not Assert.isTrue(env.removed.fromWorld,
        "wrapper zombie still purged once the body is handled") then return false end
    return Assert.isTrue(env.removed.fromSquare, "removeFromSquare called on local zombie")
end

tests["client_defers_wrapper_purge_when_body_not_located"] = function()
    -- No body ids in the payload (pre-v2.1.16 server), or a drag longer than
    -- the sweep radius. We must NOT rip the wrapper out immediately —
    -- vanilla's ZombieOnGroundState -> IsoDeadBody.removeDeadBody is the
    -- only remaining cleanup and it reads the wrapper's reanimatedBodyId.
    -- Purge lands on the deferred sweep instead.
    local env = installGhostCell({ onlineId = 999 })

    CS.handleRemoveGhostCorpse({ bodyId = 999, kind = "zombie",
        x = 0, y = 0, z = 0 })

    local purgedEarly = env.removed.fromWorld
    -- Drain the deferral (production drains via Events.OnTick).
    CS._flushGhostPurges()
    env.restore()

    if not Assert.isTrue(purgedEarly == false,
        "wrapper left alive so vanilla gets its cleanup window") then return false end
    if not Assert.isTrue(env.removed.fromWorld,
        "wrapper purged once the deferral expires") then return false end
    return Assert.isTrue(env.removed.fromSquare, "removeFromSquare called on deferred purge")
end

tests["client_deferred_sweep_retries_body_purge_before_giving_up"] = function()
    -- The deferred pass sweeps for the body one more time. Covers the case
    -- where vanilla's cleanup didn't fire either and we're the last resort.
    local env = installGhostCell({ onlineId = 999, bodyId = 777,
        bodyX = 40, bodyY = 40 })

    -- Centre is out of sweep range of the body (radius 10), so the first
    -- pass misses and the purge defers.
    CS.handleRemoveGhostCorpse({ bodyId = 999, kind = "zombie",
        originalBodyId = 777, x = 0, y = 0, z = 0 })
    local foundEarly = env.removedBody ~= nil

    -- Second pass sweeps the same centre — still a miss, but it must not
    -- crash and must still retire the wrapper.
    CS._flushGhostPurges()
    env.restore()

    if not Assert.isTrue(foundEarly == false,
        "body outside sweep radius is not found on the first pass") then return false end
    return Assert.isTrue(env.removed.fromWorld,
        "wrapper always retired after the deferral, even if the body is unreachable")
end

tests["extract_original_body_id_parses_reanimated_wrapper_name"] = function()
    -- reanimate() stamps the source body into the wrapper's name
    -- (IsoDeadBody.java:1937: setName("ReanimatedCorpse_" + this)). That
    -- name is the ONLY surviving reference to the original body's id once
    -- the body has been pulled from the world — and the extractor that
    -- reads it sat unused from v2.1.5 to v2.1.16, which is why clients
    -- could never purge their stranded copy.
    local origIO = patchInstanceof()

    -- Real toString shapes: IsoMovingObject.toString for the zombie,
    -- IsoDeadBody.toString nested inside its name.
    local wrapper = setmetatable({
        _type = "IsoZombie",
        isReanimatedForGrappleOnly = function() return true end,
    }, { __tostring = function()
        return "IsoZombie{  Name:ReanimatedCorpse_IsoDeadBody{  Name:null,  ID:4242," ..
            "  ObjectID:DeadBody-17,  wasZombie:true,  deathTime:990.0 },  ID:31 }"
    end })

    local got = CS._extractOriginalBodyIdFromGrappled(wrapper)

    -- A plain zombie (not a grapple wrapper) must yield nil — we only ever
    -- want to purge bodies we know were reanimated for dragging.
    local plain = setmetatable({
        _type = "IsoZombie",
        isReanimatedForGrappleOnly = function() return false end,
    }, { __tostring = function() return "IsoZombie{  Name:null,  ID:31 }" end })
    local gotPlain = CS._extractOriginalBodyIdFromGrappled(plain)

    _G.instanceof = origIO

    if not Assert.equal(got, 4242,
        "original IsoDeadBody id parsed out of the wrapper name, not the wrapper's own ID:31") then
        return false
    end
    return Assert.isTrue(gotPlain == nil, "non-grapple zombie yields no body id")
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

tests["unload_fresh_corpse_materializes_and_broadcasts_sendCorpse"] = function()
    -- Fresh corpse (under skeletonAt) → loadCorpseFromByteData spawns body,
    -- addCorpse registers on the tile, and sendCorpse fires for remote
    -- clients to receive AddCorpseToMapPacket.
    local restoreSb = installSandbox({ hoursForRemoval = 24, now = 100 })

    local sq = F.square(7, 8, 0)
    sq.addCorpse = function(self, body, bRemote) self._addedBody = body end

    local materialized
    local item = makeCorpseItemWithStamp({
        id = 9002, stampedDeathTime = 95,  -- effective_age = 5h, fresh
        loadCorpseFromByteData = function(self, dropSq)
            materialized = makeDeadBody({ square = dropSq, id = self:getID() })
            return materialized
        end,
    })
    local sendCorpseCount = 0
    local prevSendCorpse = _G.sendCorpse
    _G.sendCorpse = function(body) sendCorpseCount = sendCorpseCount + 1 end

    -- Force isServer() to true so the sendCorpse branch fires.
    local prevIsServer = _G.isServer
    _G.isServer = function() return true end
    -- isClient stays false in this scope.

    local src = F.container({ typeName = "TestSrc" })
    src:AddItem(item)
    local cart = makeRegisteredCart({ id = 1235 })
    cart._innerContainer = src
    src.getContainingItem = function() return cart end
    cart.getItemContainer = function(self) return self._innerContainer end

    local player = F.player({ square = sq })

    local ok = SaucedCarts.performCartTransfer(
        player, item, src, nil, sq)

    _G.isServer = prevIsServer
    _G.sendCorpse = prevSendCorpse
    restoreSb()

    if not Assert.isTrue(ok, "performCartTransfer returned true") then return false end
    if not Assert.isTrue(materialized ~= nil, "loadCorpseFromByteData was called") then return false end
    if not Assert.equal(sq._addedBody, materialized,
        "addCorpse called with the rematerialized body") then return false end
    return Assert.equal(sendCorpseCount, 1,
        "exactly one sendCorpse broadcast — remote clients receive AddCorpseToMapPacket")
end

return tests
