--[[
    SaucedCarts — ISCartEquipAction:findCart resolution matrix
    ==========================================================

    WHY THIS FILE EXISTS. Player report (hosted MP): "I try to push it and it
    just goes into my inventory. My friend can use it with the same mod list."

    ISCartEquipAction defines complete(), so it REPLICATES: the client's
    complete() is local prediction and the SERVER runs its own copy, which is
    authoritative. The server's copy begins:

        local cart = self:findCart()
        if not cart then
            SaucedCarts.error("Equip failed: cart not found (ID: ...)")
            return false          -- server NEVER equips
        end

    If that lookup misses, the client has already predicted the equip locally,
    the server never performs it, and the next sync puts the cart back where
    the server thinks it lives — the inventory. That is the reported symptom
    exactly, and it is MP-only because singleplayer has no second VM to
    disagree with.

    So the question is not "does equipping work" but "for which cart locations
    can the server RE-FIND the cart from the serialized action fields". The
    action only carries: cartId, sourceType, vehicleX/Y/Z. Everything else —
    which container, which square — has to be rediscovered.

    This matrix drives findCart across every location a cart can legitimately
    be in when a player asks to push it. It began life deliberately RED — each
    failing row was a real "cart goes into my inventory" for some player — and
    drove the resolution ladder that findCart now implements:

        1. player inventory, recursive (bags)
        2. carried vehicle coords, 5x5 window
        3. last resort, any sourceType: the squares around the CHARACTER
           (world containers, nil vehicle coords, drift past the window)

    A red row here is a regression back to the report.

    The engine-mode sibling (EngineCartTests) re-proves the container rows on
    REAL Java containers; this file keeps the world/vehicle rows, which need a
    mock cell either way.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/TimedActions/ISCartEquipAction"

local CART_ID = 4242

-- ----------------------------------------------------------------------------
-- Mocks: only what findCart touches
-- ----------------------------------------------------------------------------

local function makeContainer(parent)
    local c = { _items = {}, _parent = parent }
    c.getItems  = function(self)
        local list = self._items
        return { size = function() return #list end,
                 get = function(_, i) return list[i + 1] end }
    end
    c.containsID = function(self, id)
        for _, it in ipairs(self._items) do
            if it:getID() == id then return true end
        end
        return false
    end
    c.AddItem   = function(self, it) table.insert(self._items, it); return it end
    c.getParent = function(self) return self._parent end
    return c
end

local function makeCart(id)
    local cart = { _type = "InventoryContainer", _id = id or CART_ID }
    cart.getID       = function(self) return self._id end
    cart.getFullType = function(self) return "SaucedCarts.ShoppingCart" end
    return cart
end

--- Character with an inventory and (optionally) a position — the position is
--- what findCart's last-resort square scan anchors on.
local function makeCharacter(inv, x, y, z)
    return {
        getInventory = function() return inv end,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
    }
end

--- A world container object (crate, shelf, locker) holding `contents`.
local function makeCrate(contents)
    local container = makeContainer(nil)
    for _, it in ipairs(contents) do container:AddItem(it) end
    return { getContainer = function() return container end }
end

--- Install a cell of squares. `squaresAt` maps "x,y,z" to
--- { vehicle = vehicleMock|nil, objects = { crateMock, ... }|nil }.
local function withCell(squaresAt, fn)
    local orig = _G.getCell
    _G.getCell = function()
        return {
            getGridSquare = function(_, x, y, z)
                if x == nil or y == nil or z == nil then return nil end
                local entry = squaresAt[x .. "," .. y .. "," .. z] or {}
                local objects = entry.objects or {}
                return {
                    getVehicleContainer = function() return entry.vehicle end,
                    getObjects = function()
                        return { size = function() return #objects end,
                                 get = function(_, i) return objects[i + 1] end }
                    end,
                }
            end,
        }
    end
    local ok, err = pcall(fn)
    _G.getCell = orig
    if not ok then error(err) end
end

local function withInstanceof(fn)
    local orig = _G.instanceof
    _G.instanceof = function(obj, cls)
        if obj == nil then return false end
        if type(obj) == "table" and obj._type == cls then return true end
        if orig then return orig(obj, cls) end
        return false
    end
    local ok, err = pcall(fn)
    _G.instanceof = orig
    if not ok then error(err) end
end

--- A vehicle whose part containers hold `contents`. Mirrors the surface
--- searchVehicleForCart actually walks: getScript() -> getPartCount/getPart,
--- then vehicle:getPartById(id):getItemContainer().
local function makeVehicle(contents)
    local partContainer = makeContainer(nil)
    for _, it in ipairs(contents) do partContainer:AddItem(it) end
    return {
        _type = "BaseVehicle",
        getScript = function()
            return {
                getPartCount = function() return 1 end,
                getPart = function() return { getId = function() return "TruckBed" end } end,
            }
        end,
        getPartById = function(_, id)
            return { getItemContainer = function() return partContainer end }
        end,
    }
end

--- Build only the fields findCart reads, rather than going through :new().
--- The constructor computes a duration and needs character surface this
--- resolver never touches; isolating it keeps the matrix about resolution.
local function newAction(character, sourceType, vx, vy, vz)
    return setmetatable({
        character  = character,
        cartId     = CART_ID,
        sourceType = sourceType,
        vehicleX   = vx, vehicleY = vy, vehicleZ = vz,
    }, { __index = ISCartEquipAction })
end

local tests = {}

-- ============================================================================
-- The matrix
-- ============================================================================

tests["resolves_a_cart_held_directly_in_the_player_inventory"] = function()
    -- Baseline. sourceType "inventory", cart at the top level. This is the
    -- common case and it must never regress.
    local inv  = makeContainer(nil)
    local cart = makeCart()
    inv:AddItem(cart)
    local found
    withInstanceof(function()
        withCell({}, function()
            found = newAction(makeCharacter(inv), "inventory"):findCart()
        end)
    end)
    return Assert.equal(found, cart, "top-level inventory cart resolves")
end

tests["resolves_a_cart_in_a_vehicle_when_coords_are_carried"] = function()
    -- The designed vehicle path: sourceType "vehicle" plus the vehicle's
    -- square, rediscovered via the windowed getVehicleContainer scan.
    local inv  = makeContainer(nil)
    local cart = makeCart()
    local found
    withInstanceof(function()
        withCell({ ["10,20,0"] = { vehicle = makeVehicle({ cart }) } }, function()
            found = newAction(makeCharacter(inv), "vehicle", 10, 20, 0):findCart()
        end)
    end)
    return Assert.equal(found, cart, "vehicle cart resolves from carried coords")
end

tests["resolves_a_vehicle_cart_when_the_vehicle_shifts_one_tile"] = function()
    -- Vehicles occupy several tiles and the coords are captured client-side at
    -- menu-click time. The window exists to absorb exactly this.
    local inv  = makeContainer(nil)
    local cart = makeCart()
    local found
    withInstanceof(function()
        withCell({ ["11,20,0"] = { vehicle = makeVehicle({ cart }) } }, function()
            found = newAction(makeCharacter(inv), "vehicle", 10, 20, 0):findCart()
        end)
    end)
    return Assert.equal(found, cart, "one-tile drift is absorbed by the scan window")
end

tests["resolves_a_vehicle_cart_when_the_vehicle_shifts_two_tiles"] = function()
    -- A driven vehicle, or simply a long one whose reference square is not the
    -- square the trunk sits on. The old 3x3 window missed this; the 5x5 one
    -- covers it. If this fails, "cart goes into my inventory" is reproducible
    -- any time the vehicle is not where the client said it was.
    local inv  = makeContainer(nil)
    local cart = makeCart()
    local found
    withInstanceof(function()
        withCell({ ["12,20,0"] = { vehicle = makeVehicle({ cart }) } }, function()
            found = newAction(makeCharacter(inv), "vehicle", 10, 20, 0):findCart()
        end)
    end)
    return Assert.equal(found, cart, "two-tile drift still resolves")
end

tests["resolves_a_vehicle_cart_when_coords_were_not_captured"] = function()
    -- FromCart reads parent:getSquare() on the CLIENT. A vehicle whose square
    -- is momentarily nil yields sourceType "vehicle" with nil coords. The
    -- coord-driven branch can't run; the last-resort scan around the
    -- CHARACTER — who is standing at the vehicle, having just clicked its
    -- cart — is what resolves it.
    local inv  = makeContainer(nil)
    local cart = makeCart()
    local found
    withInstanceof(function()
        withCell({ ["10,20,0"] = { vehicle = makeVehicle({ cart }) } }, function()
            found = newAction(makeCharacter(inv, 10, 20, 0), "vehicle", nil, nil, nil):findCart()
        end)
    end)
    return Assert.equal(found, cart, "missing coords still resolve the cart")
end

tests["resolves_a_cart_inside_a_bag_in_the_player_inventory"] = function()
    -- findCart's inventory walk must be recursive: vanilla "put in container"
    -- has no cart-specific gate, so a cart CAN reach the inside of a bag, and
    -- the server must match the client's reachability or the equip desyncs.
    local inv  = makeContainer(nil)
    local bagContainer = makeContainer(nil)
    local bag  = { _type = "InventoryContainer", getID = function() return 999 end,
                   getItemContainer = function() return bagContainer end,
                   getInventory = function() return bagContainer end }
    local cart = makeCart()
    bagContainer:AddItem(cart)
    inv:AddItem(bag)
    local found
    withInstanceof(function()
        withCell({}, function()
            found = newAction(makeCharacter(inv), "inventory"):findCart()
        end)
    end)
    return Assert.equal(found, cart, "a nested cart resolves")
end

tests["resolves_a_cart_sitting_in_a_world_container"] = function()
    -- FromCart only ever emits "vehicle" or "inventory": any container whose
    -- parent is not a BaseVehicle falls through to "inventory". A cart in a
    -- crate, shelf or locker therefore arrives at the server labelled
    -- "inventory" while not being in the inventory at all. The last-resort
    -- scan around the character is what finds it.
    local inv  = makeContainer(nil)
    local cart = makeCart()
    local found
    withInstanceof(function()
        withCell({ ["10,20,0"] = { objects = { makeCrate({ cart }) } } }, function()
            found = newAction(makeCharacter(inv, 10, 20, 0), "inventory"):findCart()
        end)
    end)
    return Assert.equal(found, cart, "a cart in a world container resolves")
end

tests["resolution_never_returns_a_different_item"] = function()
    -- The ladder may widen the search but must stay ID-exact: a DIFFERENT
    -- cart within reach must not satisfy the lookup.
    local inv  = makeContainer(nil)
    local otherCart = makeCart(1111)
    local found
    withInstanceof(function()
        withCell({ ["10,20,0"] = { objects = { makeCrate({ otherCart }) } } }, function()
            found = newAction(makeCharacter(inv, 10, 20, 0), "inventory"):findCart()
        end)
    end)
    return Assert.isNil(found, "a nearby cart with the wrong ID does not resolve")
end

return tests
