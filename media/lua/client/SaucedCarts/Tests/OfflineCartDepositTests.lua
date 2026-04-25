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
    c._drawDirtyCount = 0
    c.setDrawDirty = function(self, v) self._drawDirtyCount = self._drawDirtyCount + 1 end
    c.isDrawDirty = function(self) return self._drawDirtyCount > 0 end
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

-- Regression: inventory panel refresh after cart transfers (2026-04-24).
-- User reported SP transfers to an equipped cart leaving the UI stale —
-- weight + item list wouldn't update until the panel was closed/reopened.
-- Root cause: performCartTransfer routed through vanilla ISTransferAction
-- which relies on TransactionManager-set dirty flags we deliberately skip.
-- Locking the fix: both containers must have setDrawDirty called after a
-- successful mutation.
tests["performCartTransfer_marks_both_containers_dirty_container_to_container"] = function()
    local item = makeItem({ id = 201 })
    local src = makeContainer()
    src:AddItem(item)
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    local chr = makeCharacter()

    SaucedCarts.performCartTransfer(chr, item, src, cart:getItemContainer())

    if not Assert.isTrue(src:isDrawDirty(), "source container marked dirty after transfer") then return false end
    return Assert.isTrue(cart:getItemContainer():isDrawDirty(),
        "destination (cart inner) marked dirty after transfer")
end

tests["performCartTransfer_marks_dest_dirty_on_floor_pickup"] = function()
    -- Ground item → cart. srcContainer is nil; we only care that the
    -- destination cart is marked dirty so its inventory panel repaints.
    local worldItem = {}  -- stub, findWorldItem path in performCartTransfer
    local item = makeItem({ id = 202 })
    item.getWorldItem = function(self) return {
        getSquare = function() return nil end,
        removeFromWorld = function() end,
        removeFromSquare = function() end,
        setSquare = function() end,
    } end
    item.setWorldItem = function(self, v) end
    item.setJobDelta = function(self, v) end
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    local chr = makeCharacter()
    local srcSq = { _type = "IsoGridSquare",
        getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
        transmitRemoveItemFromSquare = function() end }

    SaucedCarts.performCartTransfer(chr, item, nil, cart:getItemContainer(), nil, srcSq)

    return Assert.isTrue(cart:getItemContainer():isDrawDirty(),
        "cart marked dirty on floor→cart pickup")
end

tests["performCartTransfer_marks_src_dirty_on_floor_drop"] = function()
    -- Cart → ground. destContainer is nil; we only care that the
    -- source cart is marked dirty so its inventory panel repaints.
    -- ISTransferAction.GetDropItemOffset is called in the drop branch;
    -- stub it locally so the production code path completes.
    local origGetDropOffset = ISTransferAction and ISTransferAction.GetDropItemOffset
    if ISTransferAction then
        ISTransferAction.GetDropItemOffset = function(p, sq, it) return 0.5, 0.5, 0.0 end
    end

    local item = makeItem({ id = 203 })
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    cart:getItemContainer():AddItem(item)
    local chr = makeCharacter()
    local dropSq = { _type = "IsoGridSquare",
        getX = function() return 1 end, getY = function() return 0 end, getZ = function() return 0 end,
        AddWorldInventoryItem = function(self, it, x, y, h, transmit) return nil end }

    SaucedCarts.performCartTransfer(chr, item, cart:getItemContainer(), nil, dropSq, nil)

    if ISTransferAction then
        ISTransferAction.GetDropItemOffset = origGetDropOffset
    end
    return Assert.isTrue(cart:getItemContainer():isDrawDirty(),
        "cart marked dirty on cart→floor drop")
end

