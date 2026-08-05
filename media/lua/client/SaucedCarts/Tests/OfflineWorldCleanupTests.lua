--[[
    SaucedCarts — carts deleted by the server's world-item cleanup
    ==============================================================

    Player report (Fichin, B42.20 dedicated MP): "During world cleanup the
    item is deleted... since it can't be stored in a player's inventory or
    inside a regular container, there's currently no safe way to keep it."

    Root cause: vanilla's world-item cleanup is NOT a periodic sweep — it's a
    filter inside IsoGridSquare.load (IsoGridSquare.java:3297-3314) that
    discards matching IsoWorldInventoryObjects as the chunk is deserialized.
    The entire condition is gated on `&& !worldItem.isIgnoreRemoveSandbox()`,
    and that flag is serialized (IsoWorldInventoryObject.java:487 write /
    :430 read), so setting it once at drop time survives save/load.

    Vanilla sets the flag on EVERY player-initiated drop —
    ISDropWorldItemAction.lua:85, ISDropVehicleItemAction.lua:51,
    ItemSpawner.java:37 — so player-handled items are exempt by design and
    the sandbox option only sweeps spawned clutter. SaucedCarts dropped carts
    (and, when a cart breaks, its entire payload) through raw
    AddWorldInventoryItem without the flag, making carts the only
    player-dropped object in the game that vanilla cleanup eats.

    These tests lock the flag onto all five drop paths plus the shared
    SaucedCarts.markDropPersistent helper. Sensitivity: every path test fails
    against pre-fix code (flag never set → ignoreRemoveSandbox stays false).
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"
require "SaucedCarts/CartTransferInterceptor"
require "SaucedCarts/Durability"
require "SaucedCarts/ContainerRestrictions"

local Durability = SaucedCarts.Durability

local TEST_CART_TYPE = "SaucedCarts.TestCleanupCart"
if not SaucedCarts.isRegistered(TEST_CART_TYPE) then
    SaucedCarts.registerCart(TEST_CART_TYPE, {
        name         = "TestCleanupCart",
        capacity     = 50,
        conditionMax = 100,
    })
end

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

--- Every world item on the square must carry the cleanup exemption.
--- Returns (allExempt, count) — a count of 0 is reported as NOT exempt so a
--- test can never pass by simply failing to drop anything.
local function worldItemsExempt(sq)
    local list = sq:getWorldObjects()
    local n = list:size()
    if n == 0 then return false, 0 end
    for i = 0, n - 1 do
        local wi = list:get(i)
        if not (wi and wi._private and wi._private.ignoreRemoveSandbox) then
            return false, n
        end
    end
    return true, n
end

local origInstanceItem = instanceItem
local origZombRandFloat = ZombRandFloat
local salvageStub
local function installSalvageStub()
    salvageStub = {
        ["Base.ScrapMetal"] = true,
        ["Base.Wire"]       = true,
        ["Base.MetalPipe"]  = true,
    }
    instanceItem = function(fullType)
        if salvageStub and salvageStub[fullType] then
            return F.item({ fullType = fullType, weight = 0.5 })
        end
        return origInstanceItem and origInstanceItem(fullType) or nil
    end
    -- Deterministic placement offsets; also guarantees dropSalvage's
    -- ZombRand(min, max+1) rolls produce at least one ScrapMetal.
    ZombRandFloat = function(a, b) return (a + b) / 2 end
end
local function uninstallSalvageStub()
    instanceItem = origInstanceItem
    ZombRandFloat = origZombRandFloat
    salvageStub = nil
end

local function makeCart(opts)
    opts = opts or {}
    local cart = F.item({
        id           = opts.id,
        fullType     = opts.fullType or TEST_CART_TYPE,
        condition    = opts.condition or 100,
        conditionMax = opts.conditionMax or 100,
    })
    cart._type = "InventoryContainer"
    cart:getModData().SaucedCarts_distancePushed = opts.distancePushed or 0
    cart._innerContainer = F.container({
        containingItem = cart,
        typeName       = "ShoppingCart",
        capacity       = opts.capacity or 50,
    })
    cart.getItemContainer = function(self) return self._innerContainer end
    return cart
end

-- Recognize the Lua-table mock as a cart (additive — real userdata still
-- routes through the original implementations).
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item.getFullType and (item:getFullType() or ""):find("^SaucedCarts%.") then
        return true
    end
    return origSafeIsCart(item)
end
local origIsCart = SaucedCarts.isCart
SaucedCarts.isCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item.getFullType and (item:getFullType() or ""):find("^SaucedCarts%.") then
        return true
    end
    return origIsCart(item)
end

--- Stub the heavy deps the drop paths touch so they actually REACH
--- AddWorldInventoryItem. Restores on throw (a leaked stub poisons whichever
--- test Kahlua's arbitrary pairs order runs next).
local function withDropEnv(fn)
    local origApply  = Durability.applyAccumulatedDamage
    local origVisual = SaucedCarts.updateCartVisual
    local origSend   = _G.sendRemoveItemFromContainer
    local origEquip  = _G.sendEquip
    Durability.applyAccumulatedDamage = function() return 100 end
    SaucedCarts.updateCartVisual = function() end
    _G.sendRemoveItemFromContainer = function() end
    _G.sendEquip = function() end
    local ok, err = pcall(fn)
    Durability.applyAccumulatedDamage = origApply
    SaucedCarts.updateCartVisual = origVisual
    _G.sendRemoveItemFromContainer = origSend
    _G.sendEquip = origEquip
    if not ok then error(err) end
end

local tests = {}

-- ============================================================================
-- SaucedCarts.markDropPersistent — the shared helper's contract
-- ============================================================================

tests["mark_drop_persistent_sets_the_exemption_flag"] = function()
    local sq = F.square(0, 0, 0)
    local dropped = sq:AddWorldInventoryItem(F.item({ id = 1 }), 0.5, 0.5, 0, false)

    if not Assert.isTrue(SaucedCarts.markDropPersistent(dropped),
        "reports success on a real world drop") then return false end

    local wi = dropped:getWorldItem()
    if not Assert.equal(wi._private.setIgnoreRemoveSandboxCount, 1,
        "setIgnoreRemoveSandbox called exactly once") then return false end
    return Assert.isTrue(wi._private.ignoreRemoveSandbox,
        "flag set to true, not merely touched")
end

tests["mark_drop_persistent_nil_safe"] = function()
    -- AddWorldInventoryItem can return nil (square rejected the drop). The
    -- helper is called on its raw return value at every site, so a nil must
    -- never throw — that would abort the surrounding drop mid-way.
    return Assert.isFalse(SaucedCarts.markDropPersistent(nil),
        "nil return value is a safe no-op")
end

tests["mark_drop_persistent_tolerates_missing_world_item"] = function()
    -- An item that never materialized (setWorldItem never ran) must not throw.
    local orphan = F.item({ id = 2 })
    return Assert.isFalse(SaucedCarts.markDropPersistent(orphan),
        "item with no world item is a safe no-op")
end

tests["mark_drop_persistent_swallows_errors"] = function()
    -- Fail-safe: never let the exemption break a drop that otherwise worked.
    local hostile = { getWorldItem = function() error("boom") end }
    return Assert.isFalse(SaucedCarts.markDropPersistent(hostile),
        "throwing accessor is caught, returns false instead of propagating")
end

-- ============================================================================
-- Durability.dropContentsAndDestroy — cart payload + salvage (the worst case:
-- a broken cart dumps its ENTIRE cargo on the ground)
-- ============================================================================

tests["broken_cart_payload_exempt_from_world_cleanup"] = function()
    installSalvageStub()
    local cart = makeCart()
    local inner = cart:getItemContainer()
    for _, it in ipairs({
        F.item({ id = 101, fullType = "Base.Screwdriver" }),
        F.item({ id = 102, fullType = "Base.Plank" }),
        F.item({ id = 103, fullType = "Base.Nails" }),
    }) do inner:AddItem(it) end
    local sq = F.square(0, 0, 0)
    local player = F.player({ square = sq })

    Durability.dropContentsAndDestroy(cart, player, sq)
    uninstallSalvageStub()

    local exempt, n = worldItemsExempt(sq)
    if not Assert.greaterEq(n, 3, "all three cart contents reached the ground") then
        return false
    end
    return Assert.isTrue(exempt,
        "every item dumped by the broken cart is exempt from world cleanup")
end

tests["broken_cart_salvage_exempt_from_world_cleanup"] = function()
    -- Empty cart: the only world items on the square are salvage drops, so
    -- this isolates the dropSalvage path from the contents path.
    installSalvageStub()
    local cart = makeCart()
    local sq = F.square(0, 0, 0)

    Durability.dropContentsAndDestroy(cart, nil, sq)
    uninstallSalvageStub()

    local exempt, n = worldItemsExempt(sq)
    if not Assert.greater(n, 0, "salvage dropped") then return false end
    return Assert.isTrue(exempt, "break salvage is exempt from world cleanup")
end

-- ============================================================================
-- InstantDrop.dropCartSP — SP / combat drop
-- ============================================================================

tests["sp_instant_drop_cart_exempt_from_world_cleanup"] = function()
    -- InstantDrop lives under client/ and returns its module table.
    local loaded, InstantDrop = pcall(require, "SaucedCarts/CartState/InstantDrop")
    if not (loaded and type(InstantDrop) == "table" and InstantDrop.dropCartSP) then
        return PZTestKit.skip("InstantDrop.dropCartSP unavailable in this env")
    end

    local sq = F.square(0, 0, 0)
    local cart = makeCart()
    local player = F.player({ square = sq })
    player:setPrimaryHandItem(cart)
    player:getInventory():AddItem(cart)

    local dropped
    withDropEnv(function()
        if not _G.ISInventoryPage then _G.ISInventoryPage = {} end
        dropped = InstantDrop.dropCartSP(player, cart)
    end)

    if not Assert.isTrue(dropped, "SP combat drop completed") then return false end
    local exempt, n = worldItemsExempt(sq)
    if not Assert.equal(n, 1, "exactly one world cart created") then return false end
    return Assert.isTrue(exempt,
        "cart dropped for combat is exempt from world cleanup")
end

-- ============================================================================
-- ContainerRestrictions unequip force-drop — SP / dedicated-server branch
-- ============================================================================

local hooksInstalled = false
local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true
    if not __classmetatables then
        __classmetatables = setmetatable({}, {
            __index = function() return { __index = {} } end,
        })
    end
    if not ItemContainer then ItemContainer = { class = "ItemContainer" } end
    -- Per-listener isolation: a plain triggerEvent aborts the whole chain if
    -- an earlier mod listener throws offline.
    local evt = Events and Events.OnGameStart
    if evt and evt._listeners then
        for _, fn in ipairs(evt._listeners) do pcall(fn) end
    end
end

local function unequipHookReady()
    local cr = SaucedCarts.ContainerRestrictions
    return cr and cr.isUnequipHookInitialized and cr.isUnequipHookInitialized()
end

tests["unequip_force_drop_cart_exempt_from_world_cleanup"] = function()
    installHooks()
    if not unequipHookReady() then
        return PZTestKit.skip("ISUnequipAction hook unavailable (no vanilla_requires PZ install)")
    end

    local sq = F.square(0, 0, 0)
    local cart = makeCart()
    local player = F.player({ square = sq })
    player:getInventory():AddItem(cart)
    -- getOnlineID() nil → the hook takes the SP / dedicated-server branch that
    -- creates the world item locally (the MP client branch delegates instead).
    player.getOnlineID = function(self) return nil end
    player.removeFromHands = player.removeFromHands or function(self, it) end

    withDropEnv(function()
        local action = setmetatable({ character = player, item = cart },
            { __index = ISUnequipAction })
        ISUnequipAction.complete(action)
    end)

    local exempt, n = worldItemsExempt(sq)
    if not Assert.equal(n, 1, "exactly one world cart created by the force-drop") then
        return false
    end
    return Assert.isTrue(exempt,
        "cart force-dropped on unequip is exempt from world cleanup")
end

-- ============================================================================
-- AnimationSync requestInstantDrop — the MP server-authoritative drop.
-- This is the path a real dedicated server takes, so it matters most.
-- ============================================================================

--- server/SaucedCarts/AnimationSync.lua opens with
--- `if isClient() and not isServer() then return end`, and the kit defaults to
--- an MP client — so the module must be required (and driven) under a flipped
--- context or it returns early and never registers its handlers.
local function withServerContext(fn)
    local origIsClient, origIsServer = _G.isClient, _G.isServer
    _G.isClient = function() return false end
    _G.isServer = function() return true end
    local ok, err = pcall(fn)
    _G.isClient, _G.isServer = origIsClient, origIsServer
    if not ok then error(err) end
end

tests["server_instant_drop_cart_exempt_from_world_cleanup"] = function()
    local handler
    withServerContext(function()
        pcall(require, "SaucedCarts/AnimationSync")
        handler = SaucedCarts.Network._getServerHandler
            and SaucedCarts.Network._getServerHandler("requestInstantDrop")
    end)
    if not handler then
        return PZTestKit.skip("requestInstantDrop handler unavailable in this env")
    end

    local sq = F.square(0, 0, 0)
    local cart = makeCart({ id = 9100 })
    local player = F.player({ square = sq })
    player:getInventory():AddItem(cart)
    player:setPrimaryHandItem(cart)

    withDropEnv(function()
        withServerContext(function()
            handler(player, { cartId = cart:getID(), distancePushed = 0 })
        end)
    end)

    local exempt, n = worldItemsExempt(sq)
    if not Assert.equal(n, 1, "server drop created exactly one world cart") then
        return false
    end
    return Assert.isTrue(exempt,
        "cart dropped by the MP server is exempt from world cleanup")
end

return tests
