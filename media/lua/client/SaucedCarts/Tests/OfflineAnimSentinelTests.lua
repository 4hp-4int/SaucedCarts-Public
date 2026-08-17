--[[
    SaucedCarts — AnimLoadSentinel tests
    ====================================

    The sentinel detects the engine's animset-load race (Steam Workshop
    mounts too late, AnimationSets cache without the mod's nodes) by
    scanning IsoGameCharacter.dbgGetAnimTrackName output for Bob_Cart_*
    clips while pushing. These tests pin the two pure pieces:

      - _scanForCartClip: finds cart clips anywhere in the layer/track
        grid, tolerates empty strings (out-of-bounds contract), tolerates
        throwing readers, matches by substring (transition clip names like
        Bob_Cart_WalkToRun count)
      - _recordSample: needs SAMPLES_NEEDED (4) cumulative misses to fail,
        a single hit permanently disarms, verdicts are sticky
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/AnimLoadSentinel"

local Sentinel = SaucedCarts.AnimLoadSentinel

local function gridReader(grid)
    -- grid: { [layer] = { [track] = name } }, missing -> ""
    return function(layer, track)
        local l = grid[layer]
        return (l and l[track]) or ""
    end
end

local tests = {}

tests["scan_finds_cart_clip_in_any_slot"] = function()
    local found = Sentinel._scanForCartClip(gridReader({
        [0] = { [0] = "Bob_Walk" },
        [2] = { [1] = "Bob_Cart_Walk" },
    }))
    return Assert.isTrue(found, "cart clip on a mask layer is found")
end

tests["scan_matches_transition_clips"] = function()
    local found = Sentinel._scanForCartClip(gridReader({
        [0] = { [0] = "Bob_Cart_WalkToRun" },
    }))
    return Assert.isTrue(found, "transition clips count as cart clips")
end

tests["scan_misses_vanilla_only_grid"] = function()
    local found = Sentinel._scanForCartClip(gridReader({
        [0] = { [0] = "Bob_Walk", [1] = "Bob_WalkHeavyLimpR" },
        [1] = { [0] = "Bob_Idle_Bag" },
    }))
    return Assert.isFalse(found, "vanilla-only tracks mean the nodes are missing")
end

tests["scan_survives_throwing_reader"] = function()
    local calls = 0
    local found = Sentinel._scanForCartClip(function(l, t)
        calls = calls + 1
        error("boom")
    end)
    if not Assert.isFalse(found, "throwing reader reads as not-found") then return false end
    return Assert.isTrue(calls > 1, "scan continued past individual failures")
end

tests["verdict_needs_four_cumulative_misses"] = function()
    Sentinel._reset()
    local v
    for i = 1, 3 do
        v = Sentinel._recordSample(false)
        if v ~= nil then
            Sentinel._reset()
            return Assert.isTrue(false, "verdict fired early at sample " .. i)
        end
    end
    v = Sentinel._recordSample(false)
    Sentinel._reset()
    return Assert.equal(v, "failed", "4th cumulative miss fails the check")
end

tests["single_hit_disarms_permanently"] = function()
    Sentinel._reset()
    for _ = 1, 3 do Sentinel._recordSample(false) end
    local v = Sentinel._recordSample(true)
    if not Assert.equal(v, "ok", "a hit resolves to ok") then Sentinel._reset(); return false end
    -- misses after an ok verdict must not flip it
    for _ = 1, 20 do Sentinel._recordSample(false) end
    local finalV = Sentinel._getState()
    Sentinel._reset()
    return Assert.equal(finalV, "ok", "ok verdict is sticky")
end

tests["failed_verdict_is_sticky"] = function()
    Sentinel._reset()
    for _ = 1, 4 do Sentinel._recordSample(false) end
    local v = Sentinel._recordSample(true)  -- late hit must not un-fail
    Sentinel._reset()
    return Assert.equal(v, "failed", "failed verdict is sticky (single warning contract)")
end

return tests
