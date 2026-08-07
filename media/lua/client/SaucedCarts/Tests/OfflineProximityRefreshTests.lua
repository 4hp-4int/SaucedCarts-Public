--[[
    SaucedCarts — Aggregated-panel refresh regression tests
    =======================================================

    Locks the fix for the Better Containers "proximity window" report
    (SP, 42.20.2): moving an item from the proximity panel into a cart left
    the item still listed in the panel. Clicking the phantom did nothing
    (the item really had moved), and switching the viewed container cleared
    it. Moving a real container's item into a cart behaved normally.

    ROOT CAUSE BEING LOCKED. A pane only re-reads its container when that
    container is drawDirty (ISInventoryPane.lua:2201). performCartTransfer
    dirties the REAL src and dest, which is enough for vanilla panels
    because the container on screen IS the one we moved out of.

    It is not enough for an AGGREGATED panel. Better Containers' proximity
    view is a synthetic ItemContainer.new("proximityInv", nil, nil) holding
    REFERENCES to items owned by the real nearby containers, refilled by
    clear() + addAll() only inside refreshBackpacks (Proximity.lua:248-273).
    Vanilla always hands a transfer item:getContainer() — the real shelf —
    so nothing ever dirties the snapshot the user is looking at, and the
    moved item stays listed. Vanilla's own floor container and Proximity
    Inventory are the same shape.

    THE FIX. SaucedCarts.requestInventoryRefresh drives
    ISInventoryPage.dirtyUI() -> refreshBackpacks(), which is exactly that
    rebuild: locally in SP, and via Commands.ui.DirtyUI targeted at the
    initiator on a dedi (ordered AFTER the add/remove broadcasts so the
    client refreshes against post-move truth).

    SENSITIVITY. 7 of the 8 tests here fail against pre-fix code: the five
    requestInventoryRefresh tests (the function is absent) and both
    handle_cart_transfer tests (no DirtyUI is ever sent for an ordinary
    transfer).

    The exception is flush_container_resync_does_not_itself_refresh, which
    passes either way and is a forward-looking guard, not a regression
    lock. Pre-fix the DirtyUI send did live inside flushContainerResync,
    but behind `if pendingResyncCount == 0 then return end` — which is
    precisely why an ordinary cart transfer got no refresh at all. Proving
    that by test would mean reaching markContainerForResync, which is file-
    local. What this test does lock is that ownership of the refresh stays
    at the call site, so a future edit can't reintroduce the double-send.
]]

if isServer() and not isClient() then return end

if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartTransferInterceptor"

-- ============================================================================
-- MOCKS (shapes mirror OfflineCartDepositTests)
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
    c._explored = false
    c._hasBeenLooted = false
    c.setExplored = function(self, v) self._explored = v end
    c.isExplored = function(self) return self._explored end
    c.setHasBeenLooted = function(self, v) self._hasBeenLooted = v end
    c.isHasBeenLooted = function(self) return self._hasBeenLooted end
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
        parent = opts.parent, containingItem = item, hasRoom = opts.hasRoom,
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
    ch.getCurrentSquare = function(self) return nil end
    -- Vanilla transferItem probes `destContainer:getParent():getPartById(...)`
    -- for the vehicle-part content-amount update. Our containers are parented
    -- to the character, and the kit's instanceof mock does not reliably
    -- exclude it, so answer nil and let the `and` chain short-circuit.
    ch.getPartById = function(self, partType) return nil end
    return ch
end

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
-- HELPERS
-- ============================================================================

--- Record every sendServerCommand(player, module, command, args).
local function commandSpy()
    return { calls = {}, record = function(self, p, m, c, a)
        table.insert(self.calls, { player = p, module = m, command = c, args = a })
    end }
end

local function dirtyUICalls(self) return self.calls end

--- Count only the ui/DirtyUI sends.
local function countDirtyUI(spy)
    local n = 0
    for _, call in ipairs(spy.calls) do
        if call.module == "ui" and call.command == "DirtyUI" then n = n + 1 end
    end
    return n
