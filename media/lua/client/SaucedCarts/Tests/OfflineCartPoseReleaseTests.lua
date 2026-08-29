--[[
    SaucedCarts/Tests/OfflineCartPoseReleaseTests.lua
    =================================================

    Locks the RELEASE half of the cart-push pose contract: when a cart stops
    being held, Weapon / RightHandMask / LeftHandMask end up blank — by
    whatever route the cart left the hands, including the routes where the
    put-down FAILED and the cart is still sitting in the player's inventory.

    Why this file exists (B42.20 dedi bug report, 2026-08-22):
    the reporter's put-down sometimes lands the cart in the player's main
    inventory instead of the world, and concluded that "we found no reset for
    those three variables in the codebase", so the failure path leaves the
    cart-grip pose stuck forever.

    The reset does exist — SaucedCarts.clearCartPose (Core.lua) — and the
    load-bearing caller is NOT any individual put-down path: it is
    CartStateHandler's per-frame hand-state transition
    (CartStateHandler.lua, "just unequipped a cart" branch). That branch is
    driven off getPrimaryHandItem(), so it fires for EVERY way a cart can
    leave the hands, successful drop or not. OfflineCartPoseTests covers the
    pure helpers; nothing covered the wiring, which is the part the report is
    actually about.

    Each test therefore doubles as an assertion about the report: if the
    put-down failure path really did strand the pose, these would fail.

    Sensitivity: neuter the `SaucedCarts.clearCartPose(player)` call in
    CartStateHandler's unequip branch and tests 1-3 fail. Delete the
    `InstantDrop.isPending` early return and test 4 still passes (it asserts
    the pose is clear THROUGH the window, not because of it); make
    isPending() permanently true and test 4 fails.
]]

if isServer() and not isClient() then return end

if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/Network"
local Throttle    = require "SaucedCarts/CartState/AnimationSync/Throttle"
local InstantDrop = require "SaucedCarts/CartState/InstantDrop"
require "SaucedCarts/CartStateHandler"

-- ============================================================================
-- HARNESS
-- ============================================================================
-- Owns the clock, the isClient gate and the outbound-command spy, and always
-- restores them — a spy left installed poisons whichever test runs next, and
-- Kahlua's pairs order makes that non-deterministic.

local function withHarness(fn)
    local origSend     = SaucedCarts.Network.sendToServer
    local origTime     = getTimestampMs
    local origIsClient = isClient

    local sent = {}
    local now  = 500000

    _G.getTimestampMs = function() return now end
    _G.isClient = function() return true end
    SaucedCarts.Network.sendToServer = function(player, command, args)
        table.insert(sent, { command = command, args = args })
    end

    Throttle.reset()
    InstantDrop.reset()

    local ok, err = pcall(function()
        fn({
            sent    = sent,
            advance = function(ms) now = now + ms end,
        })
    end)

    Throttle.reset()
    InstantDrop.reset()
    SaucedCarts.Network.sendToServer = origSend
    _G.getTimestampMs = origTime
    _G.isClient = origIsClient

    if not ok then error(err) end
end

-- ============================================================================
-- FIXTURES
-- ============================================================================

local function mkCart(id)
    local c = { _id = id, _modData = {}, _worldItem = nil }
    c.getID        = function(self) return self._id end
    c.getModData   = function(self) return self._modData end
    c.getType      = function() return "ShoppingCart" end
    c.getWorldItem = function(self) return self._worldItem end
    return c
end

