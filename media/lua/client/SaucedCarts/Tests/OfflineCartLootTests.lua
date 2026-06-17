--[[
    SaucedCarts/Tests/OfflineCartLootTests.lua
    ==========================================

    Locks the pure + fill logic in shared/SaucedCarts/CartLoot.lua — the
    context-aware loaded-cart feature.

    Scope:
      * contextForRoom: room name -> loot context key (incl. nil/unmapped).
      * poolFor: context key -> vanilla ProceduralDistributions list names.
      * decideCartLoad (pure, scripted rng): density gating (Off -> always
        empty), the load roll, the ultra-rare survivor sub-roll, the
        light/loaded split, and per-tier count ranges.
      * buildWeightedPool: merges flat {type,weight,...} arrays, skips missing
        lists + zero-weight entries, guards a missing ProceduralDistributions.
      * pickWeighted: cumulative-weight band selection + empty -> nil.
      * fillCart: honors the per-tier weight budget (caps a high-capacity
        cart), routes survivor tier to the survivor pool, empty/no-data -> 0,0.

    All randomness is injected, so every case is deterministic. decideCartLoad
    rng order (see CartLoot.lua):
        [1] rng(100)   load roll   -> empty unless < LOAD_CHANCE[density]
        [2] rng(1000)  survivor    -> survivor if < 15
        [3] rng(100)   light/loaded-> light if < 75
        [4] rng(range) count
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"
require "SaucedCarts/CartLoot"

local CartLoot = SaucedCarts.CartLoot

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Deterministic rng: returns scripted values in order, ignoring the bound.
--- Author keeps each value within [0, n-1] to mirror ZombRand.
local function scriptRng(values)
    local i = 0
    return function(_)
        i = i + 1
        return values[i]
    end
end

--- An rng that always returns 0 — for fillCart, where we exercise count/budget
--- and want pickWeighted to deterministically take the first weighted entry.
local function zeroRng() return 0 end

local function contains(list, val)
    for _, v in ipairs(list) do if v == val then return true end end
    return false
end

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
        return F.item({ id = 900000 + idc, fullType = typ, weight = weight })
    end
    local ok, err = pcall(fn)
    instanceItem = orig
    if not ok then error(err) end
end

--- A cart item (InventoryContainer) with a generous inner container.
local function makeCart(capacity)
    local cart = F.item({ fullType = "SaucedCarts.TestLootCart", weight = 5 })
    cart._type = "InventoryContainer"
    cart._inner = F.container({ containingItem = cart, capacity = capacity or 500 })
    cart.getItemContainer = function(self) return self._inner end
    return cart
end

local tests = {}

-- ============================================================================
-- contextForRoom
-- ============================================================================

tests["context_grocery_rooms"] = function()
    return Assert.equal(CartLoot.contextForRoom("gigamart"), "grocery", "gigamart -> grocery")
        and Assert.equal(CartLoot.contextForRoom("conveniencestore"), "grocery", "convenience -> grocery")
end

tests["context_materials_rooms"] = function()
    return Assert.equal(CartLoot.contextForRoom("warehouse"), "materials", "warehouse -> materials")
        and Assert.equal(CartLoot.contextForRoom("storageunit"), "materials", "storageunit -> materials")
end

tests["context_tools_rooms"] = function()
    return Assert.equal(CartLoot.contextForRoom("toolstore"), "tools", "toolstore -> tools")
        and Assert.equal(CartLoot.contextForRoom("firegarage"), "tools", "firegarage -> tools")
end

tests["context_unmapped_is_generic"] = function()
    return Assert.equal(CartLoot.contextForRoom("bedroom"), "generic", "unmapped room -> generic")
end

tests["context_nil_is_generic"] = function()
    return Assert.equal(CartLoot.contextForRoom(nil), "generic", "nil room -> generic")
end

-- ============================================================================
-- poolFor
-- ============================================================================

tests["poolFor_grocery_has_food_list"] = function()
    return Assert.isTrue(contains(CartLoot.poolFor("grocery"), "GigamartCannedFood"),
        "grocery pool references a food distribution")
end

tests["poolFor_survivor_has_gun_list"] = function()
    return Assert.isTrue(contains(CartLoot.poolFor("survivor"), "GunStoreAmmunition"),
        "survivor pool references a gun distribution")
end

tests["poolFor_unknown_falls_back_to_generic"] = function()
    local g = CartLoot.poolFor("nonsense")
    return Assert.isTrue(contains(g, "CrateRandomJunk"), "unknown context -> generic pool")
end

-- ============================================================================
-- decideCartLoad — density gating
-- ============================================================================

tests["decide_off_density_always_empty"] = function()
    -- density 1 = Off -> chance 0 -> empty without consuming any roll.
    local r = CartLoot.decideCartLoad(1, scriptRng({ 0, 0, 0, 0 }))
    return Assert.equal(r.tier, "empty", "Off density never loads")
        and Assert.equal(r.count, 0, "Off density count 0")
end

tests["decide_nil_density_defaults_some"] = function()
    -- nil -> default 3 (Some), chance 40. rng(100)=40 -> 40 >= 40 -> empty.
    local r = CartLoot.decideCartLoad(nil, scriptRng({ 40 }))
    return Assert.equal(r.tier, "empty", "roll at the chance boundary -> empty (default density)")
end

tests["decide_load_roll_miss_is_empty"] = function()
    -- density 4 chance 70. rng(100)=70 -> 70 >= 70 -> empty.
    local r = CartLoot.decideCartLoad(4, scriptRng({ 70 }))
    return Assert.equal(r.tier, "empty", "load roll >= chance -> empty")
end

-- ============================================================================
-- decideCartLoad — tiers
-- ============================================================================

tests["decide_survivor_tier"] = function()
    -- load hit (0<40), survivor hit (rng(1000)=14 < 15), count rng(3)=2 -> 4.
    local r = CartLoot.decideCartLoad(3, scriptRng({ 0, 14, 2 }))
    return Assert.equal(r.tier, "survivor", "survivor sub-roll < 15 -> survivor")
        and Assert.equal(r.count, 4, "survivor count = 2 + rng(3)")
end

tests["decide_light_tier"] = function()
    -- load hit, survivor miss (500>=15), light hit (rng(100)=0 < 75), count rng(4)=3 -> 5.
    local r = CartLoot.decideCartLoad(3, scriptRng({ 0, 500, 0, 3 }))
    return Assert.equal(r.tier, "light", "rng(100) < 75 -> light")
        and Assert.equal(r.count, 5, "light count = 2 + rng(4)")
end

tests["decide_loaded_tier"] = function()
    -- load hit, survivor miss, light miss (80 >= 75 -> loaded), count rng(7)=6 -> 12.
    local r = CartLoot.decideCartLoad(3, scriptRng({ 0, 500, 80, 6 }))
    return Assert.equal(r.tier, "loaded", "rng(100) >= 75 -> loaded")
        and Assert.equal(r.count, 12, "loaded count = 6 + rng(7)")
end

tests["decide_count_ranges_min"] = function()
    -- All count rolls at 0 -> tier minimums.
    local light = CartLoot.decideCartLoad(3, scriptRng({ 0, 500, 0, 0 }))
    local loaded = CartLoot.decideCartLoad(3, scriptRng({ 0, 500, 80, 0 }))
    local surv = CartLoot.decideCartLoad(3, scriptRng({ 0, 0, 0 }))
    return Assert.equal(light.count, 2, "light min count 2")
        and Assert.equal(loaded.count, 6, "loaded min count 6")
        and Assert.equal(surv.count, 2, "survivor min count 2")
end

-- ============================================================================
-- buildWeightedPool
-- ============================================================================

tests["buildpool_merges_flat_arrays"] = function()
    withPD({
        TestA = { items = { "Base.X", 10, "Base.Y", 5 } },
        TestB = { items = { "Base.Z", 3 } },
    }, function()
        local pool = CartLoot.buildWeightedPool({ "TestA", "TestB" })
        Assert.equal(#pool, 3, "merged 3 entries from two lists")
        Assert.equal(pool[1].type, "Base.X", "first entry type")
        Assert.equal(pool[1].weight, 10, "first entry weight")
    end)
    return true
end

tests["buildpool_skips_missing_and_zero_weight"] = function()
    withPD({
        TestA = { items = { "Base.X", 10, "Base.Zero", 0 } },
    }, function()
        local pool = CartLoot.buildWeightedPool({ "TestA", "DoesNotExist" })
        Assert.equal(#pool, 1, "missing list skipped, zero-weight entry skipped")
        Assert.equal(pool[1].type, "Base.X", "only the positive-weight entry survives")
    end)
    return true
end

tests["buildpool_no_distributions_is_empty"] = function()
    withPD(nil, function()
        local pool = CartLoot.buildWeightedPool({ "Anything" })
        Assert.equal(#pool, 0, "no ProceduralDistributions -> empty pool, no error")
    end)
    return true
end

-- ============================================================================
-- pickWeighted
-- ============================================================================

tests["pick_low_roll_first_band"] = function()
    local pool = { { type = "A", weight = 80 }, { type = "B", weight = 20 } }
    return Assert.equal(CartLoot.pickWeighted(pool, scriptRng({ 50 })), "A", "roll 50 in A band")
end

tests["pick_high_roll_second_band"] = function()
    local pool = { { type = "A", weight = 80 }, { type = "B", weight = 20 } }
    return Assert.equal(CartLoot.pickWeighted(pool, scriptRng({ 90 })), "B", "roll 90 in B band")
end

tests["pick_empty_pool_nil"] = function()
    return Assert.isTrue(CartLoot.pickWeighted({}, scriptRng({ 0 })) == nil, "empty pool -> nil")
end

-- ============================================================================
-- fillCart
-- ============================================================================

tests["fill_empty_tier_no_op"] = function()
    local cart = makeCart()
    local placed, weight = CartLoot.fillCart(cart, "grocery", "empty", 5, zeroRng)
    return Assert.equal(placed, 0, "empty tier places nothing")
        and Assert.equal(weight, 0, "empty tier zero weight")
end

tests["fill_weight_budget_caps_high_capacity_cart"] = function()
    -- light budget = 8kg. Items weigh 3kg each, count=5. Loop checks budget at
    -- the START of each iter: 0->3->6->9, then 9 >= 8 stops. 3 placed, not 5,
    -- even though the cart's capacity (500) could hold all five.
    local placed, weight
    withPD({ GigamartCannedFood = { items = { "Base.TinnedSoup", 10 } } }, function()
        withItemStub(3, function()
            local cart = makeCart(500)
            placed, weight = CartLoot.fillCart(cart, "grocery", "light", 5, zeroRng)
        end)
    end)
    return Assert.equal(placed, 3, "weight budget caps count below the requested 5")
        and Assert.equal(weight, 9, "placed weight reflects the 3 items added")
end

tests["fill_survivor_uses_survivor_pool"] = function()
    -- survivor budget = 15kg. Items weigh 2kg, count=3 -> all 3 fit. The pool
    -- must come from the SURVIVOR lists (poolKey override), not the context.
    local placed
    withPD({ GunStoreAmmunition = { items = { "Base.Bullets9mm", 10 } } }, function()
        withItemStub(2, function()
            local cart = makeCart(500)
            placed = CartLoot.fillCart(cart, "grocery", "survivor", 3, zeroRng)
        end)
    end)
    return Assert.equal(placed, 3, "survivor tier fills from the survivor pool")
end

tests["fill_empty_pool_places_nothing"] = function()
    -- Context maps to lists that don't exist in PD -> empty pool -> 0 placed.
    local placed, weight
    withPD({ SomethingElse = { items = { "Base.X", 1 } } }, function()
        withItemStub(1, function()
            local cart = makeCart(500)
            placed, weight = CartLoot.fillCart(cart, "grocery", "light", 5, zeroRng)
        end)
    end)
    return Assert.equal(placed, 0, "no matching distribution -> nothing placed")
        and Assert.equal(weight, 0, "no weight added")
end

-- ============================================================================
-- fillTargetFor
-- ============================================================================

tests["target_loaded_aims_full"] = function()
    return Assert.equal(CartLoot.fillTargetFor("loaded"),
        SaucedCarts.Config.FILL_FULL_THRESHOLD, "loaded tier aims for FULL ratio")
end

tests["target_light_and_survivor_aim_partial"] = function()
    return Assert.equal(CartLoot.fillTargetFor("light"),
            SaucedCarts.Config.FILL_PARTIAL_THRESHOLD, "light aims for PARTIAL ratio")
        and Assert.equal(CartLoot.fillTargetFor("survivor"),
            SaucedCarts.Config.FILL_PARTIAL_THRESHOLD, "survivor aims for PARTIAL ratio")
end

-- ============================================================================
-- padToFillState
-- ============================================================================

tests["pad_reaches_target_ratio"] = function()
    -- capacity 50, target 0.33 -> 16.5kg. Junk weighs 3kg each. Adds until the
    -- container's capacity-weight crosses the target (the calculateFillState basis).
    local count, weight, finalW
    withItemStub(3, function()
        local cart = makeCart(50)
        count, weight = CartLoot.padToFillState(cart, 0.33, zeroRng)
        finalW = cart:getItemContainer():getCapacityWeight()
    end)
    return Assert.isTrue(finalW >= 16.5, "padded weight reaches the partial target (got " .. finalW .. ")")
        and Assert.isTrue(count >= 5 and count <= 7, "about 6 junk pieces of 3kg (got " .. count .. ")")
end

tests["pad_respects_weight_cap_on_huge_capacity"] = function()
    -- capacity 1000, target 0.33 -> 330kg, but JUNK_WEIGHT_CAP (25) stops it far
    -- short. Proves a huge-capacity cart isn't stuffed with absurd junk.
    local count, weight
    withItemStub(3, function()
        local cart = makeCart(1000)
        count, weight = CartLoot.padToFillState(cart, 0.33, zeroRng)
    end)
    return Assert.isTrue(weight <= 30, "junk weight capped well under the 330kg target (got " .. weight .. ")")
        and Assert.isTrue(count <= 12, "few junk pieces, not hundreds (got " .. count .. ")")
end

tests["pad_no_op_when_already_at_target"] = function()
    -- Prefill above the target so no junk is needed.
    local count, weight
    withItemStub(3, function()
        local cart = makeCart(50)
        cart:getItemContainer():AddItem(F.item({ id = 111, fullType = "Base.Heavy", weight = 20 }))
        count, weight = CartLoot.padToFillState(cart, 0.33, zeroRng)
    end)
    return Assert.equal(count, 0, "already past target -> no junk added")
        and Assert.equal(weight, 0, "no junk weight")
end

return tests