end

--- Run `body` server-side with sendServerCommand spied. Always restores,
--- even when body throws (a leaked patch poisons whichever test runs next —
--- Kahlua pairs order is arbitrary).
local function withServerCommandSpy(body)
    local spy = commandSpy()
    -- Vanilla transferItem calls sendRemoveItemFromContainer under isServer(),
    -- and performCartTransfer calls sendAddItemToContainer. Left nil, the test
    -- dies inside vanilla instead of on its own assertion. Stub them directly
    -- rather than depending on the kit fixture being in scope here.
    local BROADCASTS = {
        "sendAddItemToContainer", "sendRemoveItemFromContainer",
        "sendItemsInContainer", "sendReplaceItemInContainer",
    }
    local saved = {}
    for _, name in ipairs(BROADCASTS) do
        saved[name] = rawget(_G, name)
        _G[name] = function() end
    end
    local ok, err = pcall(function()
        PZTestKit.withPatch(_G, "isClient", function() return false end, function()
            return PZTestKit.withPatch(_G, "isServer", function() return true end, function()
                return PZTestKit.withPatch(_G, "sendServerCommand", function(p, m, c, a)
                    spy:record(p, m, c, a)
                end, function()
                    body(spy)
                end)
            end)
        end)
    end)
    for _, name in ipairs(BROADCASTS) do _G[name] = saved[name] end
    if not ok then error(err) end
    return spy
end

--- Run `body` in SP (isClient false, isServer false) with a stub
--- ISInventoryPage.dirtyUI counter.
local function withSPDirtyUI(body)
    local page = rawget(_G, "ISInventoryPage")
    local created = false
    if not page then
        page = {}
        _G.ISInventoryPage = page
        created = true
    end
    local origDirty = page.dirtyUI
    local count = 0
    page.dirtyUI = function() count = count + 1 end
    local ok, err = pcall(function()
        PZTestKit.withPatch(_G, "isClient", function() return false end, function()
            return PZTestKit.withPatch(_G, "isServer", function() return false end, body)
        end)
    end)
    page.dirtyUI = origDirty
    if created then _G.ISInventoryPage = nil end
    if not ok then error(err) end
    return count
end

local tests = {}

-- ============================================================================
-- requestInventoryRefresh — the seam itself
-- ============================================================================

tests["request_inventory_refresh_exists"] = function()
    return Assert.equal(type(SaucedCarts.requestInventoryRefresh), "function",
        "requestInventoryRefresh is the documented entry point for rebuilding "
        .. "aggregated panels after a cart move")
end