--- Player whose hands and main inventory are set independently, so a test can
--- model the reported failure shape: cart OUT of the hands but STILL in the
--- inventory (no world item was ever created).
local function mkPlayer(onlineId, cart)
    local sq = {}
    sq.getX = function() return 0 end
    sq.getY = function() return 0 end
    sq.getZ = function() return 0 end

    local inv = { _items = {} }
    inv.contains = function(self, item)
        for _, it in ipairs(self._items) do if it == item then return true end end
        return false
    end

    local p = { _vars = {}, _cart = cart, _onlineId = onlineId, _inv = inv, _aiming = false }
    p.isDead                   = function(self) return false end
    p.getCurrentSquare         = function(self) return sq end
    p.getOnlineID              = function(self) return self._onlineId end
    p.getPlayerNum             = function(self) return 0 end
    p.getPrimaryHandItem       = function(self) return self._cart end
    p.getSecondaryHandItem     = function(self) return self._cart end
    p.setVariable              = function(self, k, v) self._vars[k] = v end
    p.getVariableString        = function(self, k) return self._vars[k] or "" end
    p.resetEquippedHandsModels = function(self) end
    p.setIgnoreAutoVault       = function(self, v) self._ignoreAutoVault = v end
    p.setIgnoreContextKey      = function(self, v) end
    p.isSneaking               = function(self) return false end
    p.setSneaking              = function(self, v) end
    p.isAiming                 = function(self) return self._aiming end
    p.getX                     = function(self) return 0 end
    p.getY                     = function(self) return 0 end
    p.getInventory             = function(self) return self._inv end

    -- The cart is in the inventory the whole time it is equipped (PZ keeps
    -- equipped items in the container); the tests only move the HAND ref.
    if cart then table.insert(inv._items, cart) end
    return p
end

--- Run one OnPlayerUpdate frame with cart-detection forced onto our table
--- fixtures (SaucedCarts.isCart hard-rejects non-userdata).
local function pumpFrame(player, cart)
    local origIsCart     = SaucedCarts.isCart
    local origSafeIsCart = SaucedCarts.safeIsCart
    SaucedCarts.isCart     = function(item) return item ~= nil and item == cart end
    SaucedCarts.safeIsCart = SaucedCarts.isCart

    local ok, err = pcall(function()
        triggerEvent("OnPlayerUpdate", player)
    end)

    SaucedCarts.isCart     = origIsCart
    SaucedCarts.safeIsCart = origSafeIsCart
    if not ok then error(err) end
end

local function poseIsClear(player)
    return player:getVariableString("Weapon") == ""
       and player:getVariableString("RightHandMask") == ""
       and player:getVariableString("LeftHandMask") == ""
end

local function poseIsCartGrip(player)
    return player:getVariableString("Weapon") == "cart"
       and player:getVariableString("RightHandMask") == "holdingcartright"
       and player:getVariableString("LeftHandMask") == "holdingcartleft"
end

local tests = {}

-- ============================================================================
-- 1. BASELINE: a clean put-down clears the pose
-- ============================================================================

tests["release_to_world_clears_pose"] = function()
    local result
    withHarness(function(h)
        local cart   = mkCart(7101)
        local player = mkPlayer(701, cart)

        pumpFrame(player, cart)
        local gripped = poseIsCartGrip(player)

        -- Successful drop: out of the hands, out of the inventory, into the world.
        player._cart = nil
        player._inv._items = {}
        cart._worldItem = {}
        h.advance(300)
        pumpFrame(player, cart)

        result = Assert.isTrue(gripped, "pose applied while pushing")
            and Assert.isTrue(poseIsClear(player), "pose cleared once the cart is on the ground")
    end)
    return result
end

-- ============================================================================
-- 2. THE REPORTED FAILURE SHAPE: cart lands in main inventory, not the world
-- ============================================================================
-- This is the exact state the B42.20 reporter describes — the cart is out of
-- the hands, no world item was ever created, and the cart is still in the
-- player's main inventory at full weight. The report claims the pose is
-- stranded here. The hand-state transition says otherwise.

