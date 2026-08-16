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
require "SaucedCarts/WorldCleanupGuard"

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

-- ============================================================================
-- WorldCleanupGuard — boot-time keep-list guard. On servers running
-- ItemRemovalListBlacklistToggle=true, WorldItemRemovalList inverts into a
-- keep-list and every unlisted item is swept by the IsoGridSquare.load filter
-- — including carts saved unflagged before v2.1.16 and loot-spawned carts
-- players use in place. The guard appends cart types to the in-memory list at
-- boot so the filter can never match a cart at all.
-- ============================================================================

local Guard = SaucedCarts.WorldCleanupGuard

--- Sandbox-options stub: state.setValueCalls counts writes, state.list holds
--- the live value so idempotence can be tested across two apply() runs.
--- opts.protect: value of the SaucedCarts.ProtectFromWorldCleanup option
--- object (nil = option not registered, exercising the missing-option path).
--- opts.sandboxVars: when a table, swaps _G.SandboxVars for the duration so
--- the SandboxVars-table fallback is deterministic.
local function withSandbox(opts, fn)
    local state = {
        toggle = opts.toggle,
        list = opts.list or "",
        setValueCalls = 0,
    }
    local sandbox = {
        getOptionByName = function(_, name)
            if name == "ItemRemovalListBlacklistToggle" then
                return { getValue = function() return state.toggle end }
            elseif name == "WorldItemRemovalList" then
                return {
                    getValue = function() return state.list end,
                    setValue = function(_, v)
                        state.setValueCalls = state.setValueCalls + 1
                        state.list = v
                    end,
                }
            elseif name == "SaucedCarts.ProtectFromWorldCleanup" then
                if opts.protect == nil then return nil end
                return { getValue = function() return opts.protect end }
            end
            return nil
        end,
    }
    if opts.hostile then
        sandbox.getOptionByName = function() error("simulated Java-side failure") end
    end
    local realGetSandboxOptions = _G.getSandboxOptions
    local realSandboxVars = _G.SandboxVars
    _G.getSandboxOptions = function() return sandbox end
    if opts.sandboxVars then _G.SandboxVars = opts.sandboxVars end
    local ok, err = pcall(function() fn(state) end)
    _G.getSandboxOptions = realGetSandboxOptions
    _G.SandboxVars = realSandboxVars
    if not ok then error(err) end
end

--- Exact-segment CSV membership (trims each piece, no substring false hits).
local function csvContains(csv, entry)
    local pos = 1
    while true do
        local comma = string.find(csv, ",", pos, true)
        local piece = comma and string.sub(csv, pos, comma - 1) or string.sub(csv, pos)
        piece = string.match(piece, "^%s*(.-)%s*$") or piece
        if piece == entry then return true end
        if not comma then return false end
        pos = comma + 1
    end
end