-- Regression: V11 dupe vector (2026-04-24 review). The cart→floor corpse
-- branch runs loadCorpseFromByteData + sendCorpse. ISCartTransferAction is
-- shared, so the dedi executes performCartTransfer twice per drop (its own
-- :perform else-branch + the cartTransfer network command). handleCartTransfer's
-- existing idempotence guard only covers container destinations, not floor
-- drops. Without the new srcContainer:contains guard, loadCorpseFromByteData
-- runs twice → two bodies materialize → two sendCorpse broadcasts → dupe.
tests["performCartTransfer_corpse_floor_double_perform_no_dupe"] = function()
    local origGetDropOffset = ISTransferAction and ISTransferAction.GetDropItemOffset
    if ISTransferAction then
        ISTransferAction.GetDropItemOffset = function(p, sq, it) return 0.5, 0.5, 0.0 end
    end

    -- Build a corpse item that counts loadCorpseFromByteData invocations.
    local item = makeItem({ id = 910, fullType = "Base.CorpseMale" })
    local loadCalls = 0
    item.loadCorpseFromByteData = function(self, sq)
        loadCalls = loadCalls + 1
        -- Return a mock body so the success branch completes normally.
        return {
            getSquare = function() return sq end,
            getX = function() return sq and sq:getX() or 0 end,
            getY = function() return sq and sq:getY() or 0 end,
            getZ = function() return sq and sq:getZ() or 0 end,
        }
    end
    item.isHumanCorpse = function(self) return true end
    item.isAnimalCorpse = function(self) return false end

    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    cart:getItemContainer():AddItem(item)
    local chr = makeCharacter()
    local dropSq = { _type = "IsoGridSquare",
        getX = function() return 1 end, getY = function() return 0 end, getZ = function() return 0 end,
        AddWorldInventoryItem = function(self, it, x, y, h, transmit) return nil end,
        addCorpse = function(self, body, bRemote) self._addCount = (self._addCount or 0) + 1 end }

    -- First invocation: removes item, materializes body, succeeds.
    local ok1 = SaucedCarts.performCartTransfer(chr, item, cart:getItemContainer(), nil, dropSq, nil)
    -- Second invocation (simulates MP double-perform): item already removed
    -- from src. Without the guard, this would loadCorpseFromByteData again.
    local ok2 = SaucedCarts.performCartTransfer(chr, item, cart:getItemContainer(), nil, dropSq, nil)

    if ISTransferAction then
        ISTransferAction.GetDropItemOffset = origGetDropOffset
    end

    if not Assert.isTrue(ok1, "first invocation returns true") then return false end
    if not Assert.isTrue(ok2, "second invocation returns true (idempotent success)") then return false end
    return Assert.equal(loadCalls, 1,
        "loadCorpseFromByteData called EXACTLY ONCE across two performs — " ..
        "idempotence guard prevented V11 MP dupe")
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

-- ============================================================================
-- v2.1.5 regression guards: world-container ↔ cart transfer
-- ============================================================================
-- These tests cover the five specific additions in v2.1.5:
--   1. classifySide recognises world containers via getSourceGrid() → "world"
--   2. resolveSide (inside handleCartTransfer) matches by containerType on tile
--   3. findItemNearPlayer sweeps nearby world containers for itemId
--   4. handleCartTransfer recovers when the client sends a stale srcKind by
--      trusting item:getContainer() over the client's claim
--   5. handleCartTransfer no-ops on duplicate sends (item already in dest)
-- Each test is designed to fail if the corresponding guard is reverted.

require "SaucedCarts/TimedActions/ISCartTransferAction"

--- Minimal world-container fixture: a container bound to a fake IsoGridSquare.
--- Mirrors PZ's shape — an ItemContainer whose getSourceGrid() returns a
--- square with getX/getY/getZ.
local function makeWorldContainer(opts)
    opts = opts or {}
    local sq = {
        _x = opts.x or 100, _y = opts.y or 200, _z = opts.z or 0,
    }
    sq.getX = function(self) return self._x end
    sq.getY = function(self) return self._y end
    sq.getZ = function(self) return self._z end

    local c = makeContainer({ typeName = opts.typeName or "fridge" })
    c.getSourceGrid = function(self) return sq end
    return c, sq
end

--- Install a mock getCell() that returns a cell mapping (x,y,z) → squares.
--- Returns a tearDown closure the test must call before returning.
local function installMockCell(squareMap)
    local origGetCell = _G.getCell
    _G.getCell = function()
        return {
            getGridSquare = function(self, x, y, z)
                return squareMap[string.format("%d,%d,%d", x, y, z)]
            end,
        }
    end
    return function() _G.getCell = origGetCell end
end

-- ── 1. classifySide returns "world" for a world container ──────────────────
tests["classify_side_world_container_returns_world_kind"] = function()
    local fridge = makeWorldContainer({ typeName = "fridge", x = 50, y = 60, z = 1 })
    local kind, cartId, sqX, sqY, sqZ, contType =
        ISCartTransferAction.classifySide(fridge, nil)

    if not Assert.equal(kind, "world", "kind is world") then return false end
    if not Assert.isNil(cartId, "cartId is nil") then return false end
    if not Assert.equal(sqX, 50, "sqX matches") then return false end
    if not Assert.equal(sqY, 60, "sqY matches") then return false end
    if not Assert.equal(sqZ, 1,  "sqZ matches") then return false end
    return Assert.equal(contType, "fridge", "containerType matches")
end

-- ── Sanity: inv container (no getSourceGrid, not a cart) still returns "inv"
tests["classify_side_player_inv_returns_inv_kind"] = function()
    local playerInv = makeContainer({ parent = { _type = "IsoGameCharacter" } })
    -- deliberately no getSourceGrid on this mock
    local kind = ISCartTransferAction.classifySide(playerInv, nil)
    return Assert.equal(kind, "inv", "player inv stays inv")
end

-- ── Bag-kind: container inside a non-cart InventoryItem (equipped backpack)
--    Pre-fix, classifySide fell through to "inv" because getContainingItem
--    returned a non-cart item and getSourceGrid was nil. The server then
--    resolved playerInv as the destination, depositing items into main inv
--    instead of the bag.
local function makeBagItem(opts)
    opts = opts or {}
    local item = {
        _id = opts.id or 7777,
        _type = "InventoryItem",
        _fullType = opts.fullType or "Base.Bag_Schoolbag",
    }
    item.getID = function(self) return self._id end
    item.getFullType = function(self) return self._fullType end
    item.getType = function(self) return "Item" end
    item._innerContainer = makeContainer({
        parent = opts.parent,
        containingItem = item,
        typeName = opts.typeName or "Bag_Schoolbag",
    })
    item.getItemContainer = function(self) return self._innerContainer end
    return item
