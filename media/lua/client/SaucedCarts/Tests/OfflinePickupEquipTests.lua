--[[
    SaucedCarts/Tests/OfflinePickupEquipTests.lua
    ==============================================

    Coverage for ISCartPickupAction (ground pickup) and ISCartEquipAction
    (equip from inventory / vehicle).

    Scope:
      * Primitives-only constructor contract (MP serialization safety).
      * findWorldItem / findItem / findCart lookup by stored IDs+coords.
      * isValid edge cases: heavy-item guard, completed flag persistence,
        missing world item, unreachable square.
      * FromWorldItem / FromCart helpers extract the right serializable data.

    Duplication vector focus (V4): the MP-critical contract is that when
    these actions fire on both client and server endpoints, each side
    performs only the operations that belong to its role. For offline
    tests we enforce the static primitives-only contract; the MP dual-
    dispatch behavior is covered by DualVM sim tests (separate file).

    Out of scope:
      * complete() full integration — touches ~12 player methods
        (reportEvent/playSound/setVariable/faceThisObject/setMetabolicTarget/
         getEmitter/stopOrTriggerSound/refreshBackpacks) that'd require
        heavy mocking. The critical post-complete observable state
        (hand slots set, item in inventory) is tested through a minimal
        player mock that stubs those methods as no-ops.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"

-- ISCartPickupAction / ISCartEquipAction require these chain-parents.
-- Load them explicitly here; in-game they're loaded by the TimedActions
-- folder scan and our requires are just ensuring availability.
require "SaucedCarts/TimedActions/ISCartPickupAction"
require "SaucedCarts/TimedActions/ISCartEquipAction"

local TEST_CART_TYPE = "SaucedCarts.TestPickupCart"
if not SaucedCarts.isRegistered(TEST_CART_TYPE) then
    SaucedCarts.registerCart(TEST_CART_TYPE, {
        name = "TestPickupCart",
        capacity = 50,
        conditionMax = 100,
    })
end

-- =============================================================================
-- TEST HELPERS
-- =============================================================================

-- Stub the player-API surface the actions touch but that's out of scope here.
-- Rather than failing when e.g. :reportEvent is called, swallow silently so
-- tests can assert on the parts we DO care about.
local function stubPlayerSurface(p)
    p.reportEvent        = function(self, name) end
    p.playSound          = function(self, name) return name end
    p.getEmitter         = function(self)
        return { isPlaying = function(_, s) return false end }
    end
    p.stopOrTriggerSound = function(self, s) end
    p.setVariable        = function(self, k, v) end
    p.faceThisObject     = function(self, obj) end
    p.setMetabolicTarget = function(self, v) end
    return p
end

-- Build a registered cart with the ShoppingCart-style shape and add an
-- isForceDropHeavyItem method so hand-slot guards don't trip when a cart
-- lives in a hand slot.
local function makeCartItem(opts)
    opts = opts or {}
    local cart = F.item({
        id       = opts.id,
        fullType = opts.fullType or TEST_CART_TYPE,
        weight   = opts.weight or 2.0,
    })
    cart._type = "InventoryContainer"
    cart.isForceDropHeavyItem = function(self) return true end
    cart._innerContainer = F.container({
        containingItem = cart,
        typeName       = "ShoppingCart",
        capacity       = opts.capacity or 50,
    })
    cart.getItemContainer = function(self) return self._innerContainer end
    cart.getContainer = function(self) return self._container end   -- nil unless placed
    return cart
end

-- Non-cart items that might sit in a hand slot also need isForceDropHeavyItem
-- (boolean return) — default to false.
local function makeNormalItem(opts)
    opts = opts or {}
    local it = F.item(opts)
    it.isForceDropHeavyItem = function(self) return false end
    return it
end

-- Recognize mock carts as carts.
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item.getFullType and (item:getFullType() or ""):find("^SaucedCarts%.") then
        return true
    end
    return origSafeIsCart(item)
end

local tests = {}

-- =============================================================================
-- ISCartPickupAction :new — primitives-only constructor
-- =============================================================================
-- MP action sync serializes the action's fields across the wire. Java/Kahlua
-- refs (IsoGridSquare, IsoWorldInventoryObject, InventoryItem) don't survive
-- serialization — the server would recreate them as nil/stale. Constructor
-- MUST store only primitives (numbers, strings). Regression guard: if a
-- future edit stashes a cart reference in the action, these tests fail.

tests["pickup_constructor_stores_primitives_only"] = function()
    local p = stubPlayerSurface(F.player())
    local action = ISCartPickupAction:new(p, 10, 20, 0, 12345)

    if not Assert.equal(action.squareX, 10, "squareX stored as number") then return false end
    if not Assert.equal(action.squareY, 20, "squareY stored as number") then return false end
    if not Assert.equal(action.squareZ, 0, "squareZ stored as number") then return false end
    if not Assert.equal(action.itemId, 12345, "itemId stored as number") then return false end

    for k, v in pairs(action) do
        local t = type(v)
        if t ~= "number" and t ~= "string" and t ~= "boolean" and t ~= "nil"
            and k ~= "character" and k ~= "action" and k ~= "_class" then
            -- Verify unexpected refs aren't stored. `character` is a known
            -- exception — set by ISBaseTimedAction.new for action binding.
            -- `action` is the Java-side LuaTimedActionNew wrapper.
            return Assert.isTrue(false, "unexpected non-primitive field '" .. k .. "' of type " .. t)
        end
    end
    return true
end

tests["pickup_constructor_sets_completed_false"] = function()
    local p = stubPlayerSurface(F.player())
    local action = ISCartPickupAction:new(p, 0, 0, 0, 1)
    return Assert.isFalse(action.completed,
        "completed flag starts false — flips to true only after complete() runs")
end

tests["pickup_FromWorldItem_extracts_square_coords_and_item_id"] = function()
    -- FromWorldItem reads the live worldItem's square+item and synthesizes
    -- the primitives-only :new args. This is the UX entry point from
    -- context menus / hotkeys.
    local w = F.world()
    local sq = w:square(5, 7, 0)
    local cart = makeCartItem({ id = 42 })
    sq:AddWorldInventoryItem(cart, 0.5, 0.5, 0.0, false)

    local p = stubPlayerSurface(w:player({ square = sq }))
    local action = ISCartPickupAction.FromWorldItem(p, cart:getWorldItem())
    w:teardown()

    if not Assert.equal(action.squareX, 5, "squareX pulled from worldItem square") then return false end
    if not Assert.equal(action.squareY, 7, "squareY pulled from worldItem square") then return false end
    return Assert.equal(action.itemId, 42, "itemId pulled from worldItem:getItem()")
end

-- =============================================================================
-- ISCartPickupAction :findWorldItem / :findItem — stored-primitives lookup
-- =============================================================================

tests["pickup_findWorldItem_finds_by_stored_coords_and_id"] = function()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    local cart = makeCartItem({ id = 100 })
    sq:AddWorldInventoryItem(cart, 0.5, 0.5, 0.0, false)

    local p = stubPlayerSurface(w:player({ square = sq }))
    local action = ISCartPickupAction:new(p, 0, 0, 0, 100)
    local found = action:findWorldItem()
    w:teardown()

    return Assert.equal(found, cart:getWorldItem(),
        "findWorldItem returned the correct IsoWorldInventoryObject")
end

tests["pickup_findWorldItem_returns_nil_when_coords_have_no_square"] = function()
    local w = F.world()
    -- Don't register a square at the lookup coords.
    local p = stubPlayerSurface(w:player({ square = w:square(0, 0, 0) }))
    local action = ISCartPickupAction:new(p, 99, 99, 0, 1)
    local found = action:findWorldItem()
    w:teardown()

    return Assert.isNil(found, "no square at stored coords -> nil (not a crash)")
end

tests["pickup_findWorldItem_returns_nil_when_id_not_in_worldObjects"] = function()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    -- Put A on the square, search for B.
    sq:AddWorldInventoryItem(makeCartItem({ id = 1 }), 0.5, 0.5, 0.0, false)

    local p = stubPlayerSurface(w:player({ square = sq }))
    local action = ISCartPickupAction:new(p, 0, 0, 0, 999)   -- wrong id
    local found = action:findWorldItem()
    w:teardown()

    return Assert.isNil(found, "cart with matching id not present -> nil")
end

tests["pickup_findItem_returns_inner_InventoryItem"] = function()
    local w = F.world()
    local sq = w:square(0, 0, 0)
    local cart = makeCartItem({ id = 50 })
    sq:AddWorldInventoryItem(cart, 0.5, 0.5, 0.0, false)

    local p = stubPlayerSurface(w:player({ square = sq }))
    local action = ISCartPickupAction:new(p, 0, 0, 0, 50)
    local found = action:findItem()
    w:teardown()

    return Assert.equal(found, cart, "findItem unwraps worldItem -> InventoryItem")
end

-- =============================================================================
-- ISCartPickupAction :isValid — guards and flag semantics
-- =============================================================================

tests["pickup_isValid_false_when_world_item_missing"] = function()
    local w = F.world()
    local p = stubPlayerSurface(w:player({ square = w:square(0, 0, 0) }))
    local action = ISCartPickupAction:new(p, 99, 99, 0, 1)   -- no square there
    local v = action:isValid()
    w:teardown()
    return Assert.isFalse(v, "missing world item -> isValid false")
end

tests["pickup_isValid_true_once_completed_flag_set"] = function()
    -- Post-complete, findWorldItem returns nil because we removed the item.
    -- isValid must still return true (completed short-circuit) so the
    -- timed action queue doesn't flag the completed action as "bugged"
    -- and clear downstream actions.
    local p = stubPlayerSurface(F.player())
    local action = ISCartPickupAction:new(p, 0, 0, 0, 1)
    action.completed = true
    return Assert.isTrue(action:isValid(),
        "completed=true short-circuits isValid to true (queue stability)")
end

tests["pickup_isValid_false_when_primary_is_heavy_item"] = function()
    -- Guard against picking up a second cart while already holding one.
    -- Vanilla forceDropHeavyItem path would trip dupe bugs (see V1 in the
    -- dupe vector matrix) if we let this through.
    local w = F.world()
    local sq = w:square(0, 0, 0)
    local targetCart = makeCartItem({ id = 10 })
    sq:AddWorldInventoryItem(targetCart, 0.5, 0.5, 0.0, false)
    local heldCart = makeCartItem({ id = 11 })
    heldCart.isForceDropHeavyItem = function() return true end

    local p = stubPlayerSurface(w:player({ square = sq }))
    p:setPrimaryHandItem(heldCart)
    local action = ISCartPickupAction:new(p, 0, 0, 0, 10)
    local v = action:isValid()
    w:teardown()

    return Assert.isFalse(v,
        "already holding a heavy item -> pickup rejected (prevents dupe vector V1)")
end

-- =============================================================================
-- ISCartEquipAction :new — primitives-only constructor
-- =============================================================================

tests["equip_constructor_stores_primitives_only"] = function()
    local p = stubPlayerSurface(F.player())
    local action = ISCartEquipAction:new(p, 42, "inventory")

    if not Assert.equal(action.cartId, 42, "cartId stored") then return false end
    if not Assert.equal(action.sourceType, "inventory", "sourceType stored") then return false end
    return Assert.isFalse(action.completed, "completed=false at construction")
end

tests["equip_constructor_vehicle_source_stores_coords"] = function()
    local p = stubPlayerSurface(F.player())
    local action = ISCartEquipAction:new(p, 7, "vehicle", 100, 200, 0)
    if not Assert.equal(action.sourceType, "vehicle", "sourceType=vehicle") then return false end
    if not Assert.equal(action.vehicleX, 100, "vehicleX stored") then return false end
    if not Assert.equal(action.vehicleY, 200, "vehicleY stored") then return false end
    return Assert.equal(action.vehicleZ, 0, "vehicleZ stored")
end

tests["equip_constructor_defaults_sourceType_to_inventory"] = function()
    local p = stubPlayerSurface(F.player())
    local action = ISCartEquipAction:new(p, 1)   -- no sourceType
    return Assert.equal(action.sourceType, "inventory",
        "default source is player inventory (most common case)")
end

tests["equip_FromCart_classifies_inventory_source"] = function()
    -- FromCart inspects cart.container.parent. Character parent -> inventory.
    local p = stubPlayerSurface(F.player())
    local cart = makeCartItem({ id = 77 })
    p:getInventory():AddItem(cart)

    local action = ISCartEquipAction.FromCart(p, cart)
    if not Assert.equal(action.cartId, 77, "cartId extracted") then return false end
    return Assert.equal(action.sourceType, "inventory",
        "cart in player inventory -> sourceType=inventory")
end

tests["equip_FromCart_extracts_no_vehicle_coords_for_inventory_source"] = function()
    local p = stubPlayerSurface(F.player())
    local cart = makeCartItem({ id = 88 })
    p:getInventory():AddItem(cart)

    local action = ISCartEquipAction.FromCart(p, cart)
    if not Assert.isNil(action.vehicleX, "no vehicleX for inventory source") then return false end
    if not Assert.isNil(action.vehicleY, "no vehicleY") then return false end
    return Assert.isNil(action.vehicleZ, "no vehicleZ")
end

-- =============================================================================
-- ISCartEquipAction :findCart — player-inventory lookup
-- =============================================================================

tests["equip_findCart_finds_in_player_inventory"] = function()
    local w = F.world()
    local p = stubPlayerSurface(w:player({ square = w:square(0, 0, 0) }))
    local cart = makeCartItem({ id = 55 })
    p:getInventory():AddItem(cart)

    local action = ISCartEquipAction:new(p, 55, "inventory")
    local found = action:findCart()
    w:teardown()

    return Assert.equal(found, cart, "findCart located cart by id in inventory")
end

tests["equip_findCart_returns_nil_when_cart_not_in_inventory"] = function()
    local w = F.world()
    local p = stubPlayerSurface(w:player({ square = w:square(0, 0, 0) }))

    local action = ISCartEquipAction:new(p, 999, "inventory")
    local found = action:findCart()
    w:teardown()

    return Assert.isNil(found, "cart id not found -> nil (safe abort path)")
end

-- =============================================================================
-- ISCartEquipAction :isValid — guards
-- =============================================================================

tests["equip_isValid_false_when_cart_not_found"] = function()
    local w = F.world()
    local p = stubPlayerSurface(w:player({ square = w:square(0, 0, 0) }))
    local action = ISCartEquipAction:new(p, 123, "inventory")
    local v = action:isValid()
    w:teardown()
    return Assert.isFalse(v, "missing cart -> isValid false")
end

tests["equip_isValid_true_after_completed_flag_set"] = function()
    local p = stubPlayerSurface(F.player())
    local action = ISCartEquipAction:new(p, 1, "inventory")
    action.completed = true
    return Assert.isTrue(action:isValid(),
        "completed=true -> stable isValid (post-equip cart may be in a hand slot, not inv)")
end

tests["equip_isValid_false_when_primary_is_heavy_item"] = function()
    local w = F.world()
    local p = stubPlayerSurface(w:player({ square = w:square(0, 0, 0) }))
    local cart = makeCartItem({ id = 100 })
    p:getInventory():AddItem(cart)
    local heavy = makeNormalItem({ id = 101 })
    heavy.isForceDropHeavyItem = function() return true end
    p:setPrimaryHandItem(heavy)

    local action = ISCartEquipAction:new(p, 100, "inventory")
    local v = action:isValid()
    w:teardown()

    return Assert.isFalse(v,
        "another heavy item held -> reject (same dupe-prevention guard as pickup)")
end

return tests