tests["guard_patch_appends_cart_type_to_empty_list"] = function()
    local patched, added = Guard.computeKeepListPatch("", { "SaucedCarts.ShoppingCart" })
    if not Assert.equal(patched, "SaucedCarts.ShoppingCart",
        "empty list gains exactly the cart type") then return false end
    return Assert.equal(#added, 1, "one addition reported")
end

tests["guard_patch_preserves_existing_entries_and_order"] = function()
    local patched = Guard.computeKeepListPatch(
        "Base.Hat,Base.Glasses", { "SaucedCarts.ShoppingCart" })
    return Assert.equal(patched, "Base.Hat,Base.Glasses,SaucedCarts.ShoppingCart",
        "admin's entries stay first and untouched, cart appended")
end

tests["guard_patch_idempotent_when_already_present"] = function()
    -- Whitespace-tolerant: vanilla's getSplitCSVList trims, so must we.
    local patched = Guard.computeKeepListPatch(
        " Base.Hat , SaucedCarts.ShoppingCart ", { "SaucedCarts.ShoppingCart" })
    return Assert.isNil(patched, "nothing to add -> nil (no setValue churn)")
end

tests["guard_patch_underscore_type_adds_family_prefix"] = function()
    -- IsoGridSquare.load family-matches type:split("_")[0]
    -- (IsoGridSquare.java:3306-3309): with the blacklist toggle on, a listed
    -- "MyMod.CoolCart_v2" is STILL swept unless "MyMod.CoolCart" is listed
    -- too. The patch must cover both or the guard silently fails for any
    -- addon cart with an underscore in its name.
    local patched = Guard.computeKeepListPatch("", { "MyMod.CoolCart_v2" })
    if not Assert.isTrue(csvContains(patched, "MyMod.CoolCart_v2"),
        "full type listed") then return false end
    return Assert.isTrue(csvContains(patched, "MyMod.CoolCart"),
        "family prefix (before first underscore) listed as well")
end

tests["guard_apply_noop_in_remove_list_mode"] = function()
    -- toggle=false is vanilla's default REMOVE-list mode: only listed items
    -- are swept, carts can never match. The guard must not touch the
    -- admin's list.
    -- protect=true isolates the remove-list gate: even an opted-in server
    -- must be left alone when the list is a remove-list.
    local touched
    withSandbox({ toggle = false, list = "Base.Hat", protect = true }, function(state)
        Guard.apply()
        touched = state.setValueCalls
    end)
    return Assert.equal(touched, 0, "remove-list mode left entirely alone")
end

tests["guard_apply_noop_without_opt_in"] = function()
    -- Keep-list mode alone is not enough: the admin must opt in via the
    -- SaucedCarts.ProtectFromWorldCleanup sandbox option. Their cleanup
    -- config is never altered silently.
    local touched
    withSandbox({ toggle = true, list = "Base.Hat", protect = false }, function(state)
        Guard.apply()
        touched = state.setValueCalls
    end)
    return Assert.equal(touched, 0, "opt-in off: keep-list untouched")
end

tests["guard_apply_defaults_off_when_option_missing"] = function()
    -- Option object unregistered AND no SandboxVars entry (old configs,
    -- boot-order surprises): must behave as off, never as on.
    local touched
    withSandbox({ toggle = true, list = "", protect = nil, sandboxVars = {} },
        function(state)
            Guard.apply()
            touched = state.setValueCalls
        end)
    return Assert.equal(touched, 0, "missing option defaults to off")
end

tests["guard_apply_opt_in_via_sandboxvars_fallback"] = function()
    -- When the option OBJECT is unavailable but the SandboxVars table carries
    -- the opt-in, the guard still runs (dedi boot-order resilience).
    local calls
    withSandbox({
        toggle = true, list = "", protect = nil,
        sandboxVars = { SaucedCarts = { ProtectFromWorldCleanup = true } },
    }, function(state)
        Guard.apply()
        calls = state.setValueCalls
    end)
    return Assert.equal(calls, 1, "SandboxVars fallback opt-in applies the patch")
end

tests["guard_apply_patches_keep_list_for_all_registered_carts"] = function()
    local finalList, calls
    withSandbox({ toggle = true, list = "Base.Hat,Base.Glasses", protect = true }, function(state)
        Guard.apply()
        finalList = state.list
        calls = state.setValueCalls
    end)
    if not Assert.equal(calls, 1, "list written exactly once") then return false end
    for _, cartType in ipairs(SaucedCarts.getAllCartTypes()) do
        for _, entry in ipairs(Guard.entriesForCartType(cartType)) do
            if not Assert.isTrue(csvContains(finalList, entry),
                "keep-list covers " .. entry) then return false end
        end
    end
    return Assert.isTrue(csvContains(finalList, "Base.Hat"),
        "admin's own entries survive the patch")
end

tests["guard_apply_idempotent_across_boots"] = function()
    -- Second boot re-reads the (in-memory) patched list: no second write.
    local calls
    withSandbox({ toggle = true, list = "", protect = true }, function(state)
        Guard.apply()
        Guard.apply()
        calls = state.setValueCalls
    end)
    return Assert.equal(calls, 1, "second apply() found nothing to add")
end

tests["guard_apply_survives_hostile_sandbox"] = function()
    -- A Java-side throw (missing option, boot-order surprise) must never
    -- propagate out of OnServerStarted and take other listeners down.
    local result
    withSandbox({ toggle = true, hostile = true }, function()
        result = Guard.apply()
    end)
    return Assert.isFalse(result, "throwing sandbox caught, apply reports false")
end

return tests