end

tests["classify_side_equipped_bag_returns_bag_kind"] = function()
    local bag = makeBagItem({ id = 12345 })
    local kind, cartId = ISCartTransferAction.classifySide(bag:getItemContainer(), nil)
    if not Assert.equal(kind, "bag", "kind is bag") then return false end
    return Assert.equal(cartId, 12345, "cartId carries the bag's InventoryItem ID")
end

tests["resolve_side_bag_kind_finds_container_direct"] = function()
    -- Bag directly in player inventory.
    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })
    local bag = makeBagItem({ id = 555, parent = chr._inv })
    chr._inv:AddItem(bag)

    local find = SaucedCarts.CartTransferInterceptor.findInventoryItemRecursive
    local found = find(chr:getInventory(), 555)
    if not Assert.notNil(found, "bag found in player inv") then return false end
    return Assert.equal(found, bag, "found the same bag object")
end

tests["resolve_side_bag_kind_finds_container_nested"] = function()
    -- Bag inside another bag inside player inventory.
    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })
    local outerBag = makeBagItem({ id = 111, parent = chr._inv })
    chr._inv:AddItem(outerBag)
    local innerBag = makeBagItem({ id = 222, parent = outerBag:getItemContainer() })
    outerBag:getItemContainer():AddItem(innerBag)

    local find = SaucedCarts.CartTransferInterceptor.findInventoryItemRecursive
    local found = find(chr:getInventory(), 222)
    if not Assert.notNil(found, "inner bag found via recursion") then return false end
    return Assert.equal(found, innerBag, "found the nested bag")
end

tests["handle_cart_transfer_out_to_bag_lands_in_bag_not_inv"] = function()
    -- End-to-end: cart -> equipped bag with destKind="bag". Pre-fix this
    -- deposited into playerInv (the bug the user reported).

    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })
    chr.getCurrentSquare = function() return nil end  -- no-op for this test

    local cart = makeCartItem({ id = 999, parent = chr })
    chr._inv:AddItem(cart)
    local cartCont = cart:getItemContainer()

    local bag = makeBagItem({ id = 500, parent = chr._inv })
    chr._inv:AddItem(bag)
    local bagCont = bag:getItemContainer()

    local bottle = makeItem({ id = 42, fullType = "Base.PopBottle" })
    cartCont:AddItem(bottle)

    -- Stub out the performCartTransfer path so we can observe what src/dest
    -- were computed without invoking real ISTransferAction machinery.
    local origPerform = SaucedCarts.performCartTransfer
    local observedSrc, observedDest
    SaucedCarts.performCartTransfer = function(p, it, src, dest)
        observedSrc, observedDest = src, dest
        if src and src.DoRemoveItem then src:DoRemoveItem(it) end
        if dest and dest.AddItem then dest:AddItem(it) end
        return true
    end

    local handle = SaucedCarts.CartTransferInterceptor.handleCartTransfer
    handle(chr, {
        itemId     = 42,
        cartId     = 999,
        direction  = "out",
        srcKind    = "cart",
        srcCartId  = 999,
        destKind   = "bag",
        destCartId = 500,
    })

    SaucedCarts.performCartTransfer = origPerform

    if not Assert.equal(observedSrc, cartCont, "src is cart's inner container") then return false end
    if not Assert.equal(observedDest, bagCont, "dest is bag's inner container (NOT playerInv)") then return false end
    if not Assert.notNil(bagCont:getItemById(42), "bottle landed in bag") then return false end
    return Assert.isNil(chr._inv:getItemById(42), "bottle did NOT land in main inv")
end

tests["handle_cart_transfer_in_from_bag_uses_bag_as_src"] = function()
    -- Reverse: bag -> cart with srcKind="bag".
    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })
    chr.getCurrentSquare = function() return nil end

    local cart = makeCartItem({ id = 888, parent = chr })
    chr._inv:AddItem(cart)
    local cartCont = cart:getItemContainer()

    local bag = makeBagItem({ id = 600, parent = chr._inv })
    chr._inv:AddItem(bag)
    local bagCont = bag:getItemContainer()

    local bottle = makeItem({ id = 43, fullType = "Base.PopBottle" })
    bagCont:AddItem(bottle)

    local origPerform = SaucedCarts.performCartTransfer
    local observedSrc, observedDest
    SaucedCarts.performCartTransfer = function(p, it, src, dest)
        observedSrc, observedDest = src, dest
        if src and src.DoRemoveItem then src:DoRemoveItem(it) end
        if dest and dest.AddItem then dest:AddItem(it) end
        return true
    end

    local handle = SaucedCarts.CartTransferInterceptor.handleCartTransfer
    handle(chr, {
        itemId     = 43,
        cartId     = 888,
        direction  = "in",
        srcKind    = "bag",
        srcCartId  = 600,
        destKind   = "cart",
        destCartId = 888,
    })

    SaucedCarts.performCartTransfer = origPerform

    if not Assert.equal(observedSrc, bagCont, "src is bag's inner container (NOT playerInv)") then return false end
    if not Assert.equal(observedDest, cartCont, "dest is cart's inner container") then return false end
    if not Assert.notNil(cartCont:getItemById(43), "bottle landed in cart") then return false end
    return Assert.isNil(bagCont:getItemById(43), "bottle left the bag")
