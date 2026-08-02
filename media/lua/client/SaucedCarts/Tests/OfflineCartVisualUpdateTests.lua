--[[
    SaucedCarts — Visual fill-state regression tests
    ================================================

    Locks the v2.1.14 fix for the "ground cart doesn't change appearance
    until you push it" report.

    Root cause being locked: the only firer of onCartContentsChanged was a
    hook on vanilla ISInventoryTransferAction.perform — but the interceptor
    (v2.1.4+) substitutes ISCartTransferAction for EVERY cart-involved
    transfer, so the hook never fired and no cart transfer triggered a
    visual update. Ground carts only repainted when CartStateHandler's
    while-pushing reconciler caught the modData drift.

    The fix: SaucedCarts.performCartTransfer (the single funnel every cart
    move goes through — SP local, dedi handler, dedi double-perform) calls
    SaucedCarts.updateCartVisual on the involved cart(s) after a successful
    move, and updateCartVisual broadcasts updateGroundCartVisual when run
    server-side on a ground cart.

    Sensitivity: every "refreshes" test here fails against pre-fix code
    (spy count stays 0 because nothing in the transfer pipeline touched
    visuals at all).
]]

if isServer() and not isClient() then return end

if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartData"
require "SaucedCarts/CartVisuals"
require "SaucedCarts/CartTransferInterceptor"

-- ============================================================================
-- FIXTURES (mirrors OfflineCartDepositTests fixtures + visual surface)
-- ============================================================================

local function makeContainer(opts)
    opts = opts or {}
    local c = {
        _items = {}, _parent = opts.parent, _type = "InventoryContainer",
        _containingItem = opts.containingItem,
        _typeName = opts.typeName or "bag",
        _capacity = opts.capacity or 50,
        _capacityWeight = opts.capacityWeight or 0,
    }
    c.getParent = function(self) return self._parent end
    c.getContainingItem = function(self) return self._containingItem end
    c.getType = function(self) return self._typeName end
    c.contains = function(self, item)
        for _, it in ipairs(self._items) do if it == item then return true end end
        return false
    end
    c.AddItem = function(self, item)
        table.insert(self._items, item)
        if item and type(item) == "table" then
            item._container = self
            item.getContainer = function(s) return s._container end
        end
        return item
    end
    c.DoAddItemBlind = c.AddItem
    c.Remove = function(self, item)
        for i, it in ipairs(self._items) do
            if it == item then table.remove(self._items, i); return end
        end
    end
    c.DoRemoveItem = c.Remove
    c.hasRoomFor = function(self, chr, itemOrWeight) return opts.hasRoom ~= false end
    c._drawDirtyCount = 0
    c.setDrawDirty = function(self, v) self._drawDirtyCount = self._drawDirtyCount + 1 end
    c.setExplored = function(self, v) self._explored = v end
    c.setHasBeenLooted = function(self, v) self._hasBeenLooted = v end
    c.getCapacity = function(self) return self._capacity end
    c.getEffectiveCapacity = function(self, chr) return self._capacity end
    c.getCapacityWeight = function(self) return self._capacityWeight end
    c.getItems = function(self)
        local list = { _items = self._items }
        list.size = function(s) return #s._items end
        list.get  = function(s, i) return s._items[i + 1] end
        return list
    end
    return c
end

local function makeCartItem(opts)
    opts = opts or {}
    local item = {
        _id = opts.id or 42,
        _type = "InventoryContainer",
        _fullType = "SaucedCarts.ShoppingCart",
        _modData = {},
        _staticModel = nil,
        _worldStaticModel = nil,
        _worldItem = opts.worldItem,
    }
    item.getID = function(self) return self._id end
    item.getFullType = function(self) return self._fullType end
    item.getModData = function(self) return self._modData end
    item.getWorldItem = function(self) return self._worldItem end
    item.setStaticModel = function(self, m) self._staticModel = m end
    item.getStaticModel = function(self) return self._staticModel end
    item.setWorldStaticModel = function(self, m) self._worldStaticModel = m end
    item.setWorldScale = function(self, s) self._worldScale = s end
    item.getCondition = function(self) return 100 end
    item._innerContainer = makeContainer({
        parent = opts.parent,
        containingItem = item,
        hasRoom = opts.hasRoom,
        capacity = opts.capacity or 50,
        capacityWeight = opts.capacityWeight or 0,
    })
    item.getItemContainer = function(self) return self._innerContainer end
    item.getContainer = function(self) return self._outerContainer end
    return item
end

