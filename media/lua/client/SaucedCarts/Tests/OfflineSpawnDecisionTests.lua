--[[
    SaucedCarts — Spawn decision dice tests
    ========================================

    Locks the pure spawn-policy functions in shared/SpawnLocations.lua:

      INTERIOR (decideSpawnPlacements):
        ONE binary roll  -> "does this building spawn any carts today?"
                            (rate = MAX chance among the building's entries)
        uniform 1..max   -> "how many?"
        per-cart type     -> weighted by chance across all eligible entries
        Returns a list of cart-type strings (outdoor is no longer decided here).

      OUTDOOR / ZONE (zone-anchored, mirrors vanilla AddVehicles):
        zoneOverlapsChunk -> geometry test (IsoChunk.java:1735 port)
        decideZoneSpawns  -> area-scaled count of carts for a vehicle zone
        pickOutdoorCartType -> weighted cart-type pick from the outdoor pool

    All functions are pure (injected rng), so every case is deterministic via a
    scripted rng. decideSpawnPlacements rng order:
        [1] binary roll   rng(100)
        [2] count roll    rng(max)         -> count = 1 + result
        per cart:
          [3] type pick    rng(totalChance) -> ONLY when >1 entry
    The single-entry case skips the type-pick roll, keeping a base-only setup's
    RNG sequence stable.
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

--- Assert a cart-type-string list equals expected.
local function assertTypes(actual, expected, label)
    if not Assert.equal(#actual, #expected, label .. " (length)") then return false end
    for k = 1, #expected do
        if not Assert.equal(actual[k], expected[k], label .. " [" .. k .. "]") then
            return false
        end
    end
    return true
end

local decide = SaucedCarts.decideSpawnPlacements

-- Convenience entry builder (interior dice only care about type + chance).
local function E(t, chance)
    return { type = t, chance = chance }
end

local tests = {}

-- ============================================================================
-- INTERIOR — single entry (base-only; preserves pre-addon RNG stream)
-- ============================================================================

tests["binary_roll_fail_spawns_nothing"] = function()
    -- chance 80, mult 1 -> threshold 80. rng(100)=99 -> 99 < 80 is false.
    local out = decide({ E("X.Cart", 80) }, 1, 1.0, scriptRng({ 99 }))
    return Assert.equal(#out, 0, "no carts when binary roll fails")
end

tests["binary_roll_hit_cap1_one_cart"] = function()
    -- rng(100)=0 (<80 hit), rng(1)=0 -> count = 1. single entry -> no type roll.
    local out = decide({ E("X.Cart", 80) }, 1, 1.0, scriptRng({ 0, 0 }))
    return assertTypes(out, { "X.Cart" }, "cap=1 hit yields one X.Cart")
end

tests["count_is_one_plus_count_roll"] = function()
    for k = 0, 4 do
        local out = decide({ E("X.Cart", 100) }, 5, 1.0, scriptRng({ 0, k }))
        if not Assert.equal(#out, 1 + k, "count = 1 + rng(max) for k=" .. k) then
            return false
        end
    end
    return true
end

tests["single_entry_skips_type_roll"] = function()
    -- Only binary + count rolls are consumed for a single entry. A 3rd scripted
    -- value of 999 (out of range) would surface if a type roll were taken.
    local out = decide({ E("X.Cart", 100) }, 1, 1.0, scriptRng({ 0, 0, 999 }))
    return assertTypes(out, { "X.Cart" }, "single entry consumes no type roll")
end

tests["multiplier_scales_threshold_up"] = function()
    -- chance 50 x mult 2.0 -> threshold 100; rng(100)=99 < 100 -> spawns.
    local out = decide({ E("X.Cart", 50) }, 1, 2.0, scriptRng({ 99, 0 }))
    return Assert.equal(#out, 1, "mult 2.0 lifts threshold to 100, 99 still hits")
end

tests["multiplier_zero_never_spawns"] = function()
    local out = decide({ E("X.Cart", 50) }, 5, 0.0, scriptRng({ 0 }))
    return Assert.equal(#out, 0, "mult 0 -> threshold 0 -> never spawns")
end

-- ============================================================================
-- INTERIOR — multiple entries (addon carts mix with the built-in cart)
-- ============================================================================

tests["building_hitrate_is_max_chance_not_sum"] = function()
    -- base 80 + addon 20. Hit rate must be MAX (80), not SUM (100). rng(100)=85:
    -- 85 < 80 is false -> no spawn. (If it summed, 85 < 100 would spawn.)
    local out = decide({ E("BASE", 80), E("ADDON", 20) }, 1, 1.0, scriptRng({ 85 }))
    return Assert.equal(#out, 0, "hit rate uses MAX chance (80), not SUM")
end

tests["weighted_pick_low_roll_selects_base"] = function()
    -- binary 0 (hit), count rng(1)=0 -> 1, type roll rng(100)=50 -> cum 80 -> BASE.
    local out = decide({ E("BASE", 80), E("ADDON", 20) }, 1, 1.0, scriptRng({ 0, 0, 50 }))
    return assertTypes(out, { "BASE" }, "type roll 50 lands in BASE's [0,80) band")
end

tests["weighted_pick_high_roll_selects_addon"] = function()
    -- type roll rng(100)=90 -> cum 80 (no), 100 (90<100) -> ADDON.
    local out = decide({ E("BASE", 80), E("ADDON", 20) }, 1, 1.0, scriptRng({ 0, 0, 90 }))
    return assertTypes(out, { "ADDON" }, "type roll 90 lands in ADDON's [80,100) band")
end

-- ============================================================================
-- ZONE — zoneOverlapsChunk (geometry; port of IsoChunk.java:1735)
-- ============================================================================
-- Chunk (cx,cy) covers tiles [cx*8 .. cx*8+7] on each axis.

local overlaps = SaucedCarts.zoneOverlapsChunk

tests["zone_inside_chunk_overlaps"] = function()
    return Assert.isTrue(overlaps(0, 0, 4, 4, 0, 0), "zone fully inside chunk 0,0")
end

tests["zone_in_other_chunk_no_overlap"] = function()
    -- zone at tiles 10..11 is in chunk 1, not chunk 0.
    if not Assert.isFalse(overlaps(10, 10, 2, 2, 0, 0), "zone in chunk 1 doesn't hit chunk 0") then
        return false
    end
    return Assert.isTrue(overlaps(10, 10, 2, 2, 1, 1), "...but does hit chunk 1,1")
end

tests["zone_boundary_belongs_to_higher_chunk"] = function()
    -- tile x=8 is the first tile of chunk 1, not the last of chunk 0.
    if not Assert.isFalse(overlaps(8, 0, 2, 2, 0, 0), "tile 8 not in chunk 0") then return false end
    return Assert.isTrue(overlaps(8, 0, 2, 2, 1, 0), "tile 8 is in chunk 1")
end

tests["zone_spanning_two_chunks_hits_both"] = function()
    -- tiles 6..9 straddle chunk 0 (0..7) and chunk 1 (8..15).
    if not Assert.isTrue(overlaps(6, 0, 4, 2, 0, 0), "straddling zone hits chunk 0") then return false end
    return Assert.isTrue(overlaps(6, 0, 4, 2, 1, 0), "straddling zone hits chunk 1")
end

-- ============================================================================
-- ZONE — decideZoneSpawns (area-scaled count)
-- ============================================================================

local decideZone = SaucedCarts.decideZoneSpawns

tests["zone_driveway_one_roll"] = function()
    -- area 15 < areaPerRoll 16 -> rolls clamps up to 1. chance 100 -> hit.
    local n = decideZone(15, 100, 1.0, 2, 16, scriptRng({ 0 }))
    return Assert.equal(n, 1, "small driveway gets exactly one roll")
end

tests["zone_big_lot_capped_by_max"] = function()
    -- area 100 -> floor(100/16)=6 rolls, capped to maxPerZone=2. Both hit.
    local n = decideZone(100, 100, 1.0, 2, 16, scriptRng({ 0, 0 }))
    return Assert.equal(n, 2, "big area capped at maxPerChunk")
end

tests["zone_chance_gates_each_roll"] = function()
    -- area 16 -> 1 roll. chance 25, rng(100)=50 -> 50 < 25 false -> 0.
    local n = decideZone(16, 25, 1.0, 2, 16, scriptRng({ 50 }))
    return Assert.equal(n, 0, "roll above chance places nothing")
end

tests["zone_multiplier_scales_chance"] = function()
    -- chance 25 x mult 2 -> threshold 50. rng(100)=40 < 50 -> hit.
    local n = decideZone(16, 25, 2.0, 2, 16, scriptRng({ 40 }))
    return Assert.equal(n, 1, "multiplier lifts the per-roll threshold")
end

tests["zone_partial_hits"] = function()
    -- area 64 -> floor(64/16)=4 rolls, cap 5. rolls hit/miss/hit/miss.
    local n = decideZone(64, 50, 1.0, 5, 16, scriptRng({ 0, 99, 0, 99 }))
    return Assert.equal(n, 2, "counts only the rolls that hit")
end

-- ============================================================================
-- ZONE — pickOutdoorCartType (weighted pool pick)
-- ============================================================================

local pickType = SaucedCarts.pickOutdoorCartType

tests["pool_single_entry_no_roll"] = function()
    local t = pickType({ { type = "ONLY", weight = 100 } }, scriptRng({ 999 }))
    return Assert.equal(t, "ONLY", "single-entry pool returns it without rolling")
end

tests["pool_weighted_low_roll"] = function()
    -- A:80 B:20 (total 100). rng(100)=50 -> cum 80 -> A.
    local t = pickType({ { type = "A", weight = 80 }, { type = "B", weight = 20 } }, scriptRng({ 50 }))
    return Assert.equal(t, "A", "roll 50 lands in A's band")
end

tests["pool_weighted_high_roll"] = function()
    local t = pickType({ { type = "A", weight = 80 }, { type = "B", weight = 20 } }, scriptRng({ 90 }))
    return Assert.equal(t, "B", "roll 90 lands in B's band")
end

tests["pool_empty_returns_nil"] = function()
    return Assert.isTrue(pickType({}, scriptRng({ 0 })) == nil, "empty pool -> nil")
end

return tests
