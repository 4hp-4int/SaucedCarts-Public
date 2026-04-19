--[[
    SaucedCarts — Cart deposit interception + server handler tests
    ==============================================================

    Proves the narrow-scope interception logic fires exactly when the
    target case applies (vanilla's Transaction system would reject the
    transfer due to Java-internal capacity cap), and stays out of the
    way otherwise.

    Also exercises SaucedCarts.performCartDeposit — the shared move
    helper used by both the SP path and the server-command handler — to
    confirm it respects capacity and updates both containers correctly.
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
        _typeName = opts.typeName or "bag",   -- for getType() — vanilla differentiates "floor", "TradeUI", etc.
    }
    c.getParent = function(self) return self._parent end
    c.getContainingItem = function(self) return self._containingItem end
    c.getType = function(self) return self._typeName end
    c.contains = function(self, item)
        for _, it in ipairs(self._items) do if it == item then return true end end
        return false
    end
    c.AddItem = function(self, item) table.insert(self._items, item); return item end
    c.DoAddItemBlind = c.AddItem  -- vanilla uses this for floor-drop path
    c.Remove = function(self, item)
        for i, it in ipairs(self._items) do
            if it == item then table.remove(self._items, i); return end
        end
    end
    -- Vanilla ISTransferAction:transferItem calls DoRemoveItem. Our mock
    -- aliases it to Remove since the behaviour is the same for tests.
    c.DoRemoveItem = c.Remove
    c.hasRoomFor = function(self, chr, itemOrWeight) return opts.hasRoom ~= false end
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
    -- Cart's inner container. Parent defaults to nil (ground cart case).
    item._innerContainer = makeContainer({
        parent = opts.parent,
        containingItem = item,
        hasRoom = opts.hasRoom,
    })
    item.getItemContainer = function(self) return self._innerContainer end
    item.getContainer = function(self) return self._outerContainer end
    return item
end

local function makeCharacter()
    local ch = { _type = "IsoPlayer", _inv = nil }
    ch.getOnlineID = function(self) return 1 end
    ch.getInventory = function(self) return self._inv end
    ch.isEquipped = function(self, item) return false end
    ch.removeAttachedItem = function(self, item) end
    ch.removeFromHands = function(self, item) end
    ch.removeWornItem = function(self, item, b) end
    return ch
end

-- Override safeIsCart so our mock items qualify.
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer" and item._fullType
        and item._fullType:find("^SaucedCarts") then
        return true
    end
    return origSafeIsCart(item)
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

-- Narrow scope: dest container is a cart AND parent is not a character ->
-- interception fires. This is the exact failure case (ground / vehicle-
-- container cart).
tests["intercepts_when_cart_dest_parent_not_character"] = function()
    local cart = makeCartItem({ parent = { _type = "IsoGridSquare" } })
    local dest = cart:getItemContainer()
    return Assert.isTrue(
        SaucedCarts.CartTransferInterceptor.shouldInterceptTransfer(dest),
        "ground-parented cart dest: should intercept")
end

-- Narrow scope: dest container is a cart BUT parent is a character ->
-- vanilla's TransactionManager accepts this path. Don't intercept.
tests["passes_through_when_cart_dest_parent_is_character"] = function()
    local cart = makeCartItem({ parent = { _type = "IsoGameCharacter" } })
    local dest = cart:getItemContainer()
    return Assert.isFalse(
        SaucedCarts.CartTransferInterceptor.shouldInterceptTransfer(dest),
        "in-hand cart dest: do NOT intercept")
end

-- Narrow scope: dest is not a cart at all -> vanilla should handle.
tests["passes_through_when_dest_not_a_cart"] = function()
    local nonCart = makeContainer({ parent = { _type = "IsoGridSquare" } })
    return Assert.isFalse(
        SaucedCarts.CartTransferInterceptor.shouldInterceptTransfer(nonCart),
        "non-cart dest: do NOT intercept")
end

-- Nil-safety: absent destination container -> do NOT intercept.
tests["passes_through_when_dest_nil"] = function()
    return Assert.isFalse(
        SaucedCarts.CartTransferInterceptor.shouldInterceptTransfer(nil),
        "nil dest: do NOT intercept")
end

-- Dest parent is a BaseVehicle (vehicle container cart). Not a character,
-- so interception DOES fire. Vanilla's transaction path would also fail
-- here for the same reason as ground carts.
tests["intercepts_when_cart_dest_parent_is_vehicle"] = function()
    local cart = makeCartItem({ parent = { _type = "BaseVehicle" } })
    local dest = cart:getItemContainer()
    return Assert.isTrue(
        SaucedCarts.CartTransferInterceptor.shouldInterceptTransfer(dest),
        "vehicle-container cart dest: should intercept")
end

-- ============================================================================
-- performCartDeposit move helper
-- ============================================================================

tests["performCartDeposit_moves_item_from_src_to_cart"] = function()
    local item = { _id = 101, _type = "InventoryItem" }
    item.getID = function(self) return self._id end
    item.getType = function(self) return "Item" end   -- vanilla calls :getType()
    item.getWorldItem = function(self) return nil end

    local src = makeContainer()
    src:AddItem(item)
    item._outerContainer = src
    item.getContainer = function(self) return src end

    local cart = makeCartItem()
    local chr = makeCharacter()

    local ok = SaucedCarts.performCartDeposit(chr, item, cart)

    if not Assert.isTrue(ok, "deposit succeeded") then return false end
    if not Assert.isFalse(src:contains(item), "item left source") then return false end
    return Assert.isTrue(cart:getItemContainer():contains(item), "item in cart")
end

tests["performCartDeposit_refuses_when_cart_full"] = function()
    local item = { _id = 102, _type = "InventoryItem" }
    item.getID = function(self) return self._id end
    item.getType = function(self) return "Item" end
    item.getWorldItem = function(self) return nil end

    local src = makeContainer()
    src:AddItem(item)
    item._outerContainer = src
    item.getContainer = function(self) return src end

    -- Simulate full cart via hasRoom = false
    local cart = makeCartItem({ hasRoom = false })
    local chr = makeCharacter()

    local ok = SaucedCarts.performCartDeposit(chr, item, cart)

    if not Assert.isFalse(ok, "deposit refused") then return false end
    if not Assert.isTrue(src:contains(item), "item still in source") then return false end
    return Assert.isFalse(cart:getItemContainer():contains(item), "item NOT in cart")
end

tests["performCartDeposit_nil_safe"] = function()
    local chr = makeCharacter()
    if not Assert.isFalse(SaucedCarts.performCartDeposit(nil, nil, nil),
        "all-nil: false") then return false end
    if not Assert.isFalse(SaucedCarts.performCartDeposit(chr, nil, nil),
        "missing item: false") then return false end
    return Assert.isFalse(SaucedCarts.performCartDeposit(chr, {}, nil),
        "missing cart: false")
end

-- The safeIsCart override stays for the duration of the run. It's
-- additive (recognizes our Lua-table mocks while delegating to the
-- original for real userdata items), so other tests are unaffected.

return tests