local function makeItem(opts)
    opts = opts or {}
    local item = {
        _id = opts.id or 100,
        _type = "InventoryItem",
        _fullType = opts.fullType or "Base.RippedSheets",
    }
    item.getID = function(self) return self._id end
    item.getFullType = function(self) return self._fullType end
    item.getType = function(self) return "Item" end
    item.getWorldItem = function(self) return nil end
    item.getContainer = function(self) return self._container end
    item.setJobDelta = function(self, v) end
    return item
end

local function makeCharacter()
    local ch = { _type = "IsoPlayer" }
    ch.getOnlineID = function(self) return 1 end
    ch.getInventory = function(self) return self._inv end
    ch.isEquipped = function(self, item) return false end
    ch.removeAttachedItem = function(self, item) end
    ch.removeFromHands = function(self, item) end
    ch.removeWornItem = function(self, item, b) end
    ch.getPrimaryHandItem = function(self) return nil end
    ch.getCurrentSquare = function(self) return nil end
    ch.getX = function(self) return 10.0 end
    ch.getY = function(self) return 10.0 end
    ch.getZ = function(self) return 0.0 end
    ch.isSeatedInVehicle = function(self) return false end
    return ch
end

local function makeSquare(opts)
    opts = opts or {}
    local sq = { _x = opts.x or 10, _y = opts.y or 11, _z = opts.z or 0 }
    sq.getX = function(self) return self._x end
    sq.getY = function(self) return self._y end
    sq.getZ = function(self) return self._z end
    sq.transmitRemoveItemFromSquare = function(self, obj) end
    sq.getApparentZ = function(self, x, y) return self._z end
    return sq
end

local function makeWorldItemWrapper(item, sq)
    local w = { _item = item, _square = sq, _updateSpriteCount = 0 }
    w.getItem = function(self) return self._item end
    w.getSquare = function(self) return self._square end
    w.updateSprite = function(self) self._updateSpriteCount = self._updateSpriteCount + 1 end
    w.setIgnoreRemoveSandbox = function(self, v) end
    w.removeFromWorld = function(self) end
    w.removeFromSquare = function(self) end
    w.setSquare = function(self, v) self._square = v end
    return w
end

--- Run fn with SaucedCarts.updateCartVisual spy-wrapped; ALWAYS restores
--- (a leaked spy poisons whichever test runs next — Kahlua pairs order is
--- arbitrary). The chokepoint looks the function up at call time, so the
--- swap is seen. Returns (calls, ok, result) where ok/result are from
--- pcall(fn) — closure form, args-form pcall is unreliable in Kahlua.
local function withVisualSpy(fn)
    local original = SaucedCarts.updateCartVisual
    local calls = {}
    SaucedCarts.updateCartVisual = function(cart, player)
        table.insert(calls, { cart = cart, player = player })
        return true
    end
    local ok, result = pcall(fn)
    SaucedCarts.updateCartVisual = original
    if not ok then error(result, 0) end
    return calls, result
end

--- Stub isServer/isClient (kit defaults isClient()=true); returns restore.
local function stubContext(server, client)
    local oldServer, oldClient = _G.isServer, _G.isClient
    _G.isServer = function() return server end
    _G.isClient = function() return client end
    return function() _G.isServer, _G.isClient = oldServer, oldClient end
end

-- Lua-table mock items need to pass isCart/safeIsCart (both reject non-
-- userdata). The overrides are additive - real userdata still goes through
-- the originals. Mirrors OfflineCartDepositTests.
local function tableFixtureIsCart(item)
    return type(item) == "table" and item._type == "InventoryContainer"
        and item._fullType and item._fullType:find("^SaucedCarts") ~= nil
end
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if tableFixtureIsCart(item) then return true end
    return origSafeIsCart(item)
end
local origIsCart = SaucedCarts.isCart
SaucedCarts.isCart = function(item)
    if tableFixtureIsCart(item) then return true end
    return origIsCart(item)
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

-- ----------------------------------------------------------------------------
-- Chokepoint: every successful performCartTransfer branch refreshes visuals
-- ----------------------------------------------------------------------------

