--[[
    SaucedCarts — MP cart-pose announcement tests
    =============================================

    Locks the fix for the player report: "in multiplayer, when my friends use
    'Take in both hands' instead of Push, the cart is displayed wrong (carried
    like a weapon and clips through the ground)".

    Root cause being locked: the animation broadcast was gated on
    SaucedCarts.Events.onCartEquip, which fires ONLY from our own
    ISCartEquipAction / ISCartPickupAction. The cart script sets
    RequiresEquippedBothHands, so vanilla also offers "Equip in Both Hands"
    (ISInventoryPaneContextMenu.lua:428). Equipping that way produces the exact
    same hand state our own action produces, but fired no event — so no
    syncCartAnimation reached the server, the server never broadcast
    updateCartAnimation, and observer clients never added the player to
    RemotePlayer's re-application loop. The engine's Weapon=UNARMED overwrite
    (IsoPlayer network sync) then stuck, and the cart rendered as a held weapon.
    The local player was unaffected because their pose is polled off hand state
    — hence "my friends look wrong to me" but fine to themselves.

    The fix: CartStateHandler announces off the hand-state TRANSITION (which
    every equip path reaches), and Throttle.send is level-triggered so the
    event listener firing first for our own flow makes it a no-op.

    Sensitivity: transition_announces_equip_without_our_event fails against
    pre-fix code (zero packets — nothing announced a vanilla equip), and the
    duplicate-suppression tests fail against a Throttle without the level
    trigger (two packets where one is correct).
]]

if isServer() and not isClient() then return end

if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/Network"
local Throttle = require "SaucedCarts/CartState/AnimationSync/Throttle"
require "SaucedCarts/CartStateHandler"

-- ============================================================================
-- HARNESS
-- ============================================================================
-- Owns the clock, the isClient gate and the outbound-command spy. Restores
-- everything even when the body throws — a spy left installed poisons whichever
-- test runs next, and Kahlua's pairs order makes that non-deterministic.

local function withHarness(fn)
    local origSend     = SaucedCarts.Network.sendToServer
    local origTime     = getTimestampMs
    local origIsClient = isClient

    local sent = {}
    local now  = 100000

    _G.getTimestampMs = function() return now end
    _G.isClient = function() return true end
    SaucedCarts.Network.sendToServer = function(player, command, args)
        table.insert(sent, { command = command, args = args })
    end

    Throttle.reset()

    local ok, err = pcall(function()
        fn({
            sent    = sent,
            advance = function(ms) now = now + ms end,
        })
    end)

    Throttle.reset()
    SaucedCarts.Network.sendToServer = origSend
    _G.getTimestampMs = origTime
    _G.isClient = origIsClient

    if not ok then error(err) end
end

--- Minimal sender: Throttle only needs the online ID off the player.
local function mkSender(onlineId)
    return { getOnlineID = function(self) return onlineId end }
end

local function animPackets(sent)
    local n = 0
    for _, p in ipairs(sent) do
        if p.command == "syncCartAnimation" then n = n + 1 end
    end
    return n
end

local tests = {}

-- ============================================================================
-- THROTTLE: LEVEL-TRIGGERED ANNOUNCEMENT
-- ============================================================================
-- The announcement now has two callers (our equip/drop events AND the hand
-- transition). Both are level-triggered downstream — the server's equippedState
-- table and each observer's RemotePlayer tracking are set-to-state, not
-- toggles — so a repeat of the state already announced is pure packet noise.

tests["first_announcement_sends_syncCartAnimation"] = function()
    local result
    withHarness(function(h)
        Throttle.send(mkSender(101), true)
        result = Assert.equal(animPackets(h.sent), 1, "one packet for the first announcement")
            and Assert.equal(h.sent[1].command, "syncCartAnimation", "command name")
            and Assert.isTrue(h.sent[1].args.hasCart, "hasCart=true")
            and Assert.equal(h.sent[1].args.playerOnlineId, 101, "carries the online id")
    end)
    return result
end

tests["duplicate_state_suppressed_within_cooldown"] = function()
    local result
    withHarness(function(h)
        local p = mkSender(102)
        Throttle.send(p, true)
        Throttle.send(p, true)   -- e.g. onCartEquip listener, then the transition
        result = Assert.equal(animPackets(h.sent), 1, "second identical announcement is dropped")
            and Assert.equal(Throttle.getPendingCount(), 0, "and nothing was queued for later")
    end)
    return result
end

tests["duplicate_state_suppressed_after_cooldown"] = function()
    local result
    withHarness(function(h)
        local p = mkSender(103)
        Throttle.send(p, true)
        h.advance(5000)          -- well past the 250ms window
        Throttle.send(p, true)
        result = Assert.equal(animPackets(h.sent), 1,
            "state is unchanged, so the cooldown expiring does not license a resend")
    end)
    return result
