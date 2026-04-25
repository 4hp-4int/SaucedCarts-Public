--[[
    SaucedCarts — InstantDrop must not clear the action queue (regression)
    ======================================================================

    User-reported freeze + "ISTimedActionQueue:tick: bugged action, cleared
    queue ISGrabCorpseAction" when picking up a zombie while holding a cart.

    Root cause (2026-04-24): InstantDrop.dropCartSP + InstantDrop.handle
    (MP) both called ISTimedActionQueue.clear(player) during the force-drop
    path. Vanilla force-drop triggers (ISGrabCorpseAction, ISEquipWeapon,
    ISEnterVehicle, etc.) are themselves on the queue — clearing mid-tick
    destroys the currently-ticking action, producing vanilla's "bugged
    action" safety log and whatever side-effects the action had started.

    The fix is to NOT call ISTimedActionQueue.clear in the InstantDrop
    path. Cart-dependent actions self-invalidate via :isValid() once the
    cart enters the world.

    This test locks both call sites. It instruments ISTimedActionQueue.clear
    with a counter, fires the InstantDrop paths, and asserts the counter
    stays at zero.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"

-- InstantDrop lives under client/; require it directly. The module
-- returns its table — capture it from require rather than any SaucedCarts
-- global alias (there is none). ISTimedActionQueue must also exist as a
-- global table for our spy to wrap its .clear field.
local ok, InstantDrop = pcall(require, "SaucedCarts/CartState/InstantDrop")
if not ok or type(InstantDrop) ~= "table" then return {} end
if type(ISTimedActionQueue) ~= "table" then
    ISTimedActionQueue = { clear = function(p) end }
end

-- ============================================================================
-- QUEUE CLEAR INSTRUMENTATION
-- ============================================================================
-- Wrap ISTimedActionQueue.clear with a counter so we can detect any call
-- originating from InstantDrop code paths. Restored per-test via teardown.

local function installQueueSpy()
    local spy = { count = 0, lastPlayer = nil, _savedClear = ISTimedActionQueue.clear }
    ISTimedActionQueue.clear = function(player)
        spy.count = spy.count + 1
        spy.lastPlayer = player
    end
    spy.restore = function()
        ISTimedActionQueue.clear = spy._savedClear
    end
    return spy
end

-- ============================================================================
-- MINIMAL FIXTURES
-- ============================================================================

local function makePlayerWithCart()
    local cart = {
        _id = 777,
        _type = "InventoryContainer",
        _fullType = "SaucedCarts.ShoppingCart",
        _md = {},
        _worldItem = nil,
        _condition = 10,
        _conditionMax = 10,
    }
    cart.getID = function(self) return self._id end
    cart.getFullType = function(self) return self._fullType end
    cart.getModData = function(self) return self._md end
    cart.getWorldItem = function(self) return self._worldItem end
    cart.setWorldItem = function(self, v) self._worldItem = v end
    cart.getCondition = function(self) return self._condition end
    cart.getConditionMax = function(self) return self._conditionMax end
    cart.setCondition = function(self, v) self._condition = v end
    cart.getContainer = function(self) return nil end
    cart.getItemContainer = function(self) return nil end
    cart.getTexture = function(self) return nil end

    local inv = {
        _items = {},
        getItems = function(self)
            return { size = function() return 0 end, get = function(_, _) return nil end }
        end,
        Remove = function(self, it) end,
        isInCharacterInventory = function() return true end,
    }

    local sq = {
        getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
        AddWorldInventoryItem = function(self, item, x, y, h, transmit) return nil end,
    }

    local player = {
        _primary = cart,
        _square = sq,
        _inv = inv,
        _onlineId = 1,
    }
    player.getPrimaryHandItem = function(self) return self._primary end
    player.setPrimaryHandItem = function(self, v) self._primary = v end
    player.setSecondaryHandItem = function(self, v) end
    player.getCurrentSquare = function(self) return self._square end
    player.getInventory = function(self) return self._inv end
    player.getOnlineID = function(self) return self._onlineId end
    player.setVariable = function(self, k, v) end
    return player, cart
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

tests["dropCartSP_does_not_clear_action_queue"] = function()
    local spy = installQueueSpy()
    local player, cart = makePlayerWithCart()

    pcall(function() InstantDrop.dropCartSP(player, cart) end)

    local count = spy.count
    spy.restore()
    return Assert.equal(count, 0,
        "ISTimedActionQueue.clear must not be called from dropCartSP " ..
        "(would kill the ISGrabCorpseAction / ISEnterVehicle action that " ..
        "triggered the force-drop mid-tick, producing vanilla's 'bugged " ..
        "action' freeze)")
end

tests["handle_mp_does_not_clear_action_queue"] = function()
    -- handle() takes the MP path when player:getOnlineID() is non-nil.
    -- The spy must stay at zero: we send a network command instead of
    -- clearing the queue.
    local spy = installQueueSpy()
    local player, cart = makePlayerWithCart()

    -- Stub out the network send so the test doesn't try to actually
    -- talk to a dedi server.
    local origSend = SaucedCarts.Network.sendToServer
    SaucedCarts.Network.sendToServer = function() return true end

    pcall(function() InstantDrop.handle(player, cart) end)

    SaucedCarts.Network.sendToServer = origSend
    local count = spy.count
    spy.restore()
    return Assert.equal(count, 0,
        "InstantDrop.handle must not clear the client-side action queue " ..
        "(same reason as SP path — kills force-drop-triggering action)")
end

return tests
