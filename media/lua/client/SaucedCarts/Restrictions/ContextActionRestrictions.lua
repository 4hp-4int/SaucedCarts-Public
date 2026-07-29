-- ============================================================================
-- SaucedCarts/Restrictions/ContextActionRestrictions.lua
-- ============================================================================
-- PURPOSE: Allow the E key (context key) while pushing a cart, but restrict
--          it to doors only.
--
-- CONTEXT: CLIENT ONLY
--
-- DESIGN: Vanilla's E key flows through IsoPlayer.doContext() (Java), which
--         picks one contextual action and dispatches it. The actions split
--         into two classes:
--
--           - ToggleDoor is a DIRECT Java call (IsoDoor/IsoThumpable
--             .ToggleDoor) — we cannot block it, and we don't want to.
--           - Every movement/interaction action (climb fence/wall/window/
--             rope, open window, sleep, hutch, animals, butcher hook)
--             dispatches through the Lua global table
--             ContextualActionHandlers (ISContextualActions.lua).
--
--         So instead of player:setIgnoreContextKey(true) — which killed the
--         whole dispatcher, doors included — CartStateHandler leaves the
--         context key enabled and this module gates the Lua-dispatched
--         handlers on "is this player pushing a cart".
--
--         The one movement action dispatched Java-direct, ClimbOverWall, is
--         already suppressed by setIgnoreAutoVault(true) (doContextClimbOverWall
--         bails on the ignoreAutoVault flag before considering the climb),
--         which CartStateHandler still sets. Verified against decompiled
--         IsoPlayer.doContext / performContextualAction / doContextClimbOverWall.
--
--         The controller B-prompt (ISButtonPrompt) routes through the same
--         handler table via triggerContextualAction, so gamepad users get
--         the same door-only behavior for free.
--
-- SAFETY: All hooks are wrapped in pcall. If our cart check errors, the
--         original vanilla handler runs unaffected.
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Notifications"

---@class SaucedCartsContextActionRestrictions
local ContextActionRestrictions = {}

-- Handlers blocked while pushing a cart. Doors (OpenDoor/CloseDoor) are
-- deliberately absent — they're the point of this module. Curtains
-- (Open/CloseCurtain) are absent too: curtains on DOORS toggle via a direct
-- Java call (IsoDoor.toggleCurtain) that Lua can't intercept, so blocking
-- only window curtains would be inconsistent — and neither moves the player.
local BLOCKED_ACTIONS = {
    "ClimbOverFence",
    "ClimbSheetRope",
    "ClimbThroughWindow",
    "OpenWindow",
    "CloseWindow",
    "OpenButcherHook",
    "OpenHutch",
    "AnimalsInteraction",
    "SleepInBed",
}

--- Is this player currently pushing a cart? Errors default to "no" so a
--- broken check can never lock a cartless player out of vanilla actions.
---@param playerObj IsoPlayer|nil
---@return boolean
function ContextActionRestrictions.isPushingCart(playerObj)
    local pushing = false
    pcall(function()
        local primary = playerObj and playerObj:getPrimaryHandItem()
        if primary and SaucedCarts.safeIsCart(primary) then
            pushing = true
        end
    end)
    return pushing
end

local hooksInitialized = false

--- Wrap the blocked entries of the global ContextualActionHandlers table.
--- Idempotent; safe to call again after a failed first attempt.
function ContextActionRestrictions.install()
    if hooksInitialized then return end

    if type(ContextualActionHandlers) ~= "table" then
        SaucedCarts.debug("ContextActionRestrictions: ContextualActionHandlers not found, skipping")
        return
    end

    for _, actionName in ipairs(BLOCKED_ACTIONS) do
        local original = ContextualActionHandlers[actionName]
        if type(original) == "function" then
            ContextualActionHandlers[actionName] = function(action, playerObj, arg1, arg2, arg3, arg4)
                if ContextActionRestrictions.isPushingCart(playerObj) then
                    pcall(function()
                        if SaucedCarts.Notifications then
                            SaucedCarts.Notifications.cantDoThatWithCart(playerObj)
                        end
                    end)
                    SaucedCarts.debug(function()
                        return "Blocked contextual action while pushing cart: " .. tostring(action)
                    end)
                    return
                end
                return original(action, playerObj, arg1, arg2, arg3, arg4)
            end
        end
    end

    hooksInitialized = true
    SaucedCarts.debug("ContextActionRestrictions: door-only context key hooks installed")
end

local function onGameStart()
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end
    ContextActionRestrictions.install()
end

Events.OnGameStart.Add(onGameStart)

-- ============================================================================
-- DEBUG API
-- ============================================================================

function ContextActionRestrictions.isInitialized()
    return hooksInitialized
end

--- Exposed for tests: the list of handler names this module gates.
ContextActionRestrictions.BLOCKED_ACTIONS = BLOCKED_ACTIONS

SaucedCarts.ContextActionRestrictions = ContextActionRestrictions

SaucedCarts.debug("ContextActionRestrictions module loaded")

return ContextActionRestrictions