end

-- ── 3. findItemNearPlayer sweeps world containers ──────────────────────────
tests["find_item_near_player_scans_world_containers"] = function()
    -- Player stands at (100, 200, 0); fridge is one tile north.
    local fridge, fridgeSq = makeWorldContainer({ typeName = "fridge", x = 100, y = 201, z = 0 })
    local cabbage = makeItem({ id = 555 })
    fridge:AddItem(cabbage)

    -- Build the tile object that "owns" the fridge container.
    local fridgeObj = { getContainer = function() return fridge end }
    -- Populate square.getObjects + getWorldObjects.
    fridgeSq.getObjects = function(self)
        local list = { fridgeObj }; list.size = function() return 1 end
        list.get = function(s, i) return list[i + 1] end
        return list
    end
    fridgeSq.getWorldObjects = function(self)
        local list = {}; list.size = function() return 0 end
        list.get = function() return nil end
        return list
    end

    -- Player square (starting point).
    local playerSq = { _x = 100, _y = 200, _z = 0,
        getX = function(self) return self._x end,
        getY = function(self) return self._y end,
        getZ = function(self) return self._z end,
        getObjects = fridgeSq.getObjects,        -- reuse: only 1 tile in map
        getWorldObjects = fridgeSq.getWorldObjects,
    }
    -- Reassign: player square has no fridge, only the north tile does.
    local emptyList = (function() local l = {}; l.size = function() return 0 end; l.get = function() return nil end; return l end)()
    playerSq.getObjects = function() return emptyList end
    playerSq.getWorldObjects = function() return emptyList end

    -- Mock a player with that square + an empty inventory.
    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })
    chr.getCurrentSquare = function(self) return playerSq end

    -- Map from coord-string → square. Build a 3x3 region around (100,200,0).
    local squareMap = {}
    for dy = -1, 1 do
        for dx = -1, 1 do
            local key = string.format("%d,%d,%d", 100 + dx, 200 + dy, 0)
            if dy == 1 and dx == 0 then
                squareMap[key] = fridgeSq
            else
                squareMap[key] = playerSq
            end
        end
    end
    local tearDown = installMockCell(squareMap)

    local find = SaucedCarts.CartTransferInterceptor.findItemNearPlayer
    local got = find(chr, 555, 1)
    tearDown()

    if not Assert.notNil(got, "item found in nearby world container") then return false end
    return Assert.equal(got:getID(), 555, "correct itemId returned")
end

-- ── 4. handleCartTransfer uses item:getContainer() when client lies ────────
tests["handle_cart_transfer_recovers_when_client_claims_wrong_src"] = function()
    -- Scenario: pre-v2.1.5 client classifies a fridge as "inv" and sends
    -- srcKind=inv. Item actually lives in the fridge. The handler's
    -- defensive fallback should detect the mismatch and use the fridge.

    local fridge, fridgeSq = makeWorldContainer({ typeName = "fridge", x = 100, y = 200, z = 0 })
    local cart = makeCartItem({ id = 999, parent = { _type = "IsoGameCharacter" } })
    local cartCont = cart:getItemContainer()

    local item = makeItem({ id = 777, fullType = "Base.Cabbage" })
    fridge:AddItem(item)          -- item currently lives in fridge

    -- Player has the cart in inv so findCartNearPlayer finds it.
    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })
    chr._inv:AddItem(cart)
    -- Player square + mock cell so findItemNearPlayer's world-container
    -- sweep finds the fridge (which is on the same tile here).
    local playerSq = {
        getX = function() return 100 end,
        getY = function() return 200 end,
        getZ = function() return 0 end,
    }
    local fridgeObj = { getContainer = function() return fridge end }
    playerSq.getObjects = function()
        local l = { fridgeObj }
        l.size = function() return 1 end; l.get = function(s, i) return l[i + 1] end
        return l
    end
    playerSq.getWorldObjects = function()
        local l = {}; l.size = function() return 0 end; l.get = function() return nil end
        return l
    end
    chr.getCurrentSquare = function() return playerSq end

    local squareMap = {}
    for dy = -1, 1 do for dx = -1, 1 do
        squareMap[string.format("%d,%d,%d", 100 + dx, 200 + dy, 0)] = playerSq
    end end
    local tearDown = installMockCell(squareMap)

    -- Client's (wrong) payload: srcKind="inv" even though item's in the fridge.
    local args = {
        itemId = 777, cartId = 999, direction = "in",
        srcKind = "inv", destKind = "cart", destCartId = 999,
    }
    SaucedCarts.CartTransferInterceptor.handleCartTransfer(chr, args)
    tearDown()

    if not Assert.isFalse(fridge:contains(item), "item left fridge") then return false end
    return Assert.isTrue(cartCont:contains(item), "item arrived in cart")
