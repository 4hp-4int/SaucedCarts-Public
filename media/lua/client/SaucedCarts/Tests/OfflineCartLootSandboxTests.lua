--[[
    SaucedCarts/Tests/OfflineCartLootSandboxTests.lua
    =================================================

    Locks the vanilla-loot-sandbox layer added to CartLoot: a loaded cart is a
    container of loot, so it must answer to the same knobs every other
    container does. Before this, a server running Insane loot rarity, a banned
    item list, or late-game loot decay still got fully-stocked carts.

    Three mechanisms, each pinned here:

      1. PER-ITEM CATEGORY RARITY — ItemPickerJava.getLootModifier(type).
         Multiplier for the item's loot category (FoodLootNew etc.), and 0.0
         for anything on the admin LootItemRemovalList or in a category set to
         None. Zero is an unconditional skip, matching vanilla's container path
         (getActualSpawnChance returns 0.0 for a zero modifier).
      2. LOOT DECAY OVER TIME — getSandboxOptions():getCurrentLootMultiplier(),
         folded into the cart's LOAD CHANCE.
      3. RemoveStoryLoot — suppresses the survivor-cache tier.

    All three degrade to "no gating" when the engine globals are absent, so an
    offline/mock context keeps the legacy behaviour rather than silently
    spawning empty carts. That fallback is itself tested.

    Sensitivity: drop the `CartLoot.rollKeep(modFn(typ, false), rng)` guard in
    fillCart and the fill_* gating tests fail; drop the worldMult scaling in
    decideCartLoad and the decay tests fail; drop the removeStoryLoot check and
    remove_story_loot_downgrades_survivor fails.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"
require "SaucedCarts/CartLoot"

local CartLoot = SaucedCarts.CartLoot

-- ============================================================================
-- HELPERS (mirrors OfflineCartLootTests so the two files stay independent)
-- ============================================================================

--- Deterministic rng: scripted values in order, ignoring the bound.
local function scriptRng(values)
    local i = 0
    return function(_)
        i = i + 1
        return values[i]
    end
end

--- Counts how many times it was called, always returns 0.
local function countingRng(box)
    return function(_) box.n = (box.n or 0) + 1; return 0 end
end

local function zeroRng() return 0 end

--- Run fn with ProceduralDistributions.list = listTable, restoring after.
local function withPD(listTable, fn)
    local orig = ProceduralDistributions
    ProceduralDistributions = listTable and { list = listTable } or nil
    local ok, err = pcall(fn)
    ProceduralDistributions = orig
    if not ok then error(err) end
end

--- Run fn with instanceItem stubbed to mint distinct items of a fixed weight.
local function withItemStub(weight, fn)
    local orig = instanceItem
    local idc = 0
    instanceItem = function(typ)
        idc = idc + 1
        return F.item({ id = 950000 + idc, fullType = typ, weight = weight })
    end
    local ok, err = pcall(fn)
    instanceItem = orig
    if not ok then error(err) end
end

--- Run fn with a stubbed ItemPickerJava.getLootModifier. `modifiers` maps a
--- full type to its modifier; `default` covers everything else. Passing nil
--- for the whole table removes ItemPickerJava entirely (the offline case).
local function withItemPicker(modifiers, default, fn)
    local orig = ItemPickerJava
    if modifiers == nil and default == nil then
        ItemPickerJava = nil
    else
        ItemPickerJava = {
            getLootModifier = function(typ)
                local m = modifiers and modifiers[typ]
                if m ~= nil then return m end
                return default or 1.0
            end,
        }
    end
    local ok, err = pcall(fn)
    ItemPickerJava = orig
    if not ok then error(err) end
end

--- A cart item (InventoryContainer) with a generous inner container.
local function makeCart(capacity)
    local cart = F.item({ fullType = "SaucedCarts.TestSandboxCart", weight = 5 })
    cart._type = "InventoryContainer"
    cart._inner = F.container({ containingItem = cart, capacity = capacity or 500 })
    cart.getItemContainer = function(self) return self._inner end
    return cart
end

--- Injectable modifier function with the same contract as
--- CartLoot.lootModifierFor, for driving fillCart/padToFillState directly.
local function modFnFor(modifiers, default)
    return function(typ, isJunk)
        local m = modifiers and modifiers[typ]
        if m == nil then m = default or 1.0 end
        if isJunk and m > 0 then return 1.0 end
        return m
    end
end

local tests = {}

-- ============================================================================
-- lootModifierFor — the bridge to ItemPickerJava
-- ============================================================================

tests["modifier_falls_back_to_one_without_itempicker"] = function()
    -- The offline / no-script-manager case. Must NOT gate everything to zero,
    -- or a mocked context would spawn nothing and look "fixed" when it isn't.
    local m
    withItemPicker(nil, nil, function()
        m = CartLoot.lootModifierFor("Base.TinnedSoup", false)
    end)
    return Assert.equal(m, 1.0, "no ItemPickerJava -> ungated legacy behaviour")
end

tests["modifier_reads_category_value_from_itempicker"] = function()
    local rare, normal
    withItemPicker({ ["Base.Pistol"] = 0.05 }, 1.0, function()
        rare   = CartLoot.lootModifierFor("Base.Pistol", false)
        normal = CartLoot.lootModifierFor("Base.TinnedSoup", false)
    end)
    return Assert.equal(rare, 0.05, "insane-rarity category modifier passed through")
        and Assert.equal(normal, 1.0, "normal category unchanged")
end

tests["modifier_junk_clamps_nonzero_to_one"] = function()
    -- Vanilla's isJunk rule (ItemPickerJava.java:2086-2092): filler ignores
    -- category scaling entirely.
    local m
    withItemPicker({ ["Base.Plank"] = 0.05 }, 1.0, function()
        m = CartLoot.lootModifierFor("Base.Plank", true)
    end)
    return Assert.equal(m, 1.0, "junk is exempt from category rarity")
end

tests["modifier_junk_still_respects_removal_list"] = function()
    -- The clamp is `if (isJunk && modifier > 0)` — a banned item stays banned.
    local m
    withItemPicker({ ["Base.Plank"] = 0 }, 1.0, function()
        m = CartLoot.lootModifierFor("Base.Plank", true)
    end)
    return Assert.equal(m, 0, "a banned filler type is still banned as junk")
end

tests["modifier_nil_type_is_zero"] = function()
    return Assert.equal(CartLoot.lootModifierFor(nil, false), 0, "nil type never spawns")
end

-- ============================================================================
-- rollKeep — the pure keep/skip decision
-- ============================================================================

tests["keep_always_at_or_above_one"] = function()
    local box = { n = 0 }
    local rng = countingRng(box)
    local atOne     = CartLoot.rollKeep(1.0, rng)
    local abundant  = CartLoot.rollKeep(3.0, rng)
    return Assert.isTrue(atOne, "modifier 1.0 always keeps")
        and Assert.isTrue(abundant, "modifier above 1 keeps (we scale down only)")
        and Assert.equal(box.n, 0, "no rng consumed when the answer is unconditional")
end

tests["keep_never_at_zero"] = function()
    local box = { n = 0 }
    local rng = countingRng(box)
    return Assert.isFalse(CartLoot.rollKeep(0, rng), "banned / None-rarity never keeps")
        and Assert.isFalse(CartLoot.rollKeep(-1, rng), "negative treated as never")
        and Assert.equal(box.n, 0, "no rng consumed for a zero modifier")
end

tests["keep_fractional_is_a_probability_band"] = function()
    -- 0.6 -> keep while rng(1000) < 600.
    local justIn  = CartLoot.rollKeep(0.6, scriptRng({ 599 }))
    local justOut = CartLoot.rollKeep(0.6, scriptRng({ 600 }))
    return Assert.isTrue(justIn, "599/1000 is inside the 0.6 band")
        and Assert.isFalse(justOut, "600/1000 is outside the 0.6 band")
end

-- ============================================================================
-- decideCartLoad — loot decay over time + RemoveStoryLoot
-- ============================================================================

tests["decay_scales_the_load_chance"] = function()
    -- density 4 (Common) = 70% base. worldMult 0.5 -> 35%.
    local loaded = CartLoot.decideCartLoad(4, scriptRng({ 34, 999, 0, 0 }), { worldMult = 0.5 })
    local empty  = CartLoot.decideCartLoad(4, scriptRng({ 35 }), { worldMult = 0.5 })
    return Assert.isTrue(loaded.tier ~= "empty", "roll 34 is inside the decayed 35% chance")
        and Assert.equal(empty.tier, "empty", "roll 35 falls outside it (undecayed 70% would load)")
end

tests["decay_absent_leaves_chance_untouched"] = function()
    -- Precision counterpart: a fresh world (mult 1.0) and no opts at all must
    -- behave identically to the pre-sandbox code.
    local withOpts = CartLoot.decideCartLoad(4, scriptRng({ 69, 999, 0, 0 }), { worldMult = 1.0 })
    local noOpts   = CartLoot.decideCartLoad(4, scriptRng({ 69, 999, 0, 0 }))
    return Assert.isTrue(withOpts.tier ~= "empty", "mult 1.0 keeps the full 70% chance")
        and Assert.equal(noOpts.tier, withOpts.tier, "omitting opts matches mult 1.0")
end

tests["decay_to_zero_forces_empty_without_rolling"] = function()
    local box = { n = 0 }
    local load = CartLoot.decideCartLoad(4, countingRng(box), { worldMult = 0 })
    return Assert.equal(load.tier, "empty", "fully decayed world spawns empty carts")
        and Assert.equal(load.count, 0, "zero count")
        and Assert.equal(box.n, 0, "short-circuits before consuming rng")
end

tests["remove_story_loot_downgrades_survivor"] = function()
    -- rng: [1] load hit, [2] survivor HIT (5 < 15), [3] light/loaded split,
    -- [4] count. With the option on, the survivor hit must not become a
    -- weapons cache.
    local load = CartLoot.decideCartLoad(4, scriptRng({ 0, 5, 0, 0 }),
        { removeStoryLoot = true })
    return Assert.isTrue(load.tier ~= "survivor", "survivor cache suppressed (got " .. load.tier .. ")")
        and Assert.isTrue(load.tier ~= "empty", "and degrades to an ordinary load, not to empty")
end

tests["survivor_still_reachable_when_story_loot_allowed"] = function()
    -- Control for the test above: same rng stream, option off.
    local load = CartLoot.decideCartLoad(4, scriptRng({ 0, 5, 0, 0 }),
        { removeStoryLoot = false })
    return Assert.equal(load.tier, "survivor", "default worlds still roll the cache")
end

-- ============================================================================
-- fillCart — per-item category rarity
-- ============================================================================

tests["fill_skips_items_banned_by_the_removal_list"] = function()
    -- Modifier 0 = on LootItemRemovalList, or its category set to None.
    local placed, weight
    withPD({ GigamartCannedFood = { items = { "Base.TinnedSoup", 10 } } }, function()
        withItemStub(1, function()
            local cart = makeCart(500)
            placed, weight = CartLoot.fillCart(cart, "grocery", "loaded", 8, zeroRng,
                modFnFor({ ["Base.TinnedSoup"] = 0 }))
        end)
    end)
    return Assert.equal(placed, 0, "a banned type is never placed in a cart")
        and Assert.equal(weight, 0, "no weight added")
end

tests["fill_redirects_rather_than_thins_on_a_rare_loot_world"] = function()
    -- REWEIGHT, not reject (2026-08-29 balance decision). Suppression used to
    -- pick an item and then bin it, and the binned pick still consumed one of
    -- `count` — so a firearms-suppressed survivor cache arrived close to
    -- EMPTY. A cart is meant to be a reward, so a suppressed category should
    -- redirect the budget instead of deleting it.
    --
    -- Now the modifier scales the PICK WEIGHT at pool-build time. A partially
    -- suppressed context still fills its count; only the composition shifts.
    local placed
    withPD({ GigamartCannedFood = { items = { "Base.TinnedSoup", 10 } } }, function()
        withItemStub(1, function()
            local cart = makeCart(500)
            placed = CartLoot.fillCart(cart, "grocery", "loaded", 4,
                scriptRng({ 0, 0, 0, 0 }),
                modFnFor({ ["Base.TinnedSoup"] = 0.5 }))
        end)
    end)
    return Assert.equal(placed, 4,
        "a 0.5 modifier no longer eats picks; the cart still fills (got "
        .. tostring(placed) .. ")")
end

tests["fill_suppressed_category_loses_share_to_the_rest"] = function()
    -- The composition half of the same decision. Two items, equal base weight,
    -- one suppressed to 0.1 — the survivor should dominate the pool. Asserted
    -- on the POOL rather than by sampling, so it is deterministic.
    local weights
    withPD({ GigamartCannedFood = { items = {
        "Base.TinnedSoup", 10,
        "Base.Pistol",     10,
    } } }, function()
        local pool = CartLoot.buildWeightedPool({ "GigamartCannedFood" },
            modFnFor({ ["Base.TinnedSoup"] = 1.0, ["Base.Pistol"] = 0.1 }))
        weights = {}
        for _, e in ipairs(pool) do weights[e.type] = e.weight end
    end)

    if not Assert.equal(weights["Base.TinnedSoup"], 10,
        "unsuppressed item keeps its full weight") then return false end
    return Assert.equal(weights["Base.Pistol"], 1,
        "suppressed item is scaled down but still reachable")
end

tests["fill_fully_suppressed_context_yields_an_empty_cart"] = function()
    -- The edge case the handover doc asked to pin. Under the old reject path
    -- this emptied out by binning every pick; under reweighting the pool comes
    -- back empty and fillCart returns early on the #pool == 0 guard. Same
    -- outcome, different code path — and the hard guarantee (modifier 0 NEVER
    -- spawns) is preserved either way.
    local placed, weight
    withPD({ GigamartCannedFood = { items = { "Base.TinnedSoup", 10 } } }, function()
        withItemStub(1, function()
            local cart = makeCart(500)
            placed, weight = CartLoot.fillCart(cart, "grocery", "loaded", 4,
                scriptRng({ 0, 0, 0, 0 }),
                modFnFor({ ["Base.TinnedSoup"] = 0 }))
        end)
    end)
    if not Assert.equal(placed, 0, "nothing is placed from a fully banned context") then
        return false
    end
    return Assert.equal(weight, 0, "and no weight is consumed")
end

tests["fill_unchanged_on_a_normal_loot_world"] = function()
    -- Precision no-op: at modifier 1.0 the gate consumes no rng and places the
    -- same items the pre-sandbox code did.
    local placed, weight
    withPD({ GigamartCannedFood = { items = { "Base.TinnedSoup", 10 } } }, function()
        withItemStub(2, function()
            local cart = makeCart(500)
            placed, weight = CartLoot.fillCart(cart, "grocery", "light", 3, zeroRng,
                modFnFor(nil, 1.0))
        end)
    end)
    return Assert.equal(placed, 3, "normal world still fills the designed count")
        and Assert.equal(weight, 6, "and the designed weight")
end

tests["fill_default_modfn_is_the_live_lookup"] = function()
    -- fillCart with no modFn must route through lootModifierFor, which reads
    -- ItemPickerJava. Proves the production call site is actually gated.
    local placed
    withPD({ GigamartCannedFood = { items = { "Base.TinnedSoup", 10 } } }, function()
        withItemStub(1, function()
            withItemPicker({ ["Base.TinnedSoup"] = 0 }, 1.0, function()
                local cart = makeCart(500)
                placed = CartLoot.fillCart(cart, "grocery", "loaded", 6, zeroRng)
            end)
        end)
    end)
    return Assert.equal(placed, 0, "the default path honours ItemPickerJava")
end

-- ============================================================================
-- padToFillState — junk obeys the removal list, ignores category rarity
-- ============================================================================

tests["pad_skips_banned_junk_and_terminates"] = function()
    -- Every filler banned: no junk placed, and the guard counter still
    -- advances so the while loop can't spin forever.
    local count, weight
    withItemStub(3, function()
        local cart = makeCart(50)
        count, weight = CartLoot.padToFillState(cart, 0.33, zeroRng,
            function() return 0 end)
    end)
    return Assert.equal(count, 0, "no banned filler added")
        and Assert.equal(weight, 0, "no junk weight")
end

tests["pad_ignores_category_rarity_for_junk"] = function()
    -- The junk clamp means an Insane-rarity world still gets a cart that LOOKS
    -- used — the filler is worthless by design, so gating it would only make
    -- loaded carts render empty.
    local count, finalW
    withItemStub(3, function()
        local cart = makeCart(50)
        count = CartLoot.padToFillState(cart, 0.33, zeroRng, modFnFor(nil, 0.05))
        finalW = cart:getItemContainer():getCapacityWeight()
    end)
    return Assert.isTrue(count > 0, "junk still pads on a rare-loot world (got " .. count .. ")")
        and Assert.isTrue(finalW >= 16.5, "reaches the partial target (got " .. finalW .. ")")
end

-- ============================================================================
-- OnCreate placeholders (spawner stubs) never enter the pool
-- ============================================================================
-- Guns of Marz injects `*_Spawner` stubs straight into GunStoreGuns and
-- ArmyStorageGuns — two of the three lists the "survivor" context draws from.
-- They are base:weapon with no Ranged, so the sandbox gate classifies them as
-- MELEE and a firearms-suppressed server still gets guns in survivor carts.
-- They also resolve a TICK LATER off an OnTick queue, so fillCart measures a
-- stub's weight and WorldSpawning picks the cart's visual model from it.
--
-- Filtering on OnCreate (Item.getLuaCreate, java-api index:101) needs no
-- knowledge of any specific mod.

--- Stub getScriptManager():FindItem(t):getLuaCreate(). `withCreate` is a set
--- of full types that carry an OnCreate handler.
local function withScriptManager(withCreate, fn)
    local orig = _G.getScriptManager
    _G.getScriptManager = function()
        return {
            FindItem = function(_, typ)
                return { getLuaCreate = function() return withCreate[typ] end }
            end,
        }
    end
    local ok, err = pcall(fn)
    _G.getScriptManager = orig
    if not ok then error(err) end
end

tests["pool_excludes_oncreate_placeholder_items"] = function()
    local types = {}
    withScriptManager({ ["MarzGuns.World_Army_Rifle_Spawner"] = "MarzGuns_OnCreate.SelectItem" }, function()
        withPD({ ArmyStorageGuns = { items = {
            "MarzGuns.World_Army_Rifle_Spawner", 15,
            "Base.Pistol",                       10,
        } } }, function()
            local pool = CartLoot.buildWeightedPool({ "ArmyStorageGuns" })
            for _, e in ipairs(pool) do types[e.type] = true end
        end)
    end)
    if not Assert.isTrue(types["Base.Pistol"],
        "a normal item is still in the pool") then return false end
    return Assert.isFalse(types["MarzGuns.World_Army_Rifle_Spawner"] or false,
        "the OnCreate spawner stub never enters the pool")
end

tests["pool_lookup_failure_does_not_empty_the_pool"] = function()
    -- Fail-safe. No script manager (offline, early boot) must mean "treat as a
    -- normal item", never "filter everything" — that would silently produce
    -- empty carts everywhere.
    local n
    withPD({ ArmyStorageGuns = { items = { "Base.Pistol", 10 } } }, function()
        local orig = _G.getScriptManager
        _G.getScriptManager = nil
        n = #CartLoot.buildWeightedPool({ "ArmyStorageGuns" })
        _G.getScriptManager = orig
    end)
    return Assert.equal(n, 1, "unreachable script manager leaves the pool intact")
end

-- ============================================================================
-- Junk padding prefers the context's own tables
-- ============================================================================

tests["pad_prefers_the_contexts_own_junk"] = function()
    -- All 1350 vanilla tables carry a junk block; 292 are non-empty. A grocery
    -- cart padded with a dishcloth reads better than one padded with planks.
    local placedTypes = {}
    withPD({
        GigamartCannedFood = { items = { "Base.TinnedSoup", 10 },
                               junk  = { rolls = 1, items = { "Base.DishCloth", 10 } } },
    }, function()
        local orig = instanceItem
        instanceItem = function(typ)
            placedTypes[#placedTypes + 1] = typ
            return F.item({ id = 970000 + #placedTypes, fullType = typ, weight = 3 })
        end
        local cart = makeCart(50)
        CartLoot.padToFillState(cart, 0.33, zeroRng, modFnFor(nil, 1.0), "grocery")
        instanceItem = orig
    end)

    if not Assert.isTrue(#placedTypes > 0, "padding actually placed something") then
        return false
    end
    for _, t in ipairs(placedTypes) do
        if t ~= "Base.DishCloth" then
            return Assert.equal(t, "Base.DishCloth",
                "padding drew from the context's junk table, not JUNK_POOL")
        end
    end
    return Assert.isTrue(true, "every padded item came from the context's junk table")
end

tests["pad_falls_back_to_global_junk_when_context_has_none"] = function()
    -- The common case: ~78% of vanilla junk blocks are empty.
    local placedTypes = {}
    withPD({
        GigamartCannedFood = { items = { "Base.TinnedSoup", 10 }, junk = { items = {} } },
    }, function()
        local orig = instanceItem
        instanceItem = function(typ)
            placedTypes[#placedTypes + 1] = typ
            return F.item({ id = 971000 + #placedTypes, fullType = typ, weight = 3 })
        end
        local cart = makeCart(50)
        CartLoot.padToFillState(cart, 0.33, zeroRng, modFnFor(nil, 1.0), "grocery")
        instanceItem = orig
    end)

    if not Assert.isTrue(#placedTypes > 0, "padding still happened") then return false end
    return Assert.isFalse(placedTypes[1] == "Base.DishCloth",
        "an empty context junk block falls back to the global JUNK_POOL")
end

return tests
