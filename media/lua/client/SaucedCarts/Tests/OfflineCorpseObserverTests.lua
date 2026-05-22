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

tests["client_receiving_removeGhostCorpse_purges_zombie_by_onlineId"] = function()
    -- Client side of the contract: when the broadcast arrives, the local
    -- zombie matching the onlineId is removed from the cell.
    local removed = { fromWorld = false, fromSquare = false }
    local zombie = {
        _type = "IsoZombie",
        getOnlineID    = function() return 999 end,
        removeFromWorld  = function() removed.fromWorld = true end,
        removeFromSquare = function() removed.fromSquare = true end,
    }
    local zomList = {}
    zomList.size = function() return 1 end
    zomList.get  = function() return zombie end

    local prevGetCell = _G.getCell
    _G.getCell = function()
        return {
            getZombieList = function() return zomList end,
            getObjectList = function() return { remove = function() end } end,
        }
    end

    -- Drive the client handler directly with the broadcast payload.
    CS.handleRemoveGhostCorpse({ bodyId = 999, kind = "zombie",
        x = 0, y = 0, z = 0 })

    _G.getCell = prevGetCell

    if not Assert.isTrue(removed.fromWorld, "removeFromWorld called on local zombie") then return false end
    return Assert.isTrue(removed.fromSquare, "removeFromSquare called on local zombie")
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