tests["request_inventory_refresh_targets_initiator_on_server"] = function()
    local player = makeCharacter()
    local spy = withServerCommandSpy(function()
        SaucedCarts.requestInventoryRefresh(player)
    end)

    Assert.equal(#spy.calls, 1, "exactly one server command")
    local call = spy.calls[1]
    Assert.equal(call.player, player, "targeted at the initiator, not broadcast")
    Assert.equal(call.module, "ui", "vanilla ui module")
    return Assert.equal(call.command, "DirtyUI",
        "Commands.ui.DirtyUI runs ISInventoryPage.dirtyUI -> refreshBackpacks "
        .. "on the client, which is what rebuilds the proximity snapshot")
end

tests["request_inventory_refresh_calls_dirty_ui_locally_in_sp"] = function()
    local count = withSPDirtyUI(function()
        SaucedCarts.requestInventoryRefresh(makeCharacter())
    end)
    return Assert.equal(count, 1,
        "SP has no network round trip: the panel rebuild happens in-process")
end

tests["request_inventory_refresh_server_without_player_is_a_noop"] = function()
    local spy = withServerCommandSpy(function()
        SaucedCarts.requestInventoryRefresh(nil)
    end)
    return Assert.equal(#spy.calls, 0,
        "no initiator means nobody to refresh — must not broadcast to everyone")
end

tests["request_inventory_refresh_survives_missing_inventory_page"] = function()
    -- Dedicated-server Lua has no ISInventoryPage at all; the SP branch must
    -- not throw if it is ever reached in a headless context.
    local page = rawget(_G, "ISInventoryPage")
    _G.ISInventoryPage = nil
    local ok = pcall(function()
        PZTestKit.withPatch(_G, "isClient", function() return false end, function()
            return PZTestKit.withPatch(_G, "isServer", function() return false end, function()
                SaucedCarts.requestInventoryRefresh(makeCharacter())
            end)
        end)
    end)
    _G.ISInventoryPage = page
    return Assert.isTrue(ok, "must degrade quietly, not throw")
end

-- ============================================================================
-- No double-refresh: the send moved OUT of flushContainerResync
-- ============================================================================

tests["flush_container_resync_does_not_itself_refresh"] = function()
    -- Forward-looking guard, not a regression lock (see the SENSITIVITY note
    -- in the header: this passes pre-fix too, because the old send sat behind
    -- an empty-queue early return — which is exactly why ordinary transfers
    -- never got a refresh). Ownership of the refresh belongs at the call site
    -- so that a repair case gets one refresh, not two.
    local spy = withServerCommandSpy(function()
        SaucedCarts.flushContainerResync()
    end)
    return Assert.equal(countDirtyUI(spy), 0,
        "flushContainerResync no longer owns the panel refresh")
end

-- ============================================================================
-- End to end through the server handler
-- ============================================================================

local handler = SaucedCarts.CartTransferInterceptor
    and SaucedCarts.CartTransferInterceptor.handleCartTransfer

--- player inv -> cart, direction "in", both sides resolvable without any
--- world/square stubbing.
local function buildInvToCartScene(itemIds)
    local chr = makeCharacter()
    chr._inv = makeContainer({ parent = chr, typeName = "inventorymale" })
    local cart = makeCartItem({ id = 313, parent = chr })
    chr._inv:AddItem(cart)
    local items = {}
    for i, id in ipairs(itemIds) do
        local it = makeItem({ id = id })
        chr._inv:AddItem(it)
        items[i] = it
    end
    return chr, cart, items
end

tests["handle_cart_transfer_refreshes_initiator_panels"] = function()
    if type(handler) ~= "function" then
        return Assert.isTrue(false, "handleCartTransfer not exported")
    end
    local chr, cart, items = buildInvToCartScene({ 900 })

    local spy = withServerCommandSpy(function()
        handler(chr, {
            itemId = 900, cartId = 313, direction = "in",
            srcKind = "inv", destKind = "cart", destCartId = 313,
        })
    end)

    Assert.isTrue(cart:getItemContainer():contains(items[1]),
        "precondition: the move itself succeeded")
    return Assert.equal(countDirtyUI(spy), 1,
        "the initiator is told to rebuild its panels after the move")
end

tests["handle_cart_transfer_refreshes_once_per_batch_not_per_item"] = function()
    if type(handler) ~= "function" then
        return Assert.isTrue(false, "handleCartTransfer not exported")
    end
    local chr, cart, items = buildInvToCartScene({ 901, 902, 903, 904 })

    local spy = withServerCommandSpy(function()
        handler(chr, {
            itemId = 901, itemIds = { 901, 902, 903, 904 },
            cartId = 313, direction = "in",
            srcKind = "inv", destKind = "cart", destCartId = 313,
        })
    end)

    local moved = 0
    for _, it in ipairs(items) do
        if cart:getItemContainer():contains(it) then moved = moved + 1 end
    end
    Assert.equal(moved, 4, "precondition: the whole batch moved")
    return Assert.equal(countDirtyUI(spy), 1,
        "one refresh for the whole command — refreshBackpacks rebuilds every "
        .. "nearby container, so per-item refreshes would be N redundant "
        .. "full rebuilds on the client")
end

return tests