end

-- ── 5. handleCartTransfer no-ops on duplicate sends ────────────────────────
tests["handle_cart_transfer_noop_on_duplicate_send"] = function()
    -- Scenario: the first cartTransfer already moved the item into the cart.
    -- A duplicate send fires for the same itemId. Before v2.1.5 the handler
    -- would re-run performCartTransfer with src=cart/dest=cart (defensive
    -- fallback picked the item's current container = cart), broadcasting a
    -- spurious remove+add cycle that hit clients with "container already has
    -- id". With the idempotence check, it no-ops — never reaching
    -- performCartTransfer at all.

    local cart = makeCartItem({ id = 888, parent = { _type = "IsoGameCharacter" } })
    local cartCont = cart:getItemContainer()
    local item = makeItem({ id = 321 })
    cartCont:AddItem(item)        -- item already in cart

    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })
    chr._inv:AddItem(cart)
    local playerSq = {
        getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
    }
    local emptyList = (function() local l = {}; l.size = function() return 0 end; l.get = function() return nil end; return l end)()
    playerSq.getObjects      = function() return emptyList end
    playerSq.getWorldObjects = function() return emptyList end
    chr.getCurrentSquare = function() return playerSq end

    local squareMap = {}
    for dy = -1, 1 do for dx = -1, 1 do
        squareMap[string.format("%d,%d,%d", dx, dy, 0)] = playerSq
    end end
    local tearDown = installMockCell(squareMap)

    -- Spy on performCartTransfer directly. Idempotence short-circuits BEFORE
    -- calling it, so if the check is present this counter stays 0. If the
    -- check is reverted, the handler reaches performCartTransfer with
    -- src==dest (cart→cart cycle) → counter > 0.
    local origPerform = SaucedCarts.performCartTransfer
    local performCallCount = 0
    SaucedCarts.performCartTransfer = function(...)
        performCallCount = performCallCount + 1
        return true   -- don't actually run it
    end

    local args = {
        itemId = 321, cartId = 888, direction = "in",
        srcKind = "inv", destKind = "cart", destCartId = 888,
    }
    local ok = pcall(SaucedCarts.CartTransferInterceptor.handleCartTransfer, chr, args)
    SaucedCarts.performCartTransfer = origPerform
    tearDown()

    if not Assert.isTrue(ok, "handler did not throw") then return false end
    return Assert.equal(performCallCount, 0,
        "idempotence: performCartTransfer NOT called when item already in dest cart")
end

-- ============================================================================
-- Malformed-args gauntlet (v2.1.5+ robustness)
-- ============================================================================
-- handleCartTransfer is the single entry point every MP client hits. Any arg
-- shape that crashes it on the server side is a reliable DoS or desync. This
-- section fires every broken payload we can think of at the handler and
-- asserts three invariants for each:
--
--   1. pcall(handler) returns true  — no throw
--   2. no sendAddItemToContainer broadcast fires (no spurious add)
--   3. no sendRemoveItemFromContainer broadcast fires (no spurious remove)
--
-- A real transfer goes through performCartTransfer which eventually calls
-- both broadcast functions; we wrap them in counters and expect counts of 0
-- for malformed requests.

local function makeGauntletScene()
    -- A fresh scene for each test: one player, one cart in their inv, one
    -- item in the cart (so we have a known pre-state to verify stays intact).
    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })
    local cart = makeCartItem({ id = 10001, parent = chr })
    chr._inv:AddItem(cart)
    local item = makeItem({ id = 20001 })
    cart:getItemContainer():AddItem(item)
    local playerSq = {
        getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
    }
    local emptyList = (function() local l = {}; l.size = function() return 0 end; l.get = function() return nil end; return l end)()
    playerSq.getObjects      = function() return emptyList end
    playerSq.getWorldObjects = function() return emptyList end
    chr.getCurrentSquare = function() return playerSq end
    return chr, cart, item, playerSq
end

local function installBroadcastCounters()
    local counters = { add = 0, remove = 0 }
    local origAdd = _G.sendAddItemToContainer
    local origRemove = _G.sendRemoveItemFromContainer
    _G.sendAddItemToContainer    = function() counters.add    = counters.add    + 1 end
    _G.sendRemoveItemFromContainer = function() counters.remove = counters.remove + 1 end
    return counters, function()
        _G.sendAddItemToContainer    = origAdd
        _G.sendRemoveItemFromContainer = origRemove
    end
end

