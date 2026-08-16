--[[
    SaucedCarts — Cart run speed / SpeedPenaltyMultiplier tests
    ===========================================================

    Background (the "riding" report, 2026-08-16): the stand-on-and-kick cart
    animation is the SPRINT-state anim (Bob_Cart_Sprint). Vanilla cancels
    sprint whenever effective run speed drops below 0.4 unless the player is
    in ghost mode (IsoPlayer.java:2733-2741), and the cart's script
    RunSpeedModifier feeds that speed TWICE via calcRunSpeedModByBag
    (IsoGameCharacter.java:10325-10329). At the old 0.75 a clean character sat
    at ~0.41 — one moodle from losing the ride. Base is now 0.9.

    Java reads bag.getScriptItem().runSpeedModifier — a script FIELD with no
    Lua getter — so the sandbox option can only work as a per-TYPE DoParam
    script patch. The pre-v2.1.20 implementation stamped
    modData.SaucedCarts_runSpeedModifier, which NOTHING read: the sandbox
    option was a silent no-op. These tests pin the working pipeline:

      - computeRunSpeedModifier formula + clamps
      - applyCartRunSpeedSettings stamps opted-in types via DoParam
      - non-explicit (defaulted) registrations are never touched
      - registerCart derives runSpeedExplicit from the caller's data
      - first-party ShoppingCart registry base matches the item script (0.9)
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartData"

-- ============================================================================
-- HELPERS
-- ============================================================================

-- Run fn with a stubbed getScriptManager + SandboxVars.SaucedCarts, always
-- restoring globals even when fn throws (spy-leak gotcha: a stub restored
-- only on the success path poisons whichever test Kahlua runs next).
local function withEnv(penaltyMult, scripts, fn)
    local recorder = { params = {} }
    local sm = {
        getItem = function(self, fullType)
            local script = scripts[fullType]
            if script == nil then return nil end
            return {
                DoParam = function(_, str)
                    recorder.params[fullType] = str
                end,
            }
        end,
    }

    local origGetSM = getScriptManager
    local origSandbox = SandboxVars
    getScriptManager = function() return sm end
    SandboxVars = { SaucedCarts = { SpeedPenaltyMultiplier = penaltyMult } }

    local ok, result = pcall(fn, recorder)

    getScriptManager = origGetSM
    SandboxVars = origSandbox

    if not ok then error(result) end
    return result
end

-- Temporarily add a cart type entry directly to the registry, restore after.
local function withTempType(fullType, entry, fn)
    SaucedCarts.CartTypes[fullType] = entry
    local ok, result = pcall(fn)
    SaucedCarts.CartTypes[fullType] = nil
    if not ok then error(result) end
    return result
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

tests["compute_at_100_returns_base"] = function()
    return Assert.equal(SaucedCarts.computeRunSpeedModifier(0.9, 100), 0.9,
        "100% penalty multiplier must reproduce the base modifier")
end

tests["compute_at_0_removes_penalty"] = function()
    return Assert.equal(SaucedCarts.computeRunSpeedModifier(0.9, 0), 1.0,
        "0% multiplier means no penalty at all")
end

tests["compute_scales_penalty_not_speed"] = function()
    -- base 0.9 => penalty 0.1; 500% => penalty 0.5 => modifier 0.5
    return Assert.equal(SaucedCarts.computeRunSpeedModifier(0.9, 500), 0.5,
        "500% of a 0.1 penalty is a 0.5 penalty")
end

tests["compute_clamps_low_at_0_1"] = function()
    -- base 0.5 => penalty 0.5; 500% => penalty 2.5 => raw -1.5 => clamp 0.1
    return Assert.equal(SaucedCarts.computeRunSpeedModifier(0.5, 500), 0.1,
        "harsh base + max multiplier clamps at 0.1")
end

tests["compute_clamps_high_at_2_0"] = function()
    -- base 1.5 (speed BONUS cart, FIELD_RANGES allows up to 2.0):
    -- penalty -0.5; 500% => penalty -2.5 => raw 3.5 => clamp 2.0
    return Assert.equal(SaucedCarts.computeRunSpeedModifier(1.5, 500), 2.0,
        "bonus carts clamp at the 2.0 registry ceiling")
end

tests["compute_nil_mult_defaults_to_100"] = function()
    return Assert.equal(SaucedCarts.computeRunSpeedModifier(0.9, nil), 0.9,
        "missing sandbox value behaves as 100%")
end

tests["apply_stamps_shopping_cart_script"] = function()
    local param = withEnv(100, { ["SaucedCarts.ShoppingCart"] = true }, function(recorder)
        SaucedCarts.applyCartRunSpeedSettings()
        return recorder.params["SaucedCarts.ShoppingCart"]
    end)
    return Assert.equal(param, "RunSpeedModifier = 0.9000",
        "ShoppingCart script must be stamped with the base value at 100%")
end

tests["apply_honors_sandbox_multiplier"] = function()
    local param = withEnv(500, { ["SaucedCarts.ShoppingCart"] = true }, function(recorder)
        SaucedCarts.applyCartRunSpeedSettings()
        return recorder.params["SaucedCarts.ShoppingCart"]
    end)
    return Assert.equal(param, "RunSpeedModifier = 0.5000",
        "500% penalty must stamp 0.5 for the 0.9-base cart")
end

tests["apply_skips_non_explicit_types"] = function()
    local entry = { name = "Mystery Cart", runSpeedModifier = 0.75 }
    -- NOTE: no runSpeedExplicit — models an addon that fell back to defaults
    local param = withTempType("TestAddon.MysteryCart", entry, function()
        return withEnv(100, {
            ["SaucedCarts.ShoppingCart"] = true,
            ["TestAddon.MysteryCart"] = true,
        }, function(recorder)
            SaucedCarts.applyCartRunSpeedSettings()
            return recorder.params["TestAddon.MysteryCart"]
        end)
    end)
    return Assert.isNil(param,
        "defaulted registrations must never have their script stamped")
end

tests["apply_stamps_explicit_addon_types"] = function()
    local entry = { name = "Fast Cart", runSpeedModifier = 0.8, runSpeedExplicit = true }
    local param = withTempType("TestAddon.FastCart", entry, function()
        return withEnv(200, { ["TestAddon.FastCart"] = true }, function(recorder)
            SaucedCarts.applyCartRunSpeedSettings()
            return recorder.params["TestAddon.FastCart"]
        end)
    end)
    -- base 0.8 => penalty 0.2; 200% => 0.4 => modifier 0.6
    return Assert.equal(param, "RunSpeedModifier = 0.6000",
        "explicitly-declared addon types must be scaled from their own base")
end

tests["apply_survives_missing_script_item"] = function()
    local entry = { name = "Ghost Cart", runSpeedModifier = 0.9, runSpeedExplicit = true }
    local patched = withTempType("TestAddon.GhostCart", entry, function()
        return withEnv(100, { ["SaucedCarts.ShoppingCart"] = true }, function()
            -- GhostCart has no script item; must not throw, others still stamp
            return SaucedCarts.applyCartRunSpeedSettings()
        end)
    end)
    return Assert.equal(patched, 1,
        "missing script item is skipped without aborting the sweep")
end

tests["apply_without_scriptmanager_is_noop"] = function()
    local origGetSM = getScriptManager
    getScriptManager = nil
    local ok, patched = pcall(SaucedCarts.applyCartRunSpeedSettings)
    getScriptManager = origGetSM
    if not ok then error(patched) end
    return Assert.equal(patched, 0,
        "no ScriptManager (offline kit) must be a quiet no-op")
end

tests["register_cart_derives_explicit_flag"] = function()
    local okExplicit = SaucedCarts.registerCart("TestSpeed.Explicit", {
        name = "Explicit", runSpeedModifier = 0.85,
    })
    local okDefaulted = SaucedCarts.registerCart("TestSpeed.Defaulted", {
        name = "Defaulted",
    })
    local explicitFlag = SaucedCarts.CartTypes["TestSpeed.Explicit"]
        and SaucedCarts.CartTypes["TestSpeed.Explicit"].runSpeedExplicit
    local defaultedFlag = SaucedCarts.CartTypes["TestSpeed.Defaulted"]
        and SaucedCarts.CartTypes["TestSpeed.Defaulted"].runSpeedExplicit
    -- cleanup before asserting
    SaucedCarts.CartTypes["TestSpeed.Explicit"] = nil
    SaucedCarts.CartTypes["TestSpeed.Defaulted"] = nil
    return Assert.isTrue(
        okExplicit and okDefaulted and explicitFlag == true and defaultedFlag == false,
        "registerCart must set runSpeedExplicit=true only when the caller declared runSpeedModifier")
end

tests["first_party_base_is_0_9_and_explicit"] = function()
    -- Pins registry/script consistency: items_saucedcarts.txt declares
    -- RunSpeedModifier = 0.9 and CartData must match, since the registry is
    -- the base the sandbox scaling reads (the script field is unreadable
    -- from Lua). If you change one, change both — this test is the tripwire.
    local entry = SaucedCarts.CartTypes["SaucedCarts.ShoppingCart"]
    return Assert.isTrue(
        entry ~= nil and entry.runSpeedModifier == 0.9 and entry.runSpeedExplicit == true,
        "ShoppingCart registry base must be 0.9 and opted in to sandbox scaling")
end

return tests
