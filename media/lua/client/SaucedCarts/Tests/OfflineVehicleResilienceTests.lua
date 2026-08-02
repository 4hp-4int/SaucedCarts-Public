--[[
    SaucedCarts — Vehicle transfer resilience (v2.1.14)
    ===================================================

    Locks the fixes for the "cart works with the trunk but not the trailer
    until the server restarts" report family.

    ROOT CAUSE (proven live on a 42.20 dedi, 2026-08-02): runtime-spawned
    vehicles (admin /addvehicle — AddVehicleCommand constructs BaseVehicle
    directly and never calls VehicleManager.registerVehicle; healed only by
    a server restart via the DB load path) are INVISIBLE to getVehicleById.
    SC's resolveSide vehicle branch then fell back to playerInv, and the
    pre-delegation contains-guard turned every transfer into a silent no-op
    (bail logs were .debug — suppressed on dedis).

    Fixes under test:
      F1  resolveSide vehicle: square-sweep recovery channel (client now
          sends the vehicle's square; sq:getVehicleContainer walks chunk
          vehicle lists, which even unregistered spawns populate)
      F2  client-routed item lookup FIRST (resolved source container's
          getItemById before proximity sweeps)
      F3  unresolved vehicle DESTINATION refuses loudly — never substitutes
          playerInv (the old silent misdelivery into main inventory)
      F4  vanilla capacity parity: vehicle-parented destinations are exempt
          from the server-side hasRoomFor hard-refusal, exactly like
          vanilla's TransactionManager.isConsistent:264 exemption (KI5
          item-backed capacities: script 75, damnCraft.Trunk item 25,
          uninstalled racks 0)
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartTransferInterceptor"

-- ============================================================================
-- FIXTURES (deposit-tests pattern + vehicle surface)
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
    c.hasRoomFor = function(self, chr, w) return opts.hasRoom ~= false end
    c.setDrawDirty = function(self) end
    c.setExplored = function(self) end
    c.setHasBeenLooted = function(self) end
    c.isExistYet = function(self) return true end
    c.getItemById = function(self, id)
        for _, it in ipairs(self._items) do
            if it.getID and it:getID() == id then return it end
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
    item.getWorldItem = function(self) return nil end
    item.getContainer = function(self) return self._container end
    item.setJobDelta = function(self) end
    item.isFavorite = function(self) return false end
    return item
end

local function makeCartItem(opts)
    opts = opts or {}
    local item = {
        _id = opts.id or 42, _type = "InventoryContainer",
        _fullType = "SaucedCarts.ShoppingCart",
    }
    item.getID = function(self) return self._id end
    item.getFullType = function(self) return self._fullType end
    item._innerContainer = makeContainer({ containingItem = item, hasRoom = opts.hasRoom })
    item.getItemContainer = function(self) return self._innerContainer end
    item.getContainer = function(self) return self._outerContainer end
    return item
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
    ch.getVehicle = function(self) return nil end
    ch.getX = function(self) return 10.0 end
    ch.getY = function(self) return 10.0 end
    ch.getZ = function(self) return 0.0 end
    ch.isSeatedInVehicle = function(self) return false end
    ch._square = opts.square
    ch.getCurrentSquare = function(self) return self._square end
    return ch
end

--- Fixture vehicle with one container part at index 0.
local function makeVehicle(opts)
    opts = opts or {}
    local v = { _type = "BaseVehicle", _id = opts.id or 500 }
    v._container = makeContainer({ typeName = opts.typeName or "TrailerTrunk", parent = v })
    local part = {
        getItemContainer = function() return v._container end,
        getIndex = function() return 0 end,
        setContainerContentAmount = function() end,
    }
    -- vanilla transferItem's vehicle bookkeeping: getPartById(containerType)
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
    sq._vehicle = opts.vehicle
    return sq
end

-- Additive table-fixture cart recognition (deposit-tests pattern)
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

--- Run body with getVehicleById + getCell stubbed; always restores.
local function withVehicleWorld(byId, square, body)
    return PZTestKit.withPatch(_G, "getVehicleById", byId, function()
        local cell = {
            getGridSquare = function(self, x, y, z)
                if square and x == square._x and y == square._y then return square end
                return nil
            end,
        }
        return PZTestKit.withPatch(_G, "getCell", function() return cell end, body)
    end)
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

tests["handler_reachable"] = function()
    return Assert.notNil(handler, "cartTransfer server handler registered")
end

-- F1+F2: id map dead, vehicle recovered via the square sweep; item found
-- through the client-routed resolved container.
tests["vehicle_src_recovers_via_square_sweep_when_id_map_dead"] = function()
    local veh = makeVehicle({ id = 501 })
    local sq = makeSquare({ x = 12, y = 10, vehicle = veh })
    local player = makeCharacter({ square = makeSquare({ x = 10, y = 10 }) })
    local cart = makeCartItem({ id = 42 })
    player:getInventory():AddItem(cart)
    local nails = makeItem({ id = 900 })
    veh._container:AddItem(nails)

    withVehicleWorld(function() return nil end, sq, function()
        handler(player, {
            itemId = 900, cartId = 42, direction = "in",
            srcKind = "vehicle", srcCartId = 501, srcObjIdx = 0,
            srcSqX = 12, srcSqY = 10, srcSqZ = 0,
            srcContType = "TrailerTrunk", destKind = "cart",
        })
    end)

    Assert.isTrue(cart:getItemContainer():contains(nails), "item landed in the cart")
    return Assert.isFalse(veh._container:contains(nails), "item left the vehicle")
end

-- F2 alone: id map WORKS — item must be found via the resolved container
-- even though no proximity channel could find it (regression for long rigs
-- beyond the sweep radius).
tests["item_found_via_client_routed_container"] = function()
    local veh = makeVehicle({ id = 502 })
    local player = makeCharacter({ square = makeSquare({ x = 10, y = 10 }) })
    local cart = makeCartItem({ id = 43 })
    player:getInventory():AddItem(cart)
    local nails = makeItem({ id = 901 })
    veh._container:AddItem(nails)

    withVehicleWorld(function(id) if id == 502 then return veh end return nil end, nil, function()
        handler(player, {
            itemId = 901, cartId = 43, direction = "in",
            srcKind = "vehicle", srcCartId = 502, srcObjIdx = 0,
            srcContType = "TrailerTrunk", destKind = "cart",
        })
    end)

    return Assert.isTrue(cart:getItemContainer():contains(nails),
        "item found via resolved src container (no proximity dependence)")
end

-- F3: unresolved vehicle DESTINATION refuses — item stays in the cart, and
-- is NOT misdelivered into the player's main inventory.
tests["unresolved_vehicle_dest_refuses_no_misdelivery"] = function()
    local player = makeCharacter({ square = makeSquare({ x = 10, y = 10 }) })
    local cart = makeCartItem({ id = 44 })
    player:getInventory():AddItem(cart)
    local plank = makeItem({ id = 902, fullType = "Base.Plank" })
    cart:getItemContainer():AddItem(plank)

    withVehicleWorld(function() return nil end, nil, function()
        handler(player, {
            itemId = 902, cartId = 44, direction = "out",
            destKind = "vehicle", destCartId = 999, destObjIdx = 0,
            destContType = "TrailerTrunk", srcKind = "cart",
        })
    end)

    Assert.isTrue(cart:getItemContainer():contains(plank), "item stayed in the cart")
    return Assert.isFalse(player:getInventory():contains(plank),
        "item NOT misdelivered to player inventory")
end

-- F4: vehicle-parented destination is exempt from the server-side
-- hasRoomFor hard-refusal (vanilla parity)...
tests["capacity_parity_vehicle_dest_moves_despite_no_room"] = function()
    local veh = makeVehicle({ id = 503 })
    veh._container.hasRoomFor = function() return false end   -- "full" (KI5 25/0-cap shape)
    local player = makeCharacter({ square = makeSquare({ x = 10, y = 10 }) })
    local cart = makeCartItem({ id = 45 })
    player:getInventory():AddItem(cart)
    local plank = makeItem({ id = 903, fullType = "Base.Plank" })
    cart:getItemContainer():AddItem(plank)

    local ok = SaucedCarts.performCartTransfer(player, plank,
        cart:getItemContainer(), veh._container)

    Assert.isTrue(ok, "transfer succeeded")
    return Assert.isTrue(veh._container:contains(plank), "item in the vehicle container")
end

-- ...while NON-vehicle destinations keep full strictness.
tests["capacity_still_enforced_for_non_vehicle_dest"] = function()
    local player = makeCharacter({ square = makeSquare({ x = 10, y = 10 }) })
    local cart = makeCartItem({ id = 46 })
    local bag = makeContainer({ typeName = "bag", hasRoom = false })
    local plank = makeItem({ id = 904, fullType = "Base.Plank" })
    cart:getItemContainer():AddItem(plank)

    local ok = SaucedCarts.performCartTransfer(player, plank,
        cart:getItemContainer(), bag)

    Assert.isFalse(ok, "transfer refused")
    return Assert.isFalse(bag:contains(plank), "item did not enter the bag")
end

return tests