-- Run a single malformed-args case: fires the handler, asserts no throw,
-- no spurious broadcasts, cart still contains the original item.
local function runGauntletCase(caseName, args)
    local chr, cart, item, sq = makeGauntletScene()
    local counters, tearBroadcast = installBroadcastCounters()
    local squareMap = {}
    for dy = -1, 1 do for dx = -1, 1 do
        squareMap[string.format("%d,%d,%d", dx, dy, 0)] = sq
    end end
    local tearCell = installMockCell(squareMap)

    local handler = SaucedCarts.CartTransferInterceptor.handleCartTransfer
    local ok, err = pcall(handler, chr, args)
    tearCell()
    tearBroadcast()

    if not Assert.isTrue(ok, caseName .. " did not throw: " .. tostring(err)) then return false end
    if not Assert.equal(counters.add, 0, caseName .. " fired no spurious add broadcast") then return false end
    if not Assert.equal(counters.remove, 0, caseName .. " fired no spurious remove broadcast") then return false end
    return Assert.isTrue(cart:getItemContainer():contains(item),
        caseName .. " left original item in cart intact")
end

tests["gauntlet_nil_args"]                = function() return runGauntletCase("nil args", nil) end
tests["gauntlet_empty_args"]              = function() return runGauntletCase("empty args", {}) end
tests["gauntlet_missing_itemId"]          = function() return runGauntletCase("no itemId",
    { cartId = 10001, direction = "in", srcKind = "inv", destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_missing_cartId"]          = function() return runGauntletCase("no cartId",
    { itemId = 20001, direction = "in", srcKind = "inv", destKind = "cart" }) end
tests["gauntlet_unknown_cart"]            = function() return runGauntletCase("unknown cartId",
    { itemId = 20001, cartId = 99999999, direction = "in", srcKind = "inv", destKind = "cart", destCartId = 99999999 }) end
tests["gauntlet_unknown_item"]            = function() return runGauntletCase("unknown itemId",
    { itemId = 99999999, cartId = 10001, direction = "in", srcKind = "inv", destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_string_itemId"]           = function() return runGauntletCase("string itemId",
    { itemId = "haha", cartId = 10001, direction = "in", srcKind = "inv", destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_string_cartId"]           = function() return runGauntletCase("string cartId",
    { itemId = 20001, cartId = "woot", direction = "in", srcKind = "inv", destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_bogus_direction"]         = function() return runGauntletCase("bogus direction",
    { itemId = 20001, cartId = 10001, direction = "sideways", srcKind = "inv", destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_missing_direction"]       = function() return runGauntletCase("no direction",
    { itemId = 20001, cartId = 10001, srcKind = "inv", destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_world_kind_partial_coords"] = function() return runGauntletCase("world kind, partial coords",
    { itemId = 20001, cartId = 10001, direction = "in",
      srcKind = "world", srcContType = "fridge", srcSqX = 5, srcSqZ = 0, -- missing sqY
      destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_world_kind_no_containerType"] = function() return runGauntletCase("world kind, no containerType",
    { itemId = 20001, cartId = 10001, direction = "in",
      srcKind = "world", srcSqX = 5, srcSqY = 5, srcSqZ = 0,
      destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_world_kind_bogus_coords"] = function() return runGauntletCase("world kind, square far away",
    { itemId = 20001, cartId = 10001, direction = "in",
      srcKind = "world", srcContType = "fridge", srcSqX = 99999, srcSqY = 99999, srcSqZ = 0,
      destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_world_kind_no_matching_type"] = function() return runGauntletCase("world kind, container type not on tile",
    { itemId = 20001, cartId = 10001, direction = "in",
      srcKind = "world", srcContType = "nonexistenttype", srcSqX = 0, srcSqY = 0, srcSqZ = 0,
      destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_nil_player"]              = function()
    -- Special case: not using gauntlet helper because we want a nil player.
    local args = { itemId = 20001, cartId = 10001, direction = "in" }
    local counters, tear = installBroadcastCounters()
    local ok = pcall(SaucedCarts.CartTransferInterceptor.handleCartTransfer, nil, args)
    tear()
    if not Assert.isTrue(ok, "nil player did not throw") then return false end
    if not Assert.equal(counters.add, 0, "nil player: no add broadcast") then return false end
    return Assert.equal(counters.remove, 0, "nil player: no remove broadcast")
end
tests["gauntlet_floor_kind_missing_coords"] = function() return runGauntletCase("floor kind, missing coords",
    { itemId = 20001, cartId = 10001, direction = "in",
      srcKind = "floor",
      destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_self_transfer"]           = function() return runGauntletCase("src and dest both the same cart",
    { itemId = 20001, cartId = 10001, direction = "in",
      srcKind = "cart", srcCartId = 10001,
      destKind = "cart", destCartId = 10001 }) end
tests["gauntlet_massive_ids"]             = function() return runGauntletCase("absurd ID values",
    { itemId = 1e15, cartId = 1e15, direction = "in", srcKind = "inv", destKind = "cart", destCartId = 1e15 }) end
tests["gauntlet_negative_ids"]            = function() return runGauntletCase("negative ID values",
    { itemId = -1, cartId = -1, direction = "in", srcKind = "inv", destKind = "cart", destCartId = -1 }) end
tests["gauntlet_srcKind_unknown"]         = function() return runGauntletCase("unknown srcKind string",
    { itemId = 20001, cartId = 10001, direction = "in", srcKind = "wormhole", destKind = "cart", destCartId = 10001 }) end

-- ============================================================================
-- Property-based fuzzer (v2.1.5 invariant guard)
-- ============================================================================
-- Generates a random scene of containers (player inv + 1-2 carts + 0-2 world
-- containers), seeds it with random items, then runs N random valid transfers
-- and asserts three invariants after each:
--
--   1. CONSERVATION: total item count across all containers is unchanged
--   2. UNIQUENESS:   no itemId appears in two different containers
--   3. MOVED-OR-NOT: each item is in exactly one container (either src or dest)
--
-- Seeds are per-iteration so failures are reproducible — failure message
-- includes the seed + args so the offender can be rerun standalone.

local ITERATIONS = 1000

-- PZ's Kahlua doesn't expose math.randomseed / math.random. Bring our own
-- deterministic LCG so failing iterations are reproducible by seed. Park-
-- Miller "minimal standard" with modulus 2^31-1.
local function makeRng(seed)
    local state = seed or 1
    if state == 0 then state = 1 end  -- LCG needs non-zero seed
    return function(lo, hi)
        state = (state * 48271) % 2147483647
        if not lo then return state end
        hi = hi or lo
        if lo > hi then lo, hi = hi, lo end
        return lo + (state % (hi - lo + 1))
    end
end

-- Build a scene: chr + carts + world containers + items + cell mock. Returns
-- a table with the pieces and a tearDown to restore globals.
local function buildRandomScene(rng)
    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr })

    -- 1-2 carts in the player's inventory.
    local carts = {}
    local cartCount = 1 + rng(0, 1)
    for i = 1, cartCount do
        local cart = makeCartItem({ id = 1000 + i, parent = chr })
        chr._inv:AddItem(cart)
        carts[#carts + 1] = cart
    end

    -- 0-2 world containers on tiles nearby.
    local worldContainers = {}
    local squareMap = {}
    local emptyList = (function() local l = {}; l.size = function() return 0 end; l.get = function() return nil end; return l end)()

    -- Player's square: no containers on it, just coord anchor.
    local playerSq = { _x = 0, _y = 0, _z = 0 }
    playerSq.getX = function() return 0 end
    playerSq.getY = function() return 0 end
    playerSq.getZ = function() return 0 end
    playerSq.getObjects      = function() return emptyList end
    playerSq.getWorldObjects = function() return emptyList end
    chr.getCurrentSquare = function() return playerSq end
    squareMap["0,0,0"] = playerSq

    local worldCount = rng(0, 2)
    for i = 1, worldCount do
        local dx, dy = rng(-1, 1), rng(-1, 1)
        if dx == 0 and dy == 0 then dx = 1 end
        local cont, sq = makeWorldContainer({
            typeName = "wc" .. i, x = dx, y = dy, z = 0
        })
        local obj = { getContainer = function() return cont end }
        sq.getObjects = function()
            local l = { obj }; l.size = function() return 1 end; l.get = function(s, i2) return l[i2 + 1] end
            return l
        end
        sq.getWorldObjects = function() return emptyList end
        squareMap[string.format("%d,%d,%d", dx, dy, 0)] = sq
        worldContainers[#worldContainers + 1] = cont
    end
    -- Fill in unoccupied neighbors so findItemNearPlayer's sweep doesn't hit nil squares.
    for dy = -2, 2 do for dx = -2, 2 do
        local k = string.format("%d,%d,%d", dx, dy, 0)
        if not squareMap[k] then
            local emptySq = {
                getX = function() return dx end, getY = function() return dy end, getZ = function() return 0 end,
                getObjects = function() return emptyList end,
                getWorldObjects = function() return emptyList end,
            }
            squareMap[k] = emptySq
        end
    end end

    -- 5-15 items distributed across ALL containers (player inv, cart inners, world conts).
    local items = {}
    local allContainers = { chr._inv }
    for _, c in ipairs(carts) do allContainers[#allContainers + 1] = c:getItemContainer() end
    for _, wc in ipairs(worldContainers) do allContainers[#allContainers + 1] = wc end

    local itemCount = rng(5, 15)
    for i = 1, itemCount do
        local item = makeItem({ id = 2000 + i })
        local target = allContainers[rng(1, #allContainers)]
        target:AddItem(item)
        items[#items + 1] = item
    end

    local tearCell = installMockCell(squareMap)

    return {
        chr = chr, carts = carts, worldContainers = worldContainers,
        items = items, allContainers = allContainers,
        tearDown = tearCell,
    }
end

-- Generate a valid transfer for this scene: pick a random item that lives
-- somewhere, pick a random dest cart that doesn't already contain it.
-- When oldClient=true, force srcKind="inv" to simulate a pre-v2.1.5 client
-- that misclassifies world containers — exercises the defensive fallback.
local function randomTransferArgs(scene, rng, oldClient)
    -- Pick an item that's currently in SOMETHING (not freshly-created floaters).
    local item, srcCont
    for _ = 1, 20 do
        local candidate = scene.items[rng(1, #scene.items)]
        local where = candidate.getContainer and candidate:getContainer()
        if where then item = candidate; srcCont = where; break end
    end
    if not item then return nil end

    -- Pick a dest cart. Any of the scene's carts is fine.
    local destCart = scene.carts[rng(1, #scene.carts)]

    -- Classify srcCont to build realistic args (matches what client's classifySide would send).
    local srcKind, srcCartId, srcSqX, srcSqY, srcSqZ, srcContType = "inv", nil, nil, nil, nil, nil
    if not oldClient then
        local ci = srcCont.getContainingItem and srcCont:getContainingItem()
        if ci and SaucedCarts.safeIsCart(ci) then
            srcKind, srcCartId = "cart", ci:getID()
        else
            local sg = srcCont.getSourceGrid and srcCont:getSourceGrid()
            if sg and sg.getX then
                srcKind = "world"
                srcSqX, srcSqY, srcSqZ = sg:getX(), sg:getY(), sg:getZ()
                srcContType = srcCont:getType()
            end
        end
    end
    -- oldClient mode: srcKind stays "inv" regardless of actual container,
    -- exactly reproducing the v2.1.4 client bug.

    return {
        itemId = item:getID(), cartId = destCart:getID(),
        direction = "in",
        srcKind = srcKind, srcCartId = srcCartId,
        srcSqX = srcSqX, srcSqY = srcSqY, srcSqZ = srcSqZ, srcContType = srcContType,
        destKind = "cart", destCartId = destCart:getID(),
    }, item, srcCont, destCart:getItemContainer()
end

-- Scan every container, return { [itemId] = list of containers that hold it }.
local function scanItemLocations(scene)
    local locs = {}
    for _, c in ipairs(scene.allContainers) do
        local items = c:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local id = it:getID()
            if not locs[id] then locs[id] = {} end
            table.insert(locs[id], c)
        end
    end
    return locs
end

tests["fuzz_random_transfers_preserve_invariants"] = function()
    local failures = 0
    local firstFailure = nil
    local firstError = nil
    local stage = "init"
    for seed = 1, ITERATIONS do
    local iterOk, iterErr = pcall(function()
    stage = "seedReset"
        stage = "buildScene"
        local rng = makeRng(seed)
        local scene = buildRandomScene(rng)
        stage = "sceneBuilt"

        -- Snapshot pre-state.
        local preLocs = scanItemLocations(scene)
        local preCount = 0
        for _ in pairs(preLocs) do preCount = preCount + 1 end

        -- Alternate between new-client and old-client per iteration so the
        -- fuzzer exercises BOTH code paths: 50% hit the new v2.1.5 classifier
        -- path, 50% hit the defensive fallback for pre-v2.1.5 clients.
        local oldClient = (seed % 2 == 0)
        local args, item, srcCont, destCont = randomTransferArgs(scene, rng, oldClient)
        if args then
            pcall(SaucedCarts.CartTransferInterceptor.handleCartTransfer, scene.chr, args)

            -- Check invariants.
            local postLocs = scanItemLocations(scene)
            local postCount = 0
            for _ in pairs(postLocs) do postCount = postCount + 1 end

            local fail = nil
            if postCount ~= preCount then
                fail = string.format("CONSERVATION lost: pre=%d post=%d items", preCount, postCount)
            end
            if not fail then
                for id, conts in pairs(postLocs) do
                    if #conts > 1 then
                        fail = string.format("UNIQUENESS broken: itemId=%d in %d containers", id, #conts)
                        break
                    end
                end
            end
            if not fail then
                -- Moved-or-not: item must be in exactly one place.
                local finalLocs = postLocs[item:getID()]
                if not finalLocs or #finalLocs ~= 1 then
                    fail = string.format("MOVED-OR-NOT broken: item %d in %d containers",
                        item:getID(), finalLocs and #finalLocs or 0)
                end
            end

            if fail and not firstFailure then
                firstFailure = string.format("seed=%d: %s\n  args: srcKind=%s srcContType=%s destCartId=%s",
                    seed, fail, tostring(args.srcKind), tostring(args.srcContType), tostring(args.destCartId))
                failures = failures + 1
            end
        end

        scene.tearDown()
    end)
    if not iterOk and not firstError then
        firstError = string.format("seed=%d CRASHED: %s", seed, tostring(iterErr))
    end
    end

    if firstError then return Assert.isTrue(false, "stage=" .. stage .. " " .. firstError) end
    if firstFailure then return Assert.isTrue(false, firstFailure) end
    return Assert.equal(failures, 0, ITERATIONS .. " random transfers preserved all invariants")
end

return tests