tests["failed_putdown_into_inventory_clears_pose"] = function()
    local result
    withHarness(function(h)
        local cart   = mkCart(7102)
        local player = mkPlayer(702, cart)

        pumpFrame(player, cart)
        local gripped = poseIsCartGrip(player)

        -- Put-down failed: hands released, world item never created, cart
        -- still sitting in the inventory.
        player._cart = nil
        h.advance(300)
        pumpFrame(player, cart)

        result = Assert.isTrue(gripped, "pose applied while pushing")
            and Assert.isTrue(player:getInventory():contains(cart),
                "fixture models the report: cart is still in the main inventory")
            and Assert.equal(cart:getWorldItem(), nil,
                "fixture models the report: no world item was created")
            and Assert.isTrue(poseIsClear(player),
                "pose is cleared by the hand transition even though the drop failed")
    end)
    return result
end

-- ============================================================================
-- 3. THE POSE STAYS CLEAR — no per-frame re-apply after release
-- ============================================================================
-- A clear that gets undone one frame later is the same bug with extra steps:
-- maintainCartPose's drift heal must not fire for a player who no longer
-- holds a cart.

tests["pose_stays_clear_on_later_frames"] = function()
    local result
    withHarness(function(h)
        local cart   = mkCart(7103)
        local player = mkPlayer(703, cart)

        pumpFrame(player, cart)
        player._cart = nil
        h.advance(300)
        pumpFrame(player, cart)

        local clearedAtRelease = poseIsClear(player)
        for _ = 1, 5 do pumpFrame(player, cart) end

        result = Assert.isTrue(clearedAtRelease, "cleared on the release frame")
            and Assert.isTrue(poseIsClear(player),
                "still clear five frames later — no drift heal re-grips a cartless player")
    end)
    return result
end

-- ============================================================================
-- 4. THE PENDING-DROP EARLY RETURN DOES NOT STRAND THE POSE
-- ============================================================================
-- onPlayerUpdate early-returns while InstantDrop.isPending, which is the one
-- window where the unequip transition is skipped. InstantDrop.handle clears
-- the pose itself on the way in, and the window self-expires at 1000ms — so
-- the pose is clear THROUGH the window and the transition still resolves
-- after it. Pin both halves: a pending flag that never expired would be a
-- genuine stuck-pose vector.

tests["instant_drop_pending_window_does_not_strand_pose"] = function()
    local result
    withHarness(function(h)
        local cart   = mkCart(7104)
        local player = mkPlayer(704, cart)

        pumpFrame(player, cart)
        local gripped = poseIsCartGrip(player)

        -- Aiming triggers the MP instant drop request.
        player._aiming = true
        h.advance(300)
        pumpFrame(player, cart)

        local requested = false
        for _, p in ipairs(h.sent) do
            if p.command == "requestInstantDrop" then requested = true end
        end
        local clearInWindow = poseIsClear(player)

        -- Still inside the 1s window: onPlayerUpdate early-returns.
        h.advance(200)
        pumpFrame(player, cart)
        local stillClear = poseIsClear(player)

        -- Server processed the drop; window expires; transition resolves.
        player._aiming = false
        player._cart = nil
        player._inv._items = {}
        h.advance(1500)
        pumpFrame(player, cart)

        result = Assert.isTrue(gripped, "pose applied while pushing")
            and Assert.isTrue(requested, "aiming requested the server-side instant drop")
            and Assert.isTrue(clearInWindow, "InstantDrop cleared the pose on request")
            and Assert.isTrue(stillClear, "pose stays clear inside the pending window")
            and Assert.isTrue(poseIsClear(player), "pose clear after the window expires")
    end)
    return result
end

-- ============================================================================
-- 5. PRECISION: still holding means still gripped
-- ============================================================================
-- The counterpart contract — the release clear must not fire for a player who
-- is genuinely still pushing, or the pose would flicker every frame.

tests["holding_cart_keeps_grip_pose"] = function()
    local result
    withHarness(function(h)
        local cart   = mkCart(7105)
        local player = mkPlayer(705, cart)

        pumpFrame(player, cart)
        h.advance(300)
        pumpFrame(player, cart)
        pumpFrame(player, cart)

        result = Assert.isTrue(poseIsCartGrip(player),
            "a player still holding the cart keeps the grip pose")
    end)
    return result
end

return tests
