--[[
    SaucedCarts — Spawn decision dice tests
    ========================================

    Locks the per-building probability model exposed by
    SaucedCarts.decideSpawnPlacements (shared/SpawnLocations.lua):

        ONE binary roll  -> "does this building spawn any carts today?"
                            (rate = MAX chance among the building's entries)
        uniform 1..max   -> "how many?"
        per-cart type     -> weighted by chance across all eligible entries
        per-cart place    -> interior/outdoor via that type's outdoorWeight
                            (only when parking zones exist AND it opts in)

    The function is pure (no world deps) and takes an injected rng, so every
    case is deterministic via a scripted rng. rng-call order is:
        [1] binary roll       rng(100)
        [2] count roll        rng(max)            -> count = 1 + result
        per cart:
          [3] type pick        rng(totalChance)    -> ONLY when >1 entry
          [4] outdoor roll      rng(100)            -> ONLY when outdoorReady
                                                      AND the picked type opts in

    v2.1.10 note: the single-entry case skips the type-pick roll entirely, so a
    base-only setup (no addons) consumes the exact same RNG sequence as before
    addon mixing existed.
]]

if isServer() and not isClient() then return end

if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/SpawnLocations"

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Deterministic rng: returns scripted values in order, ignoring the bound.
--- Author must keep each value within [0, n-1] to mirror ZombRand.
local function scriptRng(values)
    local i = 0
    return function(_)
        i = i + 1
        return values[i]
    end
end

--- Assert a placements list equals expected list of { type, kind }.
local function assertPlacements(actual, expected, label)
    if not Assert.equal(#actual, #expected, label .. " (length)") then return false end
    for k = 1, #expected do
        if not Assert.equal(actual[k].type, expected[k].type, label .. " [" .. k .. "].type") then
            return false
        end
        if not Assert.equal(actual[k].kind, expected[k].kind, label .. " [" .. k .. "].kind") then
            return false
        end
    end
    return true
end

local decide = SaucedCarts.decideSpawnPlacements

-- Convenience entry builders.
local function E(t, chance, allowOutdoor, outdoorWeight)
    return { type = t, chance = chance, allowOutdoor = allowOutdoor, outdoorWeight = outdoorWeight }
end

-- ============================================================================
-- TESTS — single entry (base-only; preserves pre-addon behavior + RNG stream)
-- ============================================================================

local tests = {}

tests["binary_roll_fail_spawns_nothing"] = function()
    -- chance 80, mult 1 -> threshold 80. rng(100)=99 -> 99 < 80 is false.
    local out = decide({ E("X.Cart", 80) }, 1, 1.0, false, scriptRng({ 99 }))
    return Assert.equal(#out, 0, "no carts when binary roll fails")
end

tests["binary_roll_hit_cap1_one_cart"] = function()
    -- rng(100)=0 (<80 hit), rng(1)=0 -> count = 1. single entry -> no type roll.
    local out = decide({ E("X.Cart", 80) }, 1, 1.0, false, scriptRng({ 0, 0 }))
    return assertPlacements(out, { { type = "X.Cart", kind = "interior" } },
        "cap=1 hit yields one interior X.Cart")
end

tests["count_is_one_plus_count_roll"] = function()
    for k = 0, 4 do
        local out = decide({ E("X.Cart", 100) }, 5, 1.0, false, scriptRng({ 0, k }))
        if not Assert.equal(#out, 1 + k, "count = 1 + rng(max) for k=" .. k) then
            return false
        end
    end
    return true
end

tests["outdoor_not_ready_all_interior"] = function()
    -- Even with outdoorWeight 100, outdoorReady=false forces interior and skips
    -- the per-cart outdoor roll (only binary + count consumed).
    local out = decide({ E("X.Cart", 100, true, 100) }, 3, 1.0, false, scriptRng({ 0, 2 }))
    return assertPlacements(out, {
        { type = "X.Cart", kind = "interior" },
        { type = "X.Cart", kind = "interior" },
        { type = "X.Cart", kind = "interior" },
    }, "outdoorReady=false -> all interior")
end

tests["outdoor_weight_100_all_outdoor"] = function()
    -- count = 3; each per-cart rng(100)=0 < 100 -> outdoor.
    local out = decide({ E("X.Cart", 100, true, 100) }, 3, 1.0, true, scriptRng({ 0, 2, 0, 0, 0 }))
    return assertPlacements(out, {
        { type = "X.Cart", kind = "outdoor" },
        { type = "X.Cart", kind = "outdoor" },
        { type = "X.Cart", kind = "outdoor" },
    }, "weight=100 -> all outdoor")
end

tests["outdoor_weight_0_all_interior"] = function()
    -- count = 3; per-cart rng(100)=0 but 0 < 0 is false -> interior. The outdoor
    -- roll IS consumed (the type opts in + zones ready), it just never wins.
    local out = decide({ E("X.Cart", 100, true, 0) }, 3, 1.0, true, scriptRng({ 0, 2, 0, 0, 0 }))
    return assertPlacements(out, {
        { type = "X.Cart", kind = "interior" },
        { type = "X.Cart", kind = "interior" },
        { type = "X.Cart", kind = "interior" },
    }, "weight=0 -> all interior")
end

tests["outdoor_weight_defaults_to_30"] = function()
    -- No outdoorWeight -> default 30. count = 2; rolls 29 (<30 outdoor), 30 (interior).
    local out = decide({ E("X.Cart", 100, true, nil) }, 2, 1.0, true, scriptRng({ 0, 1, 29, 30 }))
    return assertPlacements(out, {
        { type = "X.Cart", kind = "outdoor" },
        { type = "X.Cart", kind = "interior" },
    }, "nil outdoorWeight defaults to 30")
end

tests["multiplier_scales_threshold_up"] = function()
    -- chance 50 x mult 2.0 -> threshold 100; rng(100)=99 < 100 -> spawns.
    local out = decide({ E("X.Cart", 50) }, 1, 2.0, false, scriptRng({ 99, 0 }))
    return Assert.equal(#out, 1, "mult 2.0 lifts threshold to 100, 99 still hits")
end

tests["multiplier_zero_never_spawns"] = function()
    local out = decide({ E("X.Cart", 50, true) }, 5, 0.0, true, scriptRng({ 0 }))
    return Assert.equal(#out, 0, "mult 0 -> threshold 0 -> never spawns")
end

-- ============================================================================
-- TESTS — multiple entries (addon carts mix with the built-in cart)
-- ============================================================================

tests["building_hitrate_is_max_chance_not_sum"] = function()
    -- base 80 + addon 20. Hit rate must be MAX (80), not SUM (100). rng(100)=85:
    -- 85 < 80 is false -> no spawn. (If it summed, 85 < 100 would spawn.)
    local out = decide({ E("BASE", 80), E("ADDON", 20) }, 1, 1.0, false, scriptRng({ 85 }))
    return Assert.equal(#out, 0, "hit rate uses MAX chance (80), not SUM")
end

tests["weighted_pick_low_roll_selects_base"] = function()
    -- base 80 + addon 20 (total 100). binary 0 (hit), count rng(1)=0 -> 1,
    -- type roll rng(100)=50 -> cum 80 (50<80) -> BASE.
    local out = decide({ E("BASE", 80), E("ADDON", 20) }, 1, 1.0, false, scriptRng({ 0, 0, 50 }))
    return assertPlacements(out, { { type = "BASE", kind = "interior" } },
        "type roll 50 lands in BASE's [0,80) band")
end

tests["weighted_pick_high_roll_selects_addon"] = function()
    -- type roll rng(100)=90 -> cum 80 (no), 100 (90<100) -> ADDON.
    local out = decide({ E("BASE", 80), E("ADDON", 20) }, 1, 1.0, false, scriptRng({ 0, 0, 90 }))
    return assertPlacements(out, { { type = "ADDON", kind = "interior" } },
        "type roll 90 lands in ADDON's [80,100) band")
end

tests["outdoor_only_for_opted_in_type"] = function()
    -- OUT opts into outdoor (weight 100); IN does not. zones ready.
    -- Cart 1: type roll 10 (<50) -> OUT; outdoor roll 0 (<100) -> outdoor.
    -- Cart 2: type roll 60 (>=50) -> IN; IN doesn't opt in -> no outdoor roll, interior.
    local entries = { E("OUT", 50, true, 100), E("IN", 50) }
    local out = decide(entries, 2, 1.0, true, scriptRng({ 0, 1, 10, 0, 60 }))
    return assertPlacements(out, {
        { type = "OUT", kind = "outdoor" },
        { type = "IN", kind = "interior" },
    }, "only the opted-in type consumes the outdoor roll / can go outside")
end

return tests
