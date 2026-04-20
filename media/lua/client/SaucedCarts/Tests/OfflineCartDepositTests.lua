--[[
    SaucedCarts — Cart transfer interception + server handler tests
    ===============================================================

    Covers the 4 cart transfer cases that vanilla's TransactionManager
    silently rejects on dedicated MP (Java-internal getEffectiveCapacity
    bypasses our Lua capacity override):

        player inv           -> ground cart   (direction="in",  ground)
        ground cart          -> player inv    (direction="out", ground)
        player inv           -> in-hand cart  (direction="in",  hand)
        in-hand cart         -> player inv    (direction="out", hand)

    Plus the negative cases:

        player inv -> non-cart container      (not intercepted)
        nil src/dest                          (not intercepted)

    Regression note (2026-04-19): the initial v2.1.3 interceptor only
    matched destContainer. That silently left 3 of the 4 cart-transfer
    directions broken on dedi (src=cart cases, plus any case where the
    dest passed the "parent is character" early-exit). User-reported —
    these tests now lock the direction-neutral classifyTransfer behaviour
    so the regression can't re-occur.
]]

if isServer() and not isClient() then return end

if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartTransferInterceptor"

-- ============================================================================
-- MOCKS
-- ============================================================================

local function makeContainer(opts)
    opts = opts or {}
    local c = {
        _items = {}, _parent = opts.parent, _type = "InventoryContainer",
        _containingItem = opts.containingItem,
        _typeName = opts.typeName or "bag",
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
    c.getItems = function(self)
        local list = { _items = self._items }
        list.size = function(s) return #s._items end
        list.get  = function(s, i) return s._items[i + 1] end
        return list
    end
    c.getItemById = function(self, id)
        for _, it in ipairs(self._items) do
            if it and it.getID and it:getID() == id then return it end
        end
        return nil
    end
    return c
end

local function makeCartItem(opts)
    opts = opts or {}
    local item = {
        _id = opts.id or 42,
        _type = "InventoryContainer",
        _fullType = "SaucedCarts.ShoppingCart",
    }
    item.getID = function(self) return self._id end
    item.getFullType = function(self) return self._fullType end
    item._innerContainer = makeContainer({
        parent = opts.parent,
        containingItem = item,
        hasRoom = opts.hasRoom,
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
    ch.getX = function(self) return 10.0 end
    ch.getY = function(self) return 10.0 end
    ch.getZ = function(self) return 0.0 end
    ch.isSeatedInVehicle = function(self) return false end
    return ch
end

-- Lua-table mock items need to pass safeIsCart. The override is additive —
-- real userdata still goes through the original.
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item._fullType and item._fullType:find("^SaucedCarts") then
        return true
    end
    return origSafeIsCart(item)
end

-- ============================================================================
-- classifyTransfer — interception decision matrix
-- ============================================================================

local tests = {}

local CTI = SaucedCarts.CartTransferInterceptor
local classify = CTI.classifyTransfer

tests["classify_inv_to_ground_cart_is_in"] = function()
    local playerInv = makeContainer({ parent = { _type = "IsoGameCharacter" } })
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    local direction, matched = classify(playerInv, cart:getItemContainer())
    if not Assert.equal(direction, "in", "direction=in") then return false end
    return Assert.equal(matched, cart, "cart resolved to dest cart")
end

tests["classify_ground_cart_to_inv_is_out"] = function()
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    local playerInv = makeContainer({ parent = { _type = "IsoGameCharacter" } })
    local direction, matched = classify(cart:getItemContainer(), playerInv)
    if not Assert.equal(direction, "out", "direction=out") then return false end
    return Assert.equal(matched, cart, "cart resolved to source cart")
end

tests["classify_inv_to_inhand_cart_is_in"] = function()
    local chr = { _type = "IsoGameCharacter" }
    local playerInv = makeContainer({ parent = chr })
    local cart = makeCartItem({ parent = chr })
    local direction, matched = classify(playerInv, cart:getItemContainer())
    if not Assert.equal(direction, "in", "in-hand cart dest: direction=in") then return false end
    return Assert.equal(matched, cart, "in-hand cart resolved to dest")
end

tests["classify_inhand_cart_to_inv_is_out"] = function()
    local chr = { _type = "IsoGameCharacter" }
    local cart = makeCartItem({ parent = chr })
    local playerInv = makeContainer({ parent = chr })
    local direction, matched = classify(cart:getItemContainer(), playerInv)
    if not Assert.equal(direction, "out", "in-hand cart src: direction=out") then return false end
    return Assert.equal(matched, cart, "in-hand cart resolved to src")
end

tests["classify_inv_to_bag_no_cart_returns_nil"] = function()
    local playerInv = makeContainer({ parent = { _type = "IsoGameCharacter" } })
    local bag = makeContainer({ parent = { _type = "IsoGameCharacter" } })
    local direction, matched = classify(playerInv, bag)
    if not Assert.isNil(direction, "direction=nil for non-cart transfer") then return false end
    return Assert.isNil(matched, "cart=nil for non-cart transfer")
end

tests["classify_nil_src_and_dest_returns_nil"] = function()
    local direction, matched = classify(nil, nil)
    if not Assert.isNil(direction, "direction=nil for nil containers") then return false end
    return Assert.isNil(matched, "cart=nil for nil containers")
end

tests["classify_dest_takes_priority_over_src"] = function()
    -- Unusual but well-defined: both containers are carts. The interceptor
    -- classifies as "in" (dest-side match fires first). Keeps behaviour
    -- deterministic instead of silently swapping based on argument order.
    local cartA = makeCartItem({ id = 1, parent = { _type = "IsoGridSquare" } })
    local cartB = makeCartItem({ id = 2, parent = { _type = "IsoGameCharacter" } })
    local direction, matched = classify(cartA:getItemContainer(), cartB:getItemContainer())
    if not Assert.equal(direction, "in", "dest-wins direction=in") then return false end
    return Assert.equal(matched, cartB, "dest cart is the matched cart")
end

-- ============================================================================
-- performCartTransfer — the actual move helper
-- ============================================================================

tests["performCartTransfer_in_moves_inv_to_cart"] = function()
    local item = makeItem({ id = 101 })
    local src = makeContainer()
    src:AddItem(item)
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    local chr = makeCharacter()

    local ok = SaucedCarts.performCartTransfer(chr, item, src, cart:getItemContainer())

    if not Assert.isTrue(ok, "transfer succeeded") then return false end
    if not Assert.isFalse(src:contains(item), "item left source") then return false end
    return Assert.isTrue(cart:getItemContainer():contains(item), "item in cart")
end

tests["performCartTransfer_out_moves_cart_to_inv"] = function()
    local item = makeItem({ id = 102 })
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    cart:getItemContainer():AddItem(item)
    local playerInv = makeContainer({ parent = { _type = "IsoGameCharacter" } })
    local chr = makeCharacter()

    local ok = SaucedCarts.performCartTransfer(chr, item, cart:getItemContainer(), playerInv)

    if not Assert.isTrue(ok, "withdraw succeeded") then return false end
    if not Assert.isFalse(cart:getItemContainer():contains(item), "item left cart") then return false end
    return Assert.isTrue(playerInv:contains(item), "item in player inventory")
end

tests["performCartTransfer_refuses_when_dest_full"] = function()
    local item = makeItem({ id = 103 })
    local src = makeContainer()
    src:AddItem(item)
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" }, hasRoom = false })
    local chr = makeCharacter()

    local ok = SaucedCarts.performCartTransfer(chr, item, src, cart:getItemContainer())

    if not Assert.isFalse(ok, "transfer refused") then return false end
    if not Assert.isTrue(src:contains(item), "item still in source") then return false end
    return Assert.isFalse(cart:getItemContainer():contains(item), "item NOT in cart")
end

tests["performCartTransfer_nil_safe"] = function()
    local chr = makeCharacter()
    local src = makeContainer()
    local dst = makeContainer()
    if not Assert.isFalse(SaucedCarts.performCartTransfer(nil, nil, nil, nil),
        "all-nil: false") then return false end
    if not Assert.isFalse(SaucedCarts.performCartTransfer(chr, nil, src, dst),
        "missing item: false") then return false end
    if not Assert.isFalse(SaucedCarts.performCartTransfer(chr, {}, nil, dst),
        "missing src: false") then return false end
    return Assert.isFalse(SaucedCarts.performCartTransfer(chr, {}, src, nil),
        "missing dst: false")
end

-- Back-compat: old performCartDeposit (player, item, cartItem) still works.
-- Clients or integrations that imported the v2.1.3-pre-fix name shouldn't
-- break at upgrade time.
tests["performCartDeposit_compat_alias_still_works"] = function()
    local item = makeItem({ id = 104 })
    local src = makeContainer()
    src:AddItem(item)
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    local chr = makeCharacter()

    local ok = SaucedCarts.performCartDeposit(chr, item, cart)

    if not Assert.isTrue(ok, "compat alias succeeded") then return false end
    return Assert.isTrue(cart:getItemContainer():contains(item), "item in cart via alias")
end

-- ============================================================================
-- cart → floor drop: double-transmit regression guard (2026-04-20)
-- ============================================================================
--
-- BUG: performCartTransfer called the 4-arg form of AddWorldInventoryItem.
-- That overload routes to (item, x, y, h, transmit=true) in vanilla Java,
-- which internally broadcasts transmitCompleteItemToClients. The code THEN
-- manually called transmitCompleteItemToClients again. Every cart→floor
-- drop broadcast the new world item TWICE, producing ghost ground items
-- on clients and rolling "Error, container already has id" spam.
--
-- FIX: pass transmit=false as the 5th arg and keep the manual transmit
-- (matches vanilla ISDropWorldItemAction:complete exactly).
--
-- These tests spy on dropSquare.AddWorldInventoryItem + the returned
-- worldItem's transmitCompleteItemToClients to lock the single-broadcast
-- contract. If either side drifts back to double-broadcast, the tests fail.

local function makeDropSquare(opts)
    opts = opts or {}
    local sq = {
        _x = opts.x or 10, _y = opts.y or 10, _z = opts.z or 0,
        _addCallArgs = {},
        _addCallCount = 0,
    }
    sq.getX = function(self) return self._x end
    sq.getY = function(self) return self._y end
    sq.getZ = function(self) return self._z end
    sq.getApparentZ = function(self, x, y) return self._z end
    -- The spied return value: the InventoryItem itself, with a :getWorldItem()
    -- that returns a transmit-counting wrapper.
    sq.AddWorldInventoryItem = function(self, item, x, y, h, transmit)
        self._addCallCount = self._addCallCount + 1
        table.insert(self._addCallArgs, {
            item = item, x = x, y = y, h = h, transmit = transmit,
            argCount = (transmit == nil) and 4 or 5,
        })
        -- Attach a world-item wrapper with a transmit counter. Vanilla
        -- returns the InventoryItem, whose :getWorldItem() gives the wrapper.
        item._transmitCount = 0
        item._setIgnoreRemoveSandboxCount = 0
        item._worldItemMock = {
            setIgnoreRemoveSandbox = function(w, flag) item._setIgnoreRemoveSandboxCount = item._setIgnoreRemoveSandboxCount + 1 end,
            transmitCompleteItemToClients = function(w) item._transmitCount = item._transmitCount + 1 end,
        }
        item.getWorldItem = function(self) return self._worldItemMock end
        return item
    end
    return sq
end

-- Vanilla ISTransferAction.GetDropItemOffset requires character:getZ,
-- character:isSeatedInVehicle, square:getApparentZ, and getCore() globals.
-- The test character/square mocks have getZ/getApparentZ, but
-- getOptionDropItemsOnSquareCenter is a global. Cheap stub so the offset
-- function runs in the test harness.
local origGetCore = getCore
if not getCore or not getCore() or type(getCore().getOptionDropItemsOnSquareCenter) ~= "function" then
    local coreStub = {
        getOptionDropItemsOnSquareCenter = function(self) return false end,
    }
    getCore = function() return coreStub end
end
if not ZombRandFloat then ZombRandFloat = function(a, b) return a end end
if not ZombRand then ZombRand = function(a, b) return a end end

tests["drop_to_floor_passes_transmit_false_to_AddWorldInventoryItem"] = function()
    -- The regression: 4-arg AddWorldInventoryItem defaults transmit=true
    -- internally, producing an internal broadcast we don't control. The fix
    -- is to call the 5-arg form with transmit=false. Assert the 5th arg.
    local item = makeItem({ id = 501 })
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    cart:getItemContainer():AddItem(item)
    local sq = makeDropSquare()
    local chr = makeCharacter()

    local ok = SaucedCarts.performCartTransfer(
        chr, item, cart:getItemContainer(), nil, sq, nil
    )

    if not Assert.isTrue(ok, "drop succeeded") then return false end
    if not Assert.equal(sq._addCallCount, 1, "AddWorldInventoryItem called exactly once") then return false end
    local call = sq._addCallArgs[1]
    if not Assert.equal(call.argCount, 5, "5-arg form used (not 4-arg — 4-arg double-broadcasts)") then return false end
    return Assert.isFalse(call.transmit,
        "transmit=false passed explicitly (prevents engine-side auto-broadcast)")
end

tests["drop_to_floor_broadcasts_complete_item_exactly_once"] = function()
    -- Single-broadcast contract: transmitCompleteItemToClients fires once.
    -- If regression reintroduces double-transmit (4-arg AddWorldInventoryItem
    -- auto-transmits + manual transmit = 2), this test fails immediately.
    -- Downstream symptom was ghost ground items + "already has id" spam.
    local item = makeItem({ id = 502 })
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    cart:getItemContainer():AddItem(item)
    local sq = makeDropSquare()
    local chr = makeCharacter()

    SaucedCarts.performCartTransfer(chr, item, cart:getItemContainer(), nil, sq, nil)

    return Assert.equal(item._transmitCount, 1,
        "transmitCompleteItemToClients called exactly once per drop")
end

tests["drop_to_floor_removes_from_src_before_adding_to_world"] = function()
    -- Ordering matters: remove from cart FIRST, then put on ground.
    -- Reverse order would briefly have the item in both places and could
    -- trip containsID checks on the server.
    local item = makeItem({ id = 503 })
    local cart = makeCartItem({ parent = { _type = "IsoGameCharacter" } })
    cart:getItemContainer():AddItem(item)
    local sq = makeDropSquare()
    local chr = makeCharacter()

    SaucedCarts.performCartTransfer(chr, item, cart:getItemContainer(), nil, sq, nil)

    if not Assert.isFalse(cart:getItemContainer():contains(item), "item left cart") then return false end
    return Assert.equal(sq._addCallCount, 1, "world add fired once after cart remove")
end

tests["drop_to_floor_sets_ignore_remove_sandbox"] = function()
    -- Vanilla's ISDropWorldItemAction:complete sets ignoreRemoveSandbox so
    -- the vanilla SandboxOption that culls world items doesn't immediately
    -- delete the one we just dropped. Regression-guard that flag.
    local item = makeItem({ id = 504 })
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    cart:getItemContainer():AddItem(item)
    local sq = makeDropSquare()
    local chr = makeCharacter()

    SaucedCarts.performCartTransfer(chr, item, cart:getItemContainer(), nil, sq, nil)

    return Assert.equal(item._setIgnoreRemoveSandboxCount, 1,
        "setIgnoreRemoveSandbox fired once on the dropped world item")
end

-- ============================================================================
-- floor → cart pickup: single-removal regression guard
-- ============================================================================
--
-- Mirror guard for the pickup direction. The pickup path must:
--   1. transmitRemoveItemFromSquare — fires exactly once
--   2. worldItem:removeFromWorld / :removeFromSquare / :setSquare(nil)
--      — each fires exactly once (mirrors vanilla ISGrabItemAction)
--   3. item:setWorldItem(nil) — item's wrapper reference cleared
--   4. destContainer:AddItem(item) — item lands in cart
--
-- If any of these drift (e.g. someone swaps in sq:removeWorldObject without
-- the setSquare(nil), or skips the transmit), ghost items reappear.

local function makeWorldItemWrapper(item, sq)
    local w = {
        _item = item,
        _square = sq,
        _removeFromWorldCount = 0,
        _removeFromSquareCount = 0,
        _setSquareNilCount = 0,
    }
    w.getItem = function(self) return self._item end
    w.getSquare = function(self) return self._square end
    w.removeFromWorld  = function(self) self._removeFromWorldCount = self._removeFromWorldCount + 1 end
    w.removeFromSquare = function(self) self._removeFromSquareCount = self._removeFromSquareCount + 1 end
    w.setSquare = function(self, v)
        if v == nil then self._setSquareNilCount = self._setSquareNilCount + 1 end
        self._square = v
    end
    return w
end

local function makePickupSquare(opts)
    opts = opts or {}
    local sq = {
        _x = opts.x or 10, _y = opts.y or 10, _z = opts.z or 0,
        _transmitRemoveCount = 0,
        _transmitRemoveArg = nil,
    }
    sq.getX = function(self) return self._x end
    sq.getY = function(self) return self._y end
    sq.getZ = function(self) return self._z end
    sq.transmitRemoveItemFromSquare = function(self, obj)
        self._transmitRemoveCount = self._transmitRemoveCount + 1
        self._transmitRemoveArg = obj
    end
    return sq
end

tests["pickup_from_floor_transmits_remove_exactly_once"] = function()
    local sq = makePickupSquare()
    local item = makeItem({ id = 601 })
    local worldItem = makeWorldItemWrapper(item, sq)
    item._worldItem = worldItem
    item.getWorldItem = function(self) return self._worldItem end
    item.setWorldItem = function(self, v) self._worldItem = v end

    local cart = makeCartItem({ parent = { _type = "IsoGameCharacter" } })
    local chr = makeCharacter()

    SaucedCarts.performCartTransfer(
        chr, item, nil, cart:getItemContainer(), nil, sq
    )

    if not Assert.equal(sq._transmitRemoveCount, 1, "transmitRemoveItemFromSquare fired once") then return false end
    return Assert.equal(sq._transmitRemoveArg, worldItem, "remove targeted the worldItem wrapper (not the InventoryItem)")
end

tests["pickup_from_floor_fires_worldItem_lifecycle_once_each"] = function()
    -- Mirror vanilla ISGrabItemAction exactly. removeFromWorld +
    -- removeFromSquare + setSquare(nil) each called once on the wrapper.
    -- Pre-fix code used sq:removeWorldObject which omits setSquare(nil)
    -- and caused stale square refs to linger.
    local sq = makePickupSquare()
    local item = makeItem({ id = 602 })
    local worldItem = makeWorldItemWrapper(item, sq)
    item._worldItem = worldItem
    item.getWorldItem = function(self) return self._worldItem end
    item.setWorldItem = function(self, v) self._worldItem = v end

    local cart = makeCartItem({ parent = { _type = "IsoGameCharacter" } })
    local chr = makeCharacter()

    SaucedCarts.performCartTransfer(chr, item, nil, cart:getItemContainer(), nil, sq)

    if not Assert.equal(worldItem._removeFromWorldCount, 1, "removeFromWorld() called once") then return false end
    if not Assert.equal(worldItem._removeFromSquareCount, 1, "removeFromSquare() called once") then return false end
    return Assert.equal(worldItem._setSquareNilCount, 1, "setSquare(nil) called once on the wrapper")
end

tests["pickup_from_floor_clears_item_worldItem_and_lands_in_cart"] = function()
    local sq = makePickupSquare()
    local item = makeItem({ id = 603 })
    local worldItem = makeWorldItemWrapper(item, sq)
    item._worldItem = worldItem
    item.getWorldItem = function(self) return self._worldItem end
    item.setWorldItem = function(self, v) self._worldItem = v end

    local cart = makeCartItem({ parent = { _type = "IsoGameCharacter" } })
    local chr = makeCharacter()

    local ok = SaucedCarts.performCartTransfer(chr, item, nil, cart:getItemContainer(), nil, sq)

    if not Assert.isTrue(ok, "pickup succeeded") then return false end
    if not Assert.isNil(item._worldItem, "item:setWorldItem(nil) was called") then return false end
    return Assert.isTrue(cart:getItemContainer():contains(item), "item landed in cart")
end

return tests