end

tests["state_change_announces_again"] = function()
    local result
    withHarness(function(h)
        local p = mkSender(104)
        Throttle.send(p, true)
        h.advance(5000)
        Throttle.send(p, false)
        result = Assert.equal(animPackets(h.sent), 2, "the change is announced")
            and Assert.isFalse(h.sent[2].args.hasCart, "second packet clears the cart")
    end)
    return result
end

tests["rapid_flip_queues_rather_than_dropping"] = function()
    local result
    withHarness(function(h)
        local p = mkSender(105)
        Throttle.send(p, true)
        h.advance(50)            -- inside the cooldown
        Throttle.send(p, false)
        result = Assert.equal(animPackets(h.sent), 1, "the flip is not sent yet")
            and Assert.equal(Throttle.getPendingCount(), 1, "it is queued")
            and Assert.isTrue(Throttle.getLastState(105), "last ANNOUNCED state is still true")
    end)
    return result
end

tests["pending_intent_suppresses_its_own_duplicate"] = function()
    local result
    withHarness(function(h)
        local p = mkSender(106)
        Throttle.send(p, true)
        h.advance(50)
        Throttle.send(p, false)  -- queued
        Throttle.send(p, false)  -- same intent, must not queue a second time
        result = Assert.equal(Throttle.getPendingCount(), 1, "one pending entry, not two")
    end)
    return result
end

tests["cleanup_allows_a_fresh_announcement"] = function()
    local result
    withHarness(function(h)
        local p = mkSender(107)
        Throttle.send(p, true)
        Throttle.cleanup(107)
        h.advance(5000)
        Throttle.send(p, true)
        result = Assert.equal(animPackets(h.sent), 2,
            "after cleanup (death / relog) the state is unknown again, so re-announce")
    end)
    return result
end

-- ============================================================================
-- WIRING: THE HAND TRANSITION ANNOUNCES, NOT JUST OUR OWN EQUIP EVENT
-- ============================================================================
-- This is the actual reported bug. The fixture NEVER fires
-- SaucedCarts.Events.onCartEquip — it just puts a cart in the player's hand,
-- exactly as vanilla's OnTwoHandsEquip does.

local function mkCart(id)
    local c = { _id = id, _modData = {} }
    c.getID      = function(self) return self._id end
    c.getModData = function(self) return self._modData end
    c.getType    = function() return "ShoppingCart" end
    return c
end

local function mkPlayer(onlineId, cart)
    local sq = {}
    sq.getX = function() return 0 end
    sq.getY = function() return 0 end
    sq.getZ = function() return 0 end

    local p = { _vars = {}, _cart = cart, _onlineId = onlineId }
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
    p.isAiming                 = function(self) return false end
    p.getX                     = function(self) return 0 end
    p.getY                     = function(self) return 0 end
    p.getInventory             = function(self) return nil end
    return p
end

--- Run one OnPlayerUpdate frame with cart-detection forced on our table
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

tests["transition_announces_equip_without_our_event"] = function()
    local result
    withHarness(function(h)
        local cart   = mkCart(9001)
        local player = mkPlayer(201, cart)

        pumpFrame(player, cart)   -- cart appears in hand; no onCartEquip fired

        result = Assert.equal(animPackets(h.sent), 1,
            "a cart equipped outside our own action still announces to the server")
            and Assert.isTrue(h.sent[1].args.hasCart, "announced as hasCart=true")
            and Assert.equal(h.sent[1].args.playerOnlineId, 201, "for the right player")
    end)
    return result
end

tests["transition_announces_unequip_without_our_event"] = function()
    local result
    withHarness(function(h)
        local cart   = mkCart(9002)
        local player = mkPlayer(202, cart)

        pumpFrame(player, cart)
        h.advance(300)            -- past the throttle window, so this sends now
        player._cart = nil        -- cart leaves the hand; no onCartDrop fired
        pumpFrame(player, cart)

        result = Assert.equal(animPackets(h.sent), 2, "the unequip is announced too")
            and Assert.isFalse(h.sent[2].args.hasCart, "announced as hasCart=false")
    end)
    return result
end

tests["transition_does_not_re_announce_while_holding"] = function()
    local result
    withHarness(function(h)
        local cart   = mkCart(9003)
        local player = mkPlayer(203, cart)

        pumpFrame(player, cart)
        h.advance(5000)
        pumpFrame(player, cart)   -- still holding: no state change
        h.advance(5000)
        pumpFrame(player, cart)

        result = Assert.equal(animPackets(h.sent), 1,
            "holding a cart is not a per-frame packet source")
    end)
    return result
end

return tests
