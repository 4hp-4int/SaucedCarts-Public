--[[
    SaucedCarts — Cart transfer content-sprite refresh regression
    =============================================================

    Player reports (v2.1.6 Workshop): transferring items between a cart and a
    container whose sprite reflects its contents — bookcase showing books,
    fridge/freezer, stacked boxes — leaves the container's sprite STALE.
    Happens in SP, no errors thrown.

    Root cause: CartTransferInterceptor replaces vanilla ISInventoryTransfer-
    Action with ISCartTransferAction → SaucedCarts.performCartTransfer. Vanilla
    ISInventoryTransferAction:transferItem refreshes content-display furniture
    via ItemPicker.updateOverlaySprite(container:getParent()) (server/SP only,
    ISInventoryTransferAction.lua:661-668). performCartTransfer only called
    setDrawDirty (repaints the inventory PANEL, not the world object overlay),
    so the furniture sprite never updated.

    These tests assert the overlay refresh fires for the furniture side of a
    cart<->container move. Pre-fix: 0 calls (fail). Post-fix: called.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartTransferInterceptor"

-- ----------------------------------------------------------------------------
-- Mocks (mirror OfflineCartDepositTests' proven container/item surface, the
-- minimum ISTransferAction:transferItem needs, plus a furniture parent that
-- carries an overlay sprite like a bookcase/fridge/crate does).
-- ----------------------------------------------------------------------------

local function makeContainer(opts)
    opts = opts or {}
    local c = {
        _items = {}, _parent = opts.parent,
        _containingItem = opts.containingItem,
        _typeName = opts.typeName or "shelves",
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
    c.hasRoomFor = function(self) return opts.hasRoom ~= false end
    c._drawDirtyCount = 0
    c.setDrawDirty = function(self) self._drawDirtyCount = self._drawDirtyCount + 1 end
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
    end
    return c
end

local function makeFurnitureParent(spy)
    -- An IsoObject that, like a bookcase/crate/fridge, has an overlay sprite
    -- driven by its contents.
    return {
        _type = "IsoObject",
        getOverlaySprite = function(self) return "overlay_books" end,
        _spy = spy,
    }
end

local function makeCartItem(opts)
    opts = opts or {}
    local item = { _id = opts.id or 42, _type = "InventoryContainer",
        _fullType = "SaucedCarts.ShoppingCart" }
    item.getID = function(self) return self._id end
    item.getFullType = function(self) return self._fullType end
    item._innerContainer = makeContainer({
        parent = opts.parent or { _type = "IsoGridSquare" },
        containingItem = item, typeName = "ShoppingCart",
    })
    item.getItemContainer = function(self) return self._innerContainer end
    item.getContainer = function(self) return self._outerContainer end
    return item
end

local function makeItem(opts)
    opts = opts or {}
    local item = { _id = opts.id or 100, _type = "InventoryItem",
        _fullType = opts.fullType or "Base.Book" }
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
    ch.isEquipped = function(self) return false end
    ch.removeAttachedItem = function(self) end
    ch.removeFromHands = function(self) end
    ch.removeWornItem = function(self) end
    ch.getX = function(self) return 10.0 end
    ch.getY = function(self) return 10.0 end
    ch.getZ = function(self) return 0.0 end
    ch.isSeatedInVehicle = function(self) return false end
    return ch
end

-- Lua-table cart mocks must pass safeIsCart (same additive shim the sibling
-- deposit tests use).
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item._fullType and item._fullType:find("^SaucedCarts") then
        return true
    end
    return origSafeIsCart(item)
end

-- performCartTransfer's overlay refresh is server/SP-authoritative (mirrors
-- vanilla's `if not isClient()` gate). The reported bug is SP; the kit
-- defaults isClient()=true, so simulate SP for the duration of a call.
local function asSingleplayer(fn)
    local origIsClient, origIsServer = isClient, isServer
    isClient = function() return false end
    isServer = function() return false end
    local ok, err = pcall(fn)
    isClient, isServer = origIsClient, origIsServer
    if not ok then error(err) end
end

-- Spy on the global ItemPicker.updateOverlaySprite (vanilla's content-sprite
-- refresh entrypoint). Record which parent objects it was asked to refresh.
local function withOverlaySpy(fn)
    local origItemPicker = ItemPicker
    local calls = {}
    ItemPicker = {
        updateOverlaySprite = function(obj) table.insert(calls, obj) end,
    }
    local ok, err = pcall(fn, calls)
    ItemPicker = origItemPicker
    if not ok then error(err) end
end

local function calledWith(calls, obj)
    for _, o in ipairs(calls) do if o == obj then return true end end
    return false
end

-- ----------------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------------

local tests = {}

-- Bookcase -> cart: the bookcase (source) must get its overlay sprite
-- refreshed so its "has books" sprite updates.
tests["transfer_shelf_to_cart_refreshes_shelf_overlay"] = function()
    local shelfParent = makeFurnitureParent()
    local shelf = makeContainer({ parent = shelfParent, typeName = "shelves" })
    local book = makeItem({ id = 301 })
    shelf:AddItem(book)
    local cart = makeCartItem()
    local chr = makeCharacter()

    local result
    withOverlaySpy(function(calls)
        asSingleplayer(function()
            SaucedCarts.performCartTransfer(chr, book, shelf, cart:getItemContainer())
        end)
        result = calledWith(calls, shelfParent)
    end)

    return Assert.isTrue(result,
        "ItemPicker.updateOverlaySprite called for the source shelf object")
end

-- Cart -> bookcase: the bookcase (destination) must get its overlay sprite
-- refreshed.
tests["transfer_cart_to_shelf_refreshes_shelf_overlay"] = function()
    local shelfParent = makeFurnitureParent()
    local shelf = makeContainer({ parent = shelfParent, typeName = "shelves" })
    local cart = makeCartItem()
    local book = makeItem({ id = 302 })
    cart:getItemContainer():AddItem(book)
    local chr = makeCharacter()

    local result
    withOverlaySpy(function(calls)
        asSingleplayer(function()
            SaucedCarts.performCartTransfer(chr, book, cart:getItemContainer(), shelf)
        end)
        result = calledWith(calls, shelfParent)
    end)

    return Assert.isTrue(result,
        "ItemPicker.updateOverlaySprite called for the destination shelf object")
end

-- The move itself must still succeed (fix must not regress the transfer).
tests["overlay_refresh_does_not_break_the_move"] = function()
    local shelf = makeContainer({ parent = makeFurnitureParent(), typeName = "shelves" })
    local book = makeItem({ id = 303 })
    shelf:AddItem(book)
    local cart = makeCartItem()
    local chr = makeCharacter()

    local ok
    withOverlaySpy(function()
        asSingleplayer(function()
            ok = SaucedCarts.performCartTransfer(chr, book, shelf, cart:getItemContainer())
        end)
    end)

    if not Assert.isTrue(ok, "transfer returned success") then return false end
    if not Assert.isFalse(shelf:contains(book), "book left the shelf") then return false end
    return Assert.isTrue(cart:getItemContainer():contains(book), "book now in cart")
end

return tests
