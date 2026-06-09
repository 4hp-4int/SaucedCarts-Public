--[[
    SaucedCarts/Tests/OfflineCartPoseTests.lua
    ==========================================

    Locks the cart-push pose animation-variable helpers (Core.lua) — the single
    source of truth used by the equip/unequip transitions, the per-frame
    self-heal in CartStateHandler, remote-player maintenance, late-joiner sync,
    and instant-drop.

    The self-heal exists because vanilla timed actions (eat/drink/reload/…) and
    the engine's network sync overwrite these variables without restoring ours;
    cartPoseDrifted + applyCartPose let a single per-frame check correct ANY
    clobber source without patching each action.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"

--- Minimal IsoGameCharacter mock backing setVariable/getVariableString.
--- Counts resetEquippedHandsModels calls (the model-rebind half of a restore).
local function mkChar(initial)
    local vars = {}
    if initial then for k, v in pairs(initial) do vars[k] = v end end
    local c = { _vars = vars, resetModelsCount = 0 }
    c.setVariable        = function(self, k, v) vars[k] = v end
    c.getVariableString  = function(self, k) return vars[k] or "" end
    c.resetEquippedHandsModels = function(self) self.resetModelsCount = self.resetModelsCount + 1 end
    return c
end

local tests = {}

tests["apply_sets_all_three_vars"] = function()
    local c = mkChar()
    SaucedCarts.applyCartPose(c)
    return Assert.equal(c._vars.Weapon, "cart", "Weapon=cart")
        and Assert.equal(c._vars.RightHandMask, "holdingcartright", "right mask")
        and Assert.equal(c._vars.LeftHandMask, "holdingcartleft", "left mask")
end

tests["clear_blanks_all_three_vars"] = function()
    local c = mkChar()
    SaucedCarts.applyCartPose(c)
    SaucedCarts.clearCartPose(c)
    return Assert.equal(c._vars.Weapon, "", "Weapon cleared")
        and Assert.equal(c._vars.RightHandMask, "", "right mask cleared")
        and Assert.equal(c._vars.LeftHandMask, "", "left mask cleared")
end

tests["drift_false_when_pose_applied"] = function()
    local c = mkChar()
    SaucedCarts.applyCartPose(c)
    return Assert.isFalse(SaucedCarts.cartPoseDrifted(c), "freshly applied pose is not drifted")
end

tests["drift_true_when_cleared"] = function()
    local c = mkChar()
    SaucedCarts.applyCartPose(c)
    SaucedCarts.clearCartPose(c)
    return Assert.isTrue(SaucedCarts.cartPoseDrifted(c), "cleared pose is drifted")
end

tests["drift_true_when_only_a_mask_clobbered"] = function()
    -- Simulates an eat/drink action that overwrites a hand mask but not Weapon.
    local c = mkChar()
    SaucedCarts.applyCartPose(c)
    c:setVariable("RightHandMask", "")  -- action clobber
    return Assert.isTrue(SaucedCarts.cartPoseDrifted(c), "a single clobbered mask counts as drift")
end

tests["drift_true_on_unset_vars"] = function()
    local c = mkChar()
    return Assert.isTrue(SaucedCarts.cartPoseDrifted(c), "never-applied character reads as drifted")
end

tests["nil_character_is_safe"] = function()
    -- No throw, drifted=false (nothing to correct).
    SaucedCarts.applyCartPose(nil)
    SaucedCarts.clearCartPose(nil)
    local inAction, restored = SaucedCarts.maintainCartPose(nil, true, false)
    return Assert.isFalse(SaucedCarts.cartPoseDrifted(nil), "nil character: no-op, not drifted")
        and Assert.isFalse(inAction, "maintainCartPose(nil): inAction false")
        and Assert.isFalse(restored, "maintainCartPose(nil): no restore")
end

-- =============================================================================
-- maintainCartPose: per-frame orchestration (the smoking/barricade bug)
-- =============================================================================
-- Simulates onPlayerUpdate's per-frame loop: caller threads wasInAction
-- through; the mock counts model rebinds.

--- Run one simulated frame; returns the new wasInAction + restored flags.
local function frame(c, wasInAction, inAction)
    return SaucedCarts.maintainCartPose(c, wasInAction, inAction)
end

tests["restore_fires_on_action_end_even_without_drift"] = function()
    -- THE shipped false-negative: the action never clobbers (or something
    -- healed) the pose VARIABLES, only the model binding. A drift-gated rebind
    -- skips this case; the action-finished edge must restore unconditionally.
    local c = mkChar()
    SaucedCarts.applyCartPose(c)              -- vars correct the whole time
    local was = frame(c, nil, true)           -- action running
    local _, restored = frame(c, was, false)  -- action just finished
    return Assert.isTrue(restored, "edge restore fired despite no var drift")
        and Assert.equal(c.resetModelsCount, 1, "model rebound exactly once")
end

tests["no_touch_while_action_running"] = function()
    -- Mid-action the action owns the animation: even with clobbered vars we
    -- must not fight it (no var re-apply, no model rebind).
    local c = mkChar()
    SaucedCarts.applyCartPose(c)
    local was = frame(c, nil, true)
    c:setVariable("Weapon", "")               -- action clobbers mid-run
    local restored
    was, restored = frame(c, was, true)
    return Assert.isFalse(restored, "no restore mid-action")
        and Assert.equal(c._vars.Weapon, "", "clobbered var left alone mid-action")
        and Assert.equal(c.resetModelsCount, 0, "no model rebind mid-action")
        and Assert.isTrue(was, "inAction carried forward")
end

tests["full_action_lifecycle_restores_exactly_once"] = function()
    -- idle -> action starts + clobbers -> runs -> finishes -> idle.
    -- One restore, on the finish edge; vars correct after; idle frames quiet.
    local c = mkChar()
    SaucedCarts.applyCartPose(c)
    local was, restored = frame(c, nil, false)            -- idle, healthy
    local idleQuiet = (restored == false)
    was = frame(c, was, true)                             -- action starts
    c:setVariable("Weapon", "")                           -- and clobbers
    c:setVariable("RightHandMask", "")
    was = frame(c, was, true)                             -- still running
    was, restored = frame(c, was, false)                  -- finished
    local edgeFired = restored
    local _, after = frame(c, was, false)                 -- idle again
    return Assert.isTrue(idleQuiet, "healthy idle frame does nothing")
        and Assert.isTrue(edgeFired, "restore fired on the finish edge")
        and Assert.isFalse(after, "no second restore on the next idle frame")
        and Assert.equal(c.resetModelsCount, 1, "exactly one model rebind")
        and Assert.isFalse(SaucedCarts.cartPoseDrifted(c), "pose vars restored")
end

tests["idle_drift_heals_with_model_rebind"] = function()
    -- Outside actions (engine sync etc. clobbers): drift triggers a full
    -- restore, then goes quiet once healthy.
    local c = mkChar()
    SaucedCarts.applyCartPose(c)
    c:setVariable("LeftHandMask", "")         -- non-action clobber
    local was, restored = frame(c, nil, false)
    local healed = restored
    local _, again = frame(c, was, false)
    return Assert.isTrue(healed, "idle drift restored")
        and Assert.isFalse(again, "quiet once healed")
        and Assert.equal(c.resetModelsCount, 1, "one model rebind for the heal")
        and Assert.isFalse(SaucedCarts.cartPoseDrifted(c), "vars healed")
end

tests["restore_pose_tolerates_missing_reset_method"] = function()
    -- Server-side / mock characters may lack resetEquippedHandsModels;
    -- restoreCartPose must still set the vars without throwing.
    local c = mkChar()
    c.resetEquippedHandsModels = nil
    SaucedCarts.restoreCartPose(c)
    return Assert.isFalse(SaucedCarts.cartPoseDrifted(c), "vars applied without reset method")
end

return tests
