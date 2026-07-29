--[[
    SaucedCarts — Door-only E key (context key) tests
    =================================================

    v2.1.13: pushing a cart no longer sets player:setIgnoreContextKey(true)
    (which killed the whole E dispatcher, doors included). Instead the E key
    stays live and ContextActionRestrictions wraps the Lua-dispatched entries
    of the global ContextualActionHandlers table (ISContextualActions.lua),
    blocking movement/interaction actions for cart pushers while leaving
    doors untouched (ToggleDoor is Java-direct and never reaches Lua anyway;
    OpenDoor/CloseDoor cover the controller B-prompt path).

    These tests lock:
      - every BLOCKED action is gated when the acting player pushes a cart
      - the same actions pass through untouched (args intact) without a cart
      - door and curtain handlers are never wrapped
      - a broken cart check fails OPEN (vanilla handler still runs)
      - install() is idempotent (no double-wrap, no double-dispatch)
      - the gate is per-player (splitscreen: pusher blocked, other passes)
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"

-- The module wraps the global handler table at install time. Build a
-- recording stand-in for vanilla's table BEFORE requiring the module so
-- install() has real functions to wrap.
local HANDLER_NAMES = {
    "ClimbOverFence", "ClimbSheetRope", "ClimbThroughWindow",
    "CloseCurtain", "CloseDoor", "CloseWindow",
    "OpenCurtain", "OpenDoor", "OpenWindow",
    "OpenButcherHook", "OpenHutch", "AnimalsInteraction", "SleepInBed",
}

local callLog = {}   -- callLog[name] = { {action, playerObj, arg1..arg4}, ... }

ContextualActionHandlers = {}
local originalHandlers = {}
for _, name in ipairs(HANDLER_NAMES) do
    callLog[name] = {}
    local handler = function(action, playerObj, arg1, arg2, arg3, arg4)
        table.insert(callLog[name], { action, playerObj, arg1, arg2, arg3, arg4 })
    end
    ContextualActionHandlers[name] = handler
    originalHandlers[name] = handler
end

local ContextActionRestrictions = require "SaucedCarts/Restrictions/ContextActionRestrictions"
ContextActionRestrictions.install()

-- ============================================================================
-- MOCKS
-- ============================================================================

local function makeCart()
    return {
        _fullType = "SaucedCarts.ShoppingCart",
        _type = "InventoryContainer",
        getID = function(self) return 200 end,
        getFullType = function(self) return self._fullType end,
    }
end

--- Player mock. opts.cart -> holding a cart; opts.brokenHands -> the
--- getPrimaryHandItem call errors (exercises the fail-open pcall).
local function makePlayer(opts)
    opts = opts or {}
    return {
        _primary = opts.cart and makeCart() or opts.primary,
        getPrimaryHandItem = function(self)
            if opts.brokenHands then error("simulated java-boundary error") end
            return self._primary
        end,
        getPlayerNum = function(self) return opts.playerNum or 0 end,
        getIndex = function(self) return opts.playerNum or 0 end,
    }
end

-- Extend safeIsCart so the Lua-table mock cart qualifies (same pattern as
-- OfflineDropActionTests).
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item._fullType and item._fullType:find("^SaucedCarts") then
        return true
    end
    return origSafeIsCart(item)
end

local function resetLog()
    for _, name in ipairs(HANDLER_NAMES) do
        callLog[name] = {}
    end
end

local function dispatch(name, playerObj, arg1, arg2, arg3, arg4)
    ContextualActionHandlers[name](name, playerObj, arg1, arg2, arg3, arg4)
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

tests["install_wraps_every_blocked_action"] = function()
    for _, name in ipairs(ContextActionRestrictions.BLOCKED_ACTIONS) do
        if ContextualActionHandlers[name] == originalHandlers[name] then
            return false, "blocked action not wrapped: " .. name
        end
    end
    return true
end

tests["door_and_curtain_handlers_never_wrapped"] = function()
    for _, name in ipairs({ "OpenDoor", "CloseDoor", "OpenCurtain", "CloseCurtain" }) do
        if ContextualActionHandlers[name] ~= originalHandlers[name] then
            return false, "allowed handler was wrapped: " .. name
        end
    end
    return true
end

tests["cart_pusher_blocked_from_every_gated_action"] = function()
    resetLog()
    local pusher = makePlayer({ cart = true })
    for _, name in ipairs(ContextActionRestrictions.BLOCKED_ACTIONS) do
        dispatch(name, pusher)
        if #callLog[name] ~= 0 then
            return false, "vanilla handler ran for cart pusher: " .. name
        end
    end
    return true
end

tests["cartless_player_passes_through_with_args_intact"] = function()
    resetLog()
    local walker = makePlayer({})
    local fence, dir = { tag = "fence" }, { tag = "dir" }
    dispatch("ClimbOverFence", walker, fence, dir)

    if #callLog.ClimbOverFence ~= 1 then
        return false, "expected exactly one vanilla dispatch, got " .. #callLog.ClimbOverFence
    end
    local call = callLog.ClimbOverFence[1]
    return Assert.isTrue(
        call[1] == "ClimbOverFence" and call[2] == walker
            and call[3] == fence and call[4] == dir,
        "action name, player, and args must pass through unmodified"
    )
end

tests["door_dispatch_unaffected_even_while_pushing"] = function()
    -- Controller B-prompt path: OpenDoor/CloseDoor dispatch through the
    -- same table. Cart pushers must still get doors.
    resetLog()
    local pusher = makePlayer({ cart = true })
    local door = { tag = "door" }
    dispatch("OpenDoor", pusher, door)
    dispatch("CloseDoor", pusher, door)
    return Assert.isTrue(
        #callLog.OpenDoor == 1 and #callLog.CloseDoor == 1,
        "door handlers must run for a cart pusher"
    )
end

tests["broken_cart_check_fails_open"] = function()
    -- If the hand probe errors (Java-boundary weirdness, NPC subclass,
    -- whatever), the gate must NOT eat the action — vanilla runs.
    resetLog()
    local glitchy = makePlayer({ brokenHands = true })
    dispatch("ClimbThroughWindow", glitchy, { tag = "window" })
    return Assert.equal(#callLog.ClimbThroughWindow, 1,
        "handler must run when the cart check itself errors")
end

tests["non_cart_primary_item_does_not_block"] = function()
    resetLog()
    local armed = makePlayer({ primary = { getFullType = function() return "Base.Axe" end } })
    dispatch("OpenWindow", armed, { tag = "window" })
    return Assert.equal(#callLog.OpenWindow, 1,
        "holding a non-cart item must not gate the context key")
end

tests["install_is_idempotent"] = function()
    -- A second install() must not re-wrap: exactly ONE vanilla dispatch
    -- per cartless action, and pushers still blocked.
    ContextActionRestrictions.install()
    resetLog()
    local walker = makePlayer({})
    dispatch("SleepInBed", walker, { tag = "bed" })
    if #callLog.SleepInBed ~= 1 then
        return false, "double-install caused " .. #callLog.SleepInBed .. " dispatches"
    end
    local pusher = makePlayer({ cart = true })
    dispatch("SleepInBed", pusher, { tag = "bed" })
    return Assert.equal(#callLog.SleepInBed, 1,
        "pusher must stay blocked after second install()")
end

tests["gate_is_per_player_splitscreen"] = function()
    resetLog()
    local pusher = makePlayer({ cart = true, playerNum = 0 })
    local walker = makePlayer({ playerNum = 1 })
    dispatch("ClimbOverFence", pusher, { tag = "fence" })
    dispatch("ClimbOverFence", walker, { tag = "fence" })
    return Assert.equal(#callLog.ClimbOverFence, 1,
        "only the cartless player's climb should dispatch")
end

tests["blocked_list_matches_vanilla_movement_actions"] = function()
    -- Sanity-lock the list itself: if a future edit drops a climb action
    -- from BLOCKED_ACTIONS, this fails loudly.
    local required = {
        ClimbOverFence = true, ClimbSheetRope = true, ClimbThroughWindow = true,
        OpenWindow = true, CloseWindow = true,
        OpenButcherHook = true, OpenHutch = true,
        AnimalsInteraction = true, SleepInBed = true,
    }
    local seen = {}
    for _, name in ipairs(ContextActionRestrictions.BLOCKED_ACTIONS) do
        seen[name] = true
        if not required[name] then
            return false, "unexpected action in BLOCKED_ACTIONS: " .. name
        end
    end
    for name in pairs(required) do
        if not seen[name] then
            return false, "missing action in BLOCKED_ACTIONS: " .. name
        end
    end
    return true
end

return tests