tests["deposit_into_cart_refreshes_cart_visual"] = function()
    local player = makeCharacter()
    local cart = makeCartItem({ id = 42 })
    local bag = makeContainer({ typeName = "bag" })
    local nails = makeItem({ id = 100 })
    bag:AddItem(nails)

    local calls, ok = withVisualSpy(function()
        return SaucedCarts.performCartTransfer(player, nails, bag, cart:getItemContainer())
    end)

    Assert.isTrue(ok, "transfer should succeed")
    Assert.equal(#calls, 1, "one visual refresh for the involved cart")
    Assert.isTrue(calls[1].cart == cart, "refresh targets the dest cart")
    return Assert.isTrue(calls[1].player == player, "refresh carries the acting player")
end

tests["withdraw_from_cart_refreshes_cart_visual"] = function()
    local player = makeCharacter()
    local cart = makeCartItem({ id = 43 })
    local bag = makeContainer({ typeName = "bag" })
    local nails = makeItem({ id = 101 })
    cart:getItemContainer():AddItem(nails)

    local calls, ok = withVisualSpy(function()
        return SaucedCarts.performCartTransfer(player, nails, cart:getItemContainer(), bag)
    end)

    Assert.isTrue(ok, "transfer should succeed")
    Assert.equal(#calls, 1, "one visual refresh for the involved cart")
    return Assert.isTrue(calls[1].cart == cart, "refresh targets the src cart")
end

tests["pickup_from_ground_into_cart_refreshes_cart_visual"] = function()
    local player = makeCharacter()
    local cart = makeCartItem({ id = 44 })
    local sq = makeSquare()
    local ground = makeItem({ id = 102 })
    local wrapper = makeWorldItemWrapper(ground, sq)
    ground.getWorldItem = function(self) return wrapper end
    ground.setWorldItem = function(self, v) wrapper = v end

    local calls, ok = withVisualSpy(function()
        -- floor -> cart: srcContainer nil, srcSquare set
        return SaucedCarts.performCartTransfer(player, ground, nil, cart:getItemContainer(), nil, sq)
    end)

    Assert.isTrue(ok, "pickup should succeed")
    Assert.equal(#calls, 1, "one visual refresh for the dest cart")
    return Assert.isTrue(calls[1].cart == cart, "refresh targets the dest cart")
end

tests["drop_from_cart_to_floor_refreshes_cart_visual"] = function()
    local player = makeCharacter()
    local cart = makeCartItem({ id = 45 })
    local sq = makeSquare()
    -- Give the drop square the world-add surface the drop branch expects.
    sq.AddWorldInventoryItem = function(self, item, x, y, z, transmit)
        local w = makeWorldItemWrapper(item, self)
        w.transmitCompleteItemToClients = function() end
        return { getWorldItem = function() return w end }
    end
    local nails = makeItem({ id = 103 })
    cart:getItemContainer():AddItem(nails)

    -- Vanilla GetDropItemOffset calls ZombRandFloat/getCore options the kit
    -- env doesn't provide; pin a deterministic offset for the drop branch.
    local origOffset = ISTransferAction.GetDropItemOffset
    ISTransferAction.GetDropItemOffset = function(chr, square, it) return 0.5, 0.5, 0.0 end

    local calls, ok = withVisualSpy(function()
        return SaucedCarts.performCartTransfer(player, nails, cart:getItemContainer(), nil, sq)
    end)

    ISTransferAction.GetDropItemOffset = origOffset

    Assert.isTrue(ok, "drop should succeed")
    Assert.equal(#calls, 1, "one visual refresh for the src cart")
    return Assert.isTrue(calls[1].cart == cart, "refresh targets the src cart")
end

tests["failed_transfer_does_not_refresh"] = function()
    local player = makeCharacter()
    local cart = makeCartItem({ id = 46, hasRoom = false })
    local sq = makeSquare()
    local ground = makeItem({ id = 104 })

    local calls, ok = withVisualSpy(function()
        return SaucedCarts.performCartTransfer(player, ground, nil, cart:getItemContainer(), nil, sq)
    end)

    Assert.isFalse(ok, "no-room pickup should fail")
    return Assert.equal(#calls, 0, "failed move must not touch visuals")
end

tests["non_cart_transfer_does_not_refresh"] = function()
    local player = makeCharacter()
    local bagA = makeContainer({ typeName = "bag" })
    local bagB = makeContainer({ typeName = "bag" })
    local nails = makeItem({ id = 105 })
    bagA:AddItem(nails)

    local calls = withVisualSpy(function()
        return SaucedCarts.performCartTransfer(player, nails, bagA, bagB)
    end)

    return Assert.equal(#calls, 0, "no cart involved, no visual refresh")
end

-- ----------------------------------------------------------------------------
-- updateCartVisual: server-side ground cart broadcasts updateGroundCartVisual
-- ----------------------------------------------------------------------------

tests["server_ground_cart_update_broadcasts_visual"] = function()
    local player = makeCharacter()
    local sq = makeSquare({ x = 20, y = 21, z = 0 })
    local cart = makeCartItem({ id = 47, capacityWeight = 40 })  -- 40/50 = full
    local wrapper = makeWorldItemWrapper(cart, sq)
    cart._worldItem = wrapper

    local restoreCtx = stubContext(true, false)  -- dedi server context
    local sent = {}
    local originalBroadcast = SaucedCarts.Network.broadcast
    SaucedCarts.Network.broadcast = function(command, args)
        table.insert(sent, { command = command, args = args })
    end

    local changed = SaucedCarts.updateCartVisual(cart, player)

    SaucedCarts.Network.broadcast = originalBroadcast
    restoreCtx()

    Assert.isTrue(changed, "40/50 from empty modData is a state change")
    Assert.equal(cart:getModData().SaucedCarts_fillState, "full", "modData records the new fill state")
    Assert.equal(#sent, 1, "exactly one broadcast")
    Assert.equal(sent[1].command, "updateGroundCartVisual", "broadcasts the ground visual command")
    Assert.equal(sent[1].args.cartId, 47, "broadcast carries the cart id")
    Assert.equal(sent[1].args.fillState, "full", "broadcast carries the computed fill state")
    return Assert.equal(sent[1].args.squareX, 20, "broadcast carries the square")
end

tests["server_ground_cart_no_change_no_broadcast"] = function()
    local player = makeCharacter()
    local sq = makeSquare()
    local cart = makeCartItem({ id = 48, capacityWeight = 0 })  -- empty
    cart._worldItem = makeWorldItemWrapper(cart, sq)
    cart:getModData().SaucedCarts_fillState = "empty"  -- already correct

    local restoreCtx = stubContext(true, false)
    local sent = {}
    local originalBroadcast = SaucedCarts.Network.broadcast
    SaucedCarts.Network.broadcast = function(command, args)
        table.insert(sent, { command = command, args = args })
    end

    local changed = SaucedCarts.updateCartVisual(cart, player)

    SaucedCarts.Network.broadcast = originalBroadcast
    restoreCtx()

    Assert.isFalse(changed, "no state change")
    return Assert.equal(#sent, 0, "no-change short-circuit must not broadcast (double-perform safety)")
end

-- ----------------------------------------------------------------------------
-- Fill state thresholds (drives the same calc the chokepoint relies on)
-- ----------------------------------------------------------------------------

tests["fill_state_thresholds"] = function()
    local function stateAt(weight)
        local cart = makeCartItem({ capacity = 50, capacityWeight = weight })
        return SaucedCarts.calculateFillState(cart)
    end
    Assert.equal(stateAt(0), "empty", "0/50 is empty")
    Assert.equal(stateAt(10), "empty", "0.2 fill is below partial threshold (0.33)")
    Assert.equal(stateAt(20), "partial", "0.4 fill is partial")
    Assert.equal(stateAt(30), "partial", "0.6 fill is still partial")
    Assert.equal(stateAt(35), "full", "0.7 fill is full (threshold 0.66)")
    return Assert.equal(stateAt(50), "full", "50/50 is full")
end

-- ----------------------------------------------------------------------------
-- End-to-end: deposit updates modData fill state through the real visual path
-- ----------------------------------------------------------------------------

tests["deposit_updates_recorded_fill_state_end_to_end"] = function()
    local player = makeCharacter()
    -- Container weight is fixture-static, so preset it to the post-deposit
    -- value; the point is that the REAL updateCartVisual runs off the
    -- chokepoint and lands the new state in modData (the field the pushing
    -- reconciler and the MP receiver both key off).
    local cart = makeCartItem({ id = 49, capacityWeight = 20 })  -- partial
    local bag = makeContainer({ typeName = "bag" })
    local nails = makeItem({ id = 106 })
    bag:AddItem(nails)

    Assert.equal(cart:getModData().SaucedCarts_fillState, nil, "no fill state before")

    local restoreCtx = stubContext(false, false)  -- SP
    local ok = SaucedCarts.performCartTransfer(player, nails, bag, cart:getItemContainer())
    restoreCtx()

    Assert.isTrue(ok, "transfer should succeed")
    Assert.equal(cart:getModData().SaucedCarts_fillState, "partial",
        "chokepoint drove the real updateCartVisual: modData reflects post-move fill state")
    return Assert.equal(cart:getStaticModel() ~= nil, true, "a model was applied")
end

return tests
