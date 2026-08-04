--[[
    SaucedCarts — bags nested inside vehicle / world containers
    ===========================================================

    REPORT (Workshop, 2026-08-04): "moving items from a container such as a
    bag, while the bag is inside of a trunk of a vehicle, directly into the
    shopping cart — the action does not complete, and when you take that
    container out of the trunk the items you tried moving have completely
    disappeared and are not in the shopping cart."

    The client classifies the bag's inner container as srcKind="bag" (it has
    a containingItem, so classifySide never reaches the vehicle branch). The
    server then has to locate that bag inside a VEHICLE PART container, move
    the item, and broadcast both sides of the move.

    Two layers are covered here:

      MOVE layer  — does the server put the item in the right place, and is
                    it conserved on every bail path? (tests 1-8)
      SYNC layer  — does the resulting broadcast actually reach a client?
                    (tests 11+) This is the layer that a recording-only
                    network stub cannot see; it needs
                    PZTestKit.Fixtures.containerSyncSpy, which reproduces
                    GameServer's three-branch dispatch including its silent
                    unaddressable-container hole.

    FIXTURE FIDELITY NOTE: the containers below deliberately mirror three
    Java behaviours that a naive mock gets wrong, and getting them wrong
    changes the verdict of these tests:
      * ItemContainer.getItemById RECURSES into nested InventoryContainers
        (ItemContainer.java:3397). A flat mock invents lookup failures that
        production does not have.
      * ItemContainer.getCharacter walks containingItem -> container ->
        getCharacter (ItemContainer.java:3314), so it is nil for anything
        nested under a vehicle or world object.
      * A bag/cart inner container has a nil `parent` (it is built with the
        no-arg `new ItemContainer()`), so GameServer's second broadcast
        branch is unavailable to it — the only routes are a character owner
        or a world item.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local Fixtures = PZTestKit.Fixtures

require "SaucedCarts/Core"
require "SaucedCarts/CartTransferInterceptor"

-- ============================================================================
-- FIXTURES
-- ============================================================================

local function makeContainer(opts)
    opts = opts or {}
    local c = {
        _items = {}, _parent = opts.parent, _type = "InventoryContainer",
        _containingItem = opts.containingItem,
        _typeName = opts.typeName or "bag",
    }
    c.getParent = function(self) return self._parent end
    -- Real ItemContainer.setParent is public (@UsedFromLua class), and the
    -- repair borrows it to make a nested container addressable for the
    -- duration of one send. Modelled so tests can catch a borrowed parent
    -- that is never given back.
    c.setParent = function(self, p) self._parent = p end
    c.getContainingItem = function(self) return self._containingItem end
    c.getType = function(self) return self._typeName end

    -- Mirrors ItemContainer.getCharacter (ItemContainer.java:3314): the
    -- parent when it is a character, otherwise walk up through the
    -- containing item's own container. Terminates at nil for anything
    -- nested under a vehicle part or a world object.
    c.getCharacter = function(self)
        local p = self:getParent()
        if p and (p._type == "IsoPlayer" or p._type == "IsoGameCharacter") then
            return p
        end
        local ci = self:getContainingItem()
        local outer = ci and ci.getContainer and ci:getContainer()
        if outer and outer.getCharacter then return outer:getCharacter() end
        return nil
    end

    c.contains = function(self, item)
        for _, it in ipairs(self._items) do if it == item then return true end end
        return false
    end
    -- Mirrors ItemContainer.containsID: DIRECT children only, no recursion.
    -- This is the check the client's add-packet handler uses to decide
    -- whether to skip an incoming item as a duplicate.
    c.containsID = function(self, id)
        for _, it in ipairs(self._items) do
            if it.getID and it:getID() == id then return true end
        end
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
    c.hasRoomFor = function(self, chr, w) return opts.hasRoom ~= false end
    c.setDrawDirty = function(self) end
    c.setExplored = function(self) end
    c.setHasBeenLooted = function(self) end
    c.isExistYet = function(self) return true end

    -- Mirrors ItemContainer.getItemById (ItemContainer.java:3397): RECURSIVE
    -- into nested InventoryContainer items. A flat lookup here would fake a
    -- "server can't find the item" failure that production never hits.
    c.getItemById = function(self, id)
        for _, it in ipairs(self._items) do
            if it.getID and it:getID() == id then return it end
            if it.getItemContainer then
                local inner = it:getItemContainer()
                if inner and inner.getItemById then
                    local nested = inner:getItemById(id)
                    if nested then return nested end
                end
            end
        end
        return nil
    end

    c.getCapacityWeight = function(self) return 0 end
    c.getItems = function(self)
        local list = { _items = self._items }
        list.size = function(s) return #s._items end
        list.get  = function(s, i) return s._items[i + 1] end
        return list
    end
    return c
end

local function makeItem(opts)
    opts = opts or {}
    local item = {
        _id = opts.id or 100, _type = "InventoryItem",
        _fullType = opts.fullType or "Base.Nails",
    }
    item.getID = function(self) return self._id end
    item.getFullType = function(self) return self._fullType end
    item.getType = function(self) return "Item" end
    item.getWorldItem = function(self) return self._worldItem end
    item.getContainer = function(self) return self._container end
    item.setJobDelta = function(self) end
    item.isFavorite = function(self) return false end
    return item
end

--- Give `item` an inner container, wired the way InventoryContainer does:
--- `containingItem` and `inventoryContainer` both point back at the item,
--- and `parent` stays nil (the no-arg `new ItemContainer()` shape).
local function attachInner(item, opts)
    item._type = "InventoryContainer"
    item._innerContainer = makeContainer({
        containingItem = item, hasRoom = opts.hasRoom,
    })
    item._innerContainer.inventoryContainer = item
    item.getItemContainer = function(self) return self._innerContainer end
    return item
end

local function makeBagItem(opts)
    opts = opts or {}
    local item = makeItem({ id = opts.id or 700, fullType = "Base.Bag_ALICEpack" })
    return attachInner(item, opts)
end

local function makeCartItem(opts)
    opts = opts or {}
    local item = makeItem({ id = opts.id or 42, fullType = "SaucedCarts.ShoppingCart" })
    return attachInner(item, opts)
end

local function makeCharacter(opts)
    opts = opts or {}
    local ch = { _type = "IsoPlayer" }
    ch._inv = makeContainer({ typeName = "none", parent = ch })
    ch._inv.getItemWithIDRecursiv = function(self, id) return self:getItemById(id) end
    ch.getInventory = function(self) return self._inv end
    ch.getUsername = function(self) return "tester" end
    ch.getOnlineID = function(self) return 1 end
    ch.isEquipped = function(self) return false end
    ch.removeAttachedItem = function(self) end
    ch.removeFromHands = function(self) end
    ch.removeWornItem = function(self) end
    ch.getPrimaryHandItem = function(self) return nil end
    ch.getVehicle = function(self) return opts.vehicle end
    ch.getX = function(self) return 10.0 end
    ch.getY = function(self) return 10.0 end
    ch.getZ = function(self) return 0.0 end
    ch.isSeatedInVehicle = function(self) return opts.vehicle ~= nil end
    ch._square = opts.square
    ch.getCurrentSquare = function(self) return self._square end
    return ch
end

local function makeVehicle(opts)
    opts = opts or {}
    local v = { _type = "BaseVehicle", _id = opts.id or 500 }
    v._container = makeContainer({ typeName = opts.typeName or "TruckBed", parent = v })
    local part = {
        getItemContainer = function() return v._container end,
        getIndex = function() return 0 end,
        setContainerContentAmount = function() end,
    }
    v.getPartById = function(self, id)
        if id == v._container:getType() then return part end
        return nil
    end
    v.getId = function(self) return self._id end
    v.getPartByIndex = function(self, i) if i == 0 then return part end return nil end
    v.getPartCount = function(self) return 1 end
    return v
end

local function makeSquare(opts)
    opts = opts or {}
    local sq = { _x = opts.x or 10, _y = opts.y or 10, _z = opts.z or 0 }
    sq.getX = function(self) return self._x end
    sq.getY = function(self) return self._y end
    sq.getZ = function(self) return self._z end
    sq.getVehicleContainer = function(self) return sq._vehicle end
    sq.getWorldObjects = function(self) return nil end
    sq.getObjects = function(self) return nil end
    sq.getDeadBodys = function(self) return nil end
    sq._vehicle = opts.vehicle
    return sq
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

local handler = SaucedCarts.Network._getServerHandler
    and SaucedCarts.Network._getServerHandler("cartTransfer")

--- Stub the world: getCell():getGridSquare returns `square` at its coords.
local function withWorld(square, body)
    local cell = {
        getGridSquare = function(self, x, y, z)
            if square and x == square._x and y == square._y and z == square._z then
                return square
            end
            return nil
        end,
    }
    return PZTestKit.withPatch(_G, "getVehicleById", function() return nil end, function()
        return PZTestKit.withPatch(_G, "getCell", function() return cell end, body)
    end)
end

--- Run `body` on the server side of the world with a faithful container
--- broadcast spy installed, then flush any coalesced resync WHILE THE SPY IS
--- STILL INSTALLED. Flushing after uninstall would send the repair packets
--- into the real globals and record nothing — a silent false negative.
--- Always uninstalls, even when body throws.
local function withSyncSpy(body)
    local spy = Fixtures.containerSyncSpy()
    spy:install()
    local ok, err = pcall(function()
        return PZTestKit.withPatch(_G, "isClient", function() return false end, function()
            return PZTestKit.withPatch(_G, "isServer", function() return true end, function()
                local r = body(spy)
                -- Idempotent: handler-driven paths have already flushed.
                -- Guarded so these tests fail on their ASSERTIONS rather than
                -- on a nil call when run against a build without the repair.
                if SaucedCarts.flushContainerResync then
                    SaucedCarts.flushContainerResync()
                end
                return r
            end)
        end)
    end)
    spy:uninstall()
    if not ok then error(err) end
    return spy
end

--- Build the reported world: bag sits in a vehicle part container; the item
--- sits inside the bag; the player stands beside the vehicle with a cart.
local function buildScene(opts)
    opts = opts or {}
    local veh = makeVehicle({ id = 600 })
    local vehSq = makeSquare({ x = 10, y = 10, vehicle = veh })
    local player = makeCharacter({ square = vehSq, vehicle = opts.seated and veh or nil })
    local cart = makeCartItem({ id = 42, hasRoom = opts.cartHasRoom })
    if opts.groundCart then
        -- A dropped cart: an IsoWorldInventoryObject on the tile wrapping the
        -- cart item. Its inner container has no parent and no character, so
        -- branch 3 (inventoryContainer -> world item) is its only route.
        cart._worldItem = {
            _type = "IsoWorldInventoryObject",
            getX = function() return 10 end,
            getY = function() return 10 end,
        }
        local worldObj = {
            _type = "IsoWorldInventoryObject",
            getItem = function() return cart end,
        }
        vehSq.getWorldObjects = function(self)
            local l = { _o = { worldObj } }
            l.size = function(s2) return #s2._o end
            l.get  = function(s2, i) return s2._o[i + 1] end
            return l
        end
    else
        player:getInventory():AddItem(cart)
    end

    local bag = makeBagItem({ id = 700 })
    veh._container:AddItem(bag)

    local nails = makeItem({ id = 900 })
    bag:getItemContainer():AddItem(nails)

    return {
        veh = veh, vehSq = vehSq, player = player,
        cart = cart, bag = bag, nails = nails,
    }
end

--- How many of the four reachable containers hold `item`. Conservation
--- means exactly 1 — 0 is the reported "vanished", 2+ is a dupe.
local function occupancy(s, item)
    local n = 0
    if s.bag:getItemContainer():contains(item) then n = n + 1 end
    if s.cart:getItemContainer():contains(item) then n = n + 1 end
    if s.player:getInventory():contains(item) then n = n + 1 end
    if s.veh._container:contains(item) then n = n + 1 end
    return n
end

local function transferIn(s, overrides)
    local args = {
        itemId = 900, cartId = 42, direction = "in",
        srcKind = "bag", srcCartId = 700,
        destKind = "cart", destCartId = 42,
    }
    for k, v in pairs(overrides or {}) do args[k] = v end
    return args
end

-- ============================================================================
-- MOVE LAYER
-- ============================================================================

local tests = {}

tests["handler_reachable"] = function()
    return Assert.notNil(handler, "cartTransfer server handler registered")
end

tests["bag_in_vehicle_container_to_cart_moves_item"] = function()
    local s = buildScene()
    withWorld(s.vehSq, function() handler(s.player, transferIn(s)) end)

    Assert.isFalse(s.bag:getItemContainer():contains(s.nails), "item left the bag")
    return Assert.isTrue(s.cart:getItemContainer():contains(s.nails),
        "item landed in the cart")
end

tests["bag_in_vehicle_item_is_never_lost"] = function()
    local s = buildScene()
    withWorld(s.vehSq, function() handler(s.player, transferIn(s)) end)

    return Assert.equal(occupancy(s, s.nails), 1,
        "item exists in exactly one container (no loss, no dupe)")
end

tests["bag_in_vehicle_to_cart_while_seated"] = function()
    local s = buildScene({ seated = true })
    withWorld(s.vehSq, function() handler(s.player, transferIn(s)) end)

    return Assert.isTrue(s.cart:getItemContainer():contains(s.nails),
        "item landed in the cart (seated case)")
end

tests["cart_to_bag_in_vehicle_moves_item"] = function()
    local s = buildScene()
    s.bag:getItemContainer():Remove(s.nails)
    s.cart:getItemContainer():AddItem(s.nails)

    withWorld(s.vehSq, function()
        handler(s.player, {
            itemId = 900, cartId = 42, direction = "out",
            srcKind = "cart", srcCartId = 42,
            destKind = "bag", destCartId = 700,
        })
    end)

    Assert.isTrue(s.bag:getItemContainer():contains(s.nails), "item landed in the bag")
    return Assert.isFalse(s.player:getInventory():contains(s.nails),
        "item NOT misdelivered into main inventory")
end

tests["full_cart_refusal_leaves_item_in_bag"] = function()
    local s = buildScene({ cartHasRoom = false })
    withWorld(s.vehSq, function() handler(s.player, transferIn(s)) end)

    Assert.equal(occupancy(s, s.nails), 1, "no loss on a refused transfer")
    return Assert.isTrue(s.bag:getItemContainer():contains(s.nails),
        "item stayed in the bag")
end

tests["batched_stack_from_bag_in_vehicle_conserves_all"] = function()
    local s = buildScene()
    local extra = {}
    for i = 1, 4 do
        local it = makeItem({ id = 910 + i })
        s.bag:getItemContainer():AddItem(it)
        extra[i] = it
    end

    withWorld(s.vehSq, function()
        handler(s.player, transferIn(s, { itemIds = { 900, 911, 912, 913, 914 } }))
    end)

    Assert.equal(occupancy(s, s.nails), 1, "head item conserved")
    for i = 1, 4 do
        Assert.equal(occupancy(s, extra[i]), 1, "batched item " .. i .. " conserved")
        Assert.isTrue(s.cart:getItemContainer():contains(extra[i]),
            "batched item " .. i .. " landed in the cart")
    end
    return Assert.isTrue(true, "batch conserved")
end

-- ============================================================================
-- F1 (v2.1.16): unresolved "bag" side hard-fails instead of becoming playerInv
-- ============================================================================

--- direction "out": cart -> a bag the server cannot locate. Pre-fix the bag
--- silently became the player's main inventory and the item was misdelivered
--- into their pockets. Post-fix the transfer is refused and the item stays.
tests["unresolved_bag_dest_refuses_no_misdelivery"] = function()
    local s = buildScene()
    s.bag:getItemContainer():Remove(s.nails)
    s.cart:getItemContainer():AddItem(s.nails)
    local emptySq = makeSquare({ x = 10, y = 10 })  -- vehicle unreachable

    withWorld(emptySq, function()
        handler(s.player, {
            itemId = 900, cartId = 42, direction = "out",
            srcKind = "cart", srcCartId = 42,
            destKind = "bag", destCartId = 700,
        })
    end)

    Assert.isFalse(s.player:getInventory():contains(s.nails),
        "item NOT misdelivered into main inventory")
    return Assert.isTrue(s.cart:getItemContainer():contains(s.nails),
        "item stayed in the cart")
end

--- direction "in" with an unresolvable bag still succeeds: the item lookup
--- finds it and its own container becomes the source of truth. Proves the
--- hard-fail did not cost us a working path.
tests["unresolved_bag_src_recovers_via_item_own_container"] = function()
    local s = buildScene()

    withWorld(s.vehSq, function()
        handler(s.player, transferIn(s, { srcCartId = 99999 }))  -- bogus bag id
    end)

    Assert.equal(occupancy(s, s.nails), 1, "no loss, no dupe")
    return Assert.isTrue(s.cart:getItemContainer():contains(s.nails),
        "item recovered into the cart via its own container")
end

-- ============================================================================
-- SYNC LAYER — GameServer broadcast addressability
-- ============================================================================
-- The report's "action does not complete / items disappeared" symptoms come
-- from a silent packet drop: the MOVE succeeds server-side but the client is
-- never told. v2.1.16 repairs it with an anchored resync for any container
-- vanilla's helpers cannot address.

--- CONTROL: the spy is not just always reporting "dropped". A bag carried by
--- the player is addressable via branch 1 (getCharacter -> IsoPlayer).
tests["sync_control_bag_in_player_inventory_is_addressable"] = function()
    local player = makeCharacter({ square = makeSquare({}) })
    local bag = makeBagItem({ id = 710 })
    player:getInventory():AddItem(bag)

    local spy = withSyncSpy(function() return nil end)
    return Assert.equal(spy:routeFor(bag:getItemContainer()), "character",
        "a carried bag routes via getCharacter")
end

--- CONTROL: a vehicle part container itself IS addressable (branch 2 —
--- its parent is the BaseVehicle). Only things NESTED inside it are not.
tests["sync_control_vehicle_part_container_is_addressable"] = function()
    local veh = makeVehicle({ id = 610 })
    local spy = withSyncSpy(function() return nil end)
    return Assert.equal(spy:routeFor(veh._container), "parent",
        "a vehicle part container routes via getParent")
end

--- THE REPORTED DEFECT, source side. The removal broadcast for a bag nested
--- in a vehicle part matches none of GameServer's three branches, so on its
--- own the client never learns the item left the bag — it keeps showing a
--- phantom copy until the bag is pulled out of the trunk and re-syncs, which
--- is exactly when the reporter saw the items "completely disappear".
--- v2.1.16 covers it with an anchored resync of the vehicle part container.
tests["sync_removal_from_bag_in_vehicle_is_repaired_by_resync"] = function()
    local s = buildScene()

    local spy = withSyncSpy(function()
        return withWorld(s.vehSq, function() handler(s.player, transferIn(s)) end)
    end)

    Assert.isTrue(s.cart:getItemContainer():contains(s.nails),
        "server-side move succeeded")
    -- Two remove calls: vanilla's, which is dropped, and our repair, which
    -- is addressed at the bag's own container and does land.
    local removes = spy:callsFor("remove")
    Assert.equal(#removes, 2, "vanilla's dropped remove plus our repair")
    Assert.isFalse(removes[1].delivered,
        "vanilla's own remove was unaddressable — that's the defect")
    Assert.isTrue(removes[2].delivered, "the repaired remove reaches clients")
    Assert.equal(removes[2].container, s.bag:getItemContainer(),
        "addressed at the BAG's own container — no rebinding")
    return Assert.equal(#spy:callsFor("replace"), 0,
        "the coarse replace fallback is not used for vehicles")
end

--- Coalescing: a batched stack out of one bag must produce ONE resync for
--- the command, not one per item. Without this the repair would turn a
--- 50-nail transfer into 50 full-container broadcasts.
tests["sync_resync_is_coalesced_across_a_batch"] = function()
    local s = buildScene()
    for i = 1, 4 do
        s.bag:getItemContainer():AddItem(makeItem({ id = 910 + i }))
    end

    local spy = withSyncSpy(function()
        return withWorld(s.vehSq, function()
            handler(s.player, transferIn(s, { itemIds = { 900, 911, 912, 913, 914 } }))
        end)
    end)

    -- The precise channel is per-item by nature, exactly like vanilla's own
    -- traffic; it is the coarse whole-container fallback that must never
    -- fire once per item.
    Assert.greaterEq(#spy:callsFor("add"), 5, "all five items were moved")
    Assert.equal(#spy:callsFor("replace"), 0,
        "no coarse refresh for a vehicle-nested batch")
    -- The borrowed parent must never be left behind: a container that still
    -- looks vehicle-owned would report itself addressable forever after.
    return Assert.isNil(s.bag:getItemContainer():getParent(),
        "borrowed parent was given back")
end

--- NON-REGRESSION: an addressable transfer must NOT trigger a resync. Bag in
--- the player's inventory -> equipped cart is the common case and stays
--- entirely on the vanilla path.
tests["sync_addressable_transfer_sends_no_resync"] = function()
    local player = makeCharacter({ square = makeSquare({}) })
    local cart = makeCartItem({ id = 44 })
    player:getInventory():AddItem(cart)
    local bag = makeBagItem({ id = 720 })
    player:getInventory():AddItem(bag)
    local nails = makeItem({ id = 930 })
    bag:getItemContainer():AddItem(nails)

    local spy = withSyncSpy(function()
        return SaucedCarts.performCartTransfer(player, nails,
            bag:getItemContainer(), cart:getItemContainer())
    end)

    Assert.isTrue(cart:getItemContainer():contains(nails), "item moved")
    Assert.isTrue(spy:deliveredFor("add", nails), "vanilla add packet reached a client")
    return Assert.equal(#spy:callsFor("replace"), 0,
        "no repair needed for a fully addressable transfer")
end

--- REVERSE DIRECTION (user report, 2026-08-04): cart -> bag-in-trunk. The
--- ADD is the unaddressable side here, so the client sees the item leave the
--- cart and never arrive — it just vanishes. Same repair, dest side.
tests["sync_add_into_bag_in_vehicle_is_repaired_by_resync"] = function()
    local s = buildScene()
    s.bag:getItemContainer():Remove(s.nails)
    s.cart:getItemContainer():AddItem(s.nails)

    local spy = withSyncSpy(function()
        return withWorld(s.vehSq, function()
            handler(s.player, {
                itemId = 900, cartId = 42, direction = "out",
                srcKind = "cart", srcCartId = 42,
                destKind = "bag", destCartId = 700,
            })
        end)
    end)

    Assert.isTrue(s.bag:getItemContainer():contains(s.nails),
        "server-side move succeeded")
    local adds = spy:callsFor("add")
    Assert.equal(#adds, 2, "vanilla's dropped add plus our repair")
    Assert.isFalse(adds[1].delivered, "vanilla's add was unaddressable")
    Assert.isTrue(adds[2].delivered, "the repaired add reaches clients")
    return Assert.equal(adds[2].container, s.bag:getItemContainer(),
        "addressed at the BAG's own container — no rebinding")
end

--- The replace channel REBINDS the bag to a new object on the client, so an
--- open loot panel keeps pointing at the old, now-detached container: right
--- data, dead panel. The repair must therefore also nudge the initiator's
--- panels into re-resolving via vanilla's Commands.ui.DirtyUI.
tests["sync_repair_also_dirties_the_initiators_inventory_ui"] = function()
    -- Shelf, not vehicle: only the FALLBACK channel rebinds, so only it
    -- needs the UI nudge.
    local shelfObj = { _type = "IsoObject" }
    local shelf = makeContainer({ typeName = "shelves", parent = shelfObj })
    local bag = makeBagItem({ id = 750 })
    shelf:AddItem(bag)
    local nails = makeItem({ id = 960 })
    bag:getItemContainer():AddItem(nails)
    local s = { player = makeCharacter({ square = makeSquare({}) }) }
    local cart = makeCartItem({ id = 47 })
    s.player:getInventory():AddItem(cart)

    local spy = withSyncSpy(function()
        return SaucedCarts.performCartTransfer(s.player, nails,
            bag:getItemContainer(), cart:getItemContainer())
    end)

    Assert.equal(#spy:callsFor("replace"), 1, "a refresh was sent")
    local cmds = spy:callsFor("servercommand")
    Assert.equal(#cmds, 1, "exactly one UI nudge")
    Assert.equal(cmds[1].module, "ui", "vanilla ui module")
    Assert.equal(cmds[1].command, "DirtyUI", "vanilla DirtyUI command")
    return Assert.equal(cmds[1].player, s.player,
        "targeted at the initiator, not broadcast")
end

--- ...and an addressable transfer must not spam DirtyUI at all.
tests["sync_addressable_transfer_sends_no_ui_nudge"] = function()
    local player = makeCharacter({ square = makeSquare({}) })
    local cart = makeCartItem({ id = 46 })
    player:getInventory():AddItem(cart)
    local bag = makeBagItem({ id = 740 })
    player:getInventory():AddItem(bag)
    local nails = makeItem({ id = 950 })
    bag:getItemContainer():AddItem(nails)

    local spy = withSyncSpy(function()
        return SaucedCarts.performCartTransfer(player, nails,
            bag:getItemContainer(), cart:getItemContainer())
    end)

    Assert.isTrue(cart:getItemContainer():contains(nails), "item moved")
    return Assert.equal(#spy:callsFor("servercommand"), 0,
        "no UI nudge when vanilla already syncs the move")
end

--- Regression guard for the channel choice itself. sendItemsInContainer
--- CANNOT fix the nested case: the client skips any item whose id the
--- destination already holds, so resyncing the trunk (which still holds the
--- bag) applies nothing and logs "Error: Dupe item ID". If someone swaps the
--- repair back to that channel, this fails.
tests["sync_resync_channel_would_be_a_noop_for_the_nested_case"] = function()
    local s = buildScene()
    local spy = Fixtures.containerSyncSpy()
    spy:install()
    -- The trunk already contains the bag, exactly as a client's copy would.
    sendItemsInContainer(s.veh, s.veh._container)
    local call = spy:callsFor("resync")[1]
    spy:uninstall()

    Assert.notNil(call, "resync was recorded")
    Assert.equal(call.applied, 0, "client would apply NOTHING (all ids known)")
    return Assert.greaterEq(call.skipped, 1,
        "the bag entry is skipped as a duplicate id")
end

--- A bag on a shelf is the same nesting shape as a bag in a trunk, and gets
--- the same repair — refreshing the bag inside the addressable shelf.
tests["sync_removal_from_bag_on_shelf_is_repaired_by_resync"] = function()
    local shelfObj = { _type = "IsoObject" }
    local shelf = makeContainer({ typeName = "shelves", parent = shelfObj })
    local bag = makeBagItem({ id = 730 })
    shelf:AddItem(bag)
    local nails = makeItem({ id = 940 })
    bag:getItemContainer():AddItem(nails)

    local player = makeCharacter({ square = makeSquare({}) })
    local cart = makeCartItem({ id = 45 })
    player:getInventory():AddItem(cart)

    local spy = withSyncSpy(function()
        return SaucedCarts.performCartTransfer(player, nails,
            bag:getItemContainer(), cart:getItemContainer())
    end)

    local reps = spy:callsFor("replace")
    Assert.equal(#reps, 1, "one replace refresh (no nested id exists for shelves)")
    Assert.equal(reps[1].container, shelf, "refresh targets the shelf container")
    return Assert.equal(reps[1].item, bag, "the refreshed item is the bag")
end

--- CONTROL, destination side: a cart lying on the ground IS addressable via
--- branch 3 — its containing item has a world item. This is the boundary
--- that makes the nested case above a real distinction rather than "our
--- broadcasts never work". `inventoryContainer` survives save/load (it is
--- assigned in the constructor on a field-initialised ItemContainer, and
--- load() reuses that object), so what separates the two cases is purely
--- whether the containing item is on the ground.
tests["sync_add_to_ground_cart_is_addressable"] = function()
    local s = buildScene({ groundCart = true })

    local spy = withSyncSpy(function()
        return withWorld(s.vehSq, function() handler(s.player, transferIn(s)) end)
    end)

    Assert.isTrue(s.cart:getItemContainer():contains(s.nails),
        "server-side move succeeded")
    return Assert.isTrue(spy:deliveredFor("add", s.nails),
        "add packet routes via the cart's world item")
end

return tests
