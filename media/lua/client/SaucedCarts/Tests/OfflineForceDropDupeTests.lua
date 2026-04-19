--[[
    SaucedCarts — Vanilla forceDropHeavyItems dupe reproduction
    ===========================================================

    Reproduces the MP cart-dupe vector that's been reported as:
        "If you're pushing a cart while entering a car it dupes the cart
         and everything in it."

    The bug is not in SaucedCarts directly. It's in how vanilla's
    `forceDropHeavyItems(character)` + `ISEnterVehicle:start()` interact in
    MP's B42 timed-action sync system, combined with the "cart has
    heavyitem tag" contract.

    Root mechanism this test exercises:

        ISEnterVehicle:start() runs on BOTH the client and the server
        endpoints of the synced timed action. The relevant block is:

            if primary:hasTag(HEAVY_ITEM) or secondary:hasTag(HEAVY_ITEM) then
                if isClient() then
                    sendClientCommand(character, 'player', 'onDropHeavyItem', ...)
                else
                    forceDropHeavyItems(self.character)
                end
            end

        On the server-side instance: isClient() is false → it calls
        forceDropHeavyItems LOCALLY.
        On the client-side instance: isClient() is true → it fires
        sendClientCommand('player', 'onDropHeavyItem'), which routes to
        Commands.player.onDropHeavyItem on the server, which ALSO calls
        forceDropHeavyItems.

        The server therefore runs forceDropHeavyItems TWICE for the same
        action: once directly, once via the command. If hand references
        haven't been cleared between the two calls, the second call adds
        a second IsoWorldInventoryObject for the same InventoryItem —
        a dupe visible on all observer clients.

    This test file defines:
      - A faithful Lua reimplementation of vanilla forceDropHeavyItems
        matching the decompiled PZ source (ISEquipWeaponAction.lua:75).
      - A mock IsoGridSquare that tracks getWorldObjects() so we can
        count world items after the double-fire.
      - A mock character + cart with HEAVY_ITEM tag.
      - A test that dual-fires forceDropHeavyItems the way MP would.

    No SaucedCarts production code is used — the dupe is independent of
    our mod's code. The fix (ForceDropGuard) will wrap
    forceDropHeavyItems to clear stale hand refs before the second call
    can create a duplicate.
]]

if isServer() and not isClient() then return end

-- Offline-only: PZTestKit is the pz-test-kit harness, absent in real PZ.
-- When loaded in-game at startup, no-op cleanly — these tests are meant
-- to run under `pztest`, not via PZ's auto-loader.
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

-- Stubs: vanilla PZ MP sync globals. Real PZ provides these; the kit's mock
-- environment doesn't, so the faithful vanilla reimplementation needs them
-- present or it errors with "Object tried to call nil".
if not sendRemoveItemFromContainer then
    function sendRemoveItemFromContainer(container, item) end
end
if not sendAddItemToContainer then
    function sendAddItemToContainer(container, item) end
end

-- ============================================================================
-- VANILLA forceDropHeavyItems REIMPLEMENTATION
-- ============================================================================
-- Matches ISEquipWeaponAction.lua:75–99 from PZ's shared/TimedActions/.
-- We reimplement rather than require the real file because the real file
-- pulls in ISTransferAction which has a long dependency chain.

local function makeVanillaForceDrop()
    return function(character)
        if not character or not character:getCurrentSquare() then return end

        local primary = character:getPrimaryHandItem()
        if primary and primary.isForceDropHeavyItem and primary:isForceDropHeavyItem() then
            character:getInventory():Remove(primary)
            sendRemoveItemFromContainer(character:getInventory(), primary)
            -- Vanilla uses ISTransferAction.GetDropItemOffset; a constant
            -- drop offset is sufficient for this test.
            character:getCurrentSquare():AddWorldInventoryItem(primary, 0.5, 0.5, 0)
            character:removeFromHands(primary)
        end

        local secondary = character:getSecondaryHandItem()
        if secondary and secondary.isForceDropHeavyItem and secondary:isForceDropHeavyItem() then
            character:getInventory():Remove(secondary)
            sendRemoveItemFromContainer(character:getInventory(), secondary)
            character:getCurrentSquare():AddWorldInventoryItem(secondary, 0.5, 0.5, 0)
            character:setSecondaryHandItem(nil)
        end
    end
end

-- ============================================================================
-- MOCK FACTORIES — tracked world objects
-- ============================================================================

local function makeMockSquare()
    local sq = { _type = "IsoGridSquare", _worldObjects = {} }

    sq.getWorldObjects = function(self)
        local list = self._worldObjects
        return {
            size = function(_) return #list end,
            get = function(_, i) return list[i + 1] end,
        }
    end

    sq.AddWorldInventoryItem = function(self, item, x, y, z, transmit)
        -- Mirrors vanilla behaviour: creates an IsoWorldInventoryObject
        -- wrapping the InventoryItem. No dedupe check — that's the bug.
        local worldObj = {
            _type = "IsoWorldInventoryObject",
            _item = item,
            getItem = function(me) return me._item end,
            getSquare = function(_) return sq end,
        }
        table.insert(self._worldObjects, worldObj)
        if item and item.setWorldItem then item:setWorldItem(worldObj) end
        return item
    end

    sq.removeWorldObject = function(self, obj)
        for i, o in ipairs(self._worldObjects) do
            if o == obj then table.remove(self._worldObjects, i); return end
        end
    end

    sq.transmitRemoveItemFromSquare = function(_, _) end
    sq.getX = function(_) return 0 end
    sq.getY = function(_) return 0 end
    sq.getZ = function(_) return 0 end

    return sq
end

local function makeInventory()
    local inv = { _items = {} }
    inv.AddItem = function(self, item)
        table.insert(self._items, item)
        return item
    end
    inv.Remove = function(self, item)
        for i, it in ipairs(self._items) do
            if it == item then table.remove(self._items, i); return end
        end
    end
    inv.contains = function(self, item)
        for _, it in ipairs(self._items) do
            if it == item then return true end
        end
        return false
    end
    inv.getItems = function(self)
        return {
            size = function() return #self._items end,
            get = function(_, i) return self._items[i + 1] end,
        }
    end
    return inv
end

local function makeCart(name)
    local cart = {
        _type = "InventoryContainer",
        _id = _pz_gen_id and _pz_gen_id() or math.random(100000, 999999),
        _name = name or "ShoppingCart",
        _worldItem = nil,
        _isForceDrop = true,  -- hasTag(HEAVY_ITEM) == true
    }
    cart.getID = function(self) return self._id end
    cart.getFullType = function(self) return "SaucedCarts." .. self._name end
    cart.getName = function(self) return self._name end
    cart.isForceDropHeavyItem = function(self) return self._isForceDrop end
    cart.getWorldItem = function(self) return self._worldItem end
    cart.setWorldItem = function(self, w) self._worldItem = w end
    cart.hasTag = function(self, tag) return tag == "HEAVY_ITEM" end
    return cart
end

local function makeCharacter(square, inventory)
    local ch = {
        _type = "IsoPlayer",
        _primary = nil,
        _secondary = nil,
        _square = square,
        _inventory = inventory,
    }
    ch.getCurrentSquare = function(self) return self._square end
    ch.getInventory = function(self) return self._inventory end
    ch.getPrimaryHandItem = function(self) return self._primary end
    ch.getSecondaryHandItem = function(self) return self._secondary end
    ch.setPrimaryHandItem = function(self, i) self._primary = i end
    ch.setSecondaryHandItem = function(self, i) self._secondary = i end
    ch.isPrimaryHandItem = function(self, i) return i ~= nil and self._primary == i end
    ch.isSecondaryHandItem = function(self, i) return i ~= nil and self._secondary == i end
    ch.removeFromHands = function(self, item)
        -- Matches IsoGameCharacter.removeFromHands bytecode.
        if self:isPrimaryHandItem(item) then self:setPrimaryHandItem(nil) end
        if self:isSecondaryHandItem(item) then self:setSecondaryHandItem(nil) end
        return true
    end
    return ch
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

-- Sanity: single forceDropHeavyItems call on a freshly-equipped cart drops
-- exactly one world object. Establishes the non-dupe baseline.
tests["vanilla_single_drop_produces_one_world_item"] = function()
    local sq = makeMockSquare()
    local inv = makeInventory()
    local cart = makeCart("ShoppingCart")
    inv:AddItem(cart)

    local ch = makeCharacter(sq, inv)
    ch:setPrimaryHandItem(cart)
    ch:setSecondaryHandItem(cart)  -- two-handed: same InventoryItem ref

    local forceDrop = makeVanillaForceDrop()
    forceDrop(ch)

    if not Assert.equal(sq:getWorldObjects():size(), 1, "one world object after single drop") then return false end
    if not Assert.isNil(ch:getPrimaryHandItem(), "primary cleared") then return false end
    return Assert.isNil(ch:getSecondaryHandItem(), "secondary cleared")
end

-- REPRODUCTION: simulates the MP server receiving two forceDropHeavyItems
-- triggers for the same ISEnterVehicle action:
--   1. The server-side timed-action start() calls it directly (isClient=false branch).
--   2. The client's onDropHeavyItem command arrives at the server and fires it again.
-- If `removeFromHands` in call #1 properly clears both hands, call #2 early-exits
-- and no dupe occurs. Anything that leaves a stale hand ref between the calls
-- produces a dupe.
tests["mp_dual_fire_clears_hands_between_calls"] = function()
    local sq = makeMockSquare()
    local inv = makeInventory()
    local cart = makeCart("ShoppingCart")
    inv:AddItem(cart)

    local ch = makeCharacter(sq, inv)
    ch:setPrimaryHandItem(cart)
    ch:setSecondaryHandItem(cart)

    local forceDrop = makeVanillaForceDrop()
    -- Fire 1: server's ISEnterVehicle:start() (isClient=false branch)
    forceDrop(ch)
    -- Fire 2: server-side handler for Commands.player.onDropHeavyItem
    --         (received from the client's sendClientCommand path)
    forceDrop(ch)

    return Assert.equal(sq:getWorldObjects():size(), 1,
        "MP dual-fire should produce exactly 1 world object (got "
        .. sq:getWorldObjects():size() .. ")")
end

-- REGRESSION CANARY: proves vanilla forceDropHeavyItems STILL has the
-- stale-hand-ref dupe. If this test ever fails (i.e., vanilla no longer
-- dupes), the ForceDropGuard fix is redundant and can be removed. Kept
-- asserting the BAD behaviour intentionally so the guard can be retired
-- when vanilla patches the underlying issue.
tests["vanilla_dupes_with_stale_hand_ref_unguarded"] = function()
    local sq = makeMockSquare()
    local inv = makeInventory()
    local cart = makeCart("ShoppingCart")

    -- Precondition: cart already on the ground and not in inventory, but
    -- hands still reference it. This is the state that MP sync races
    -- (server drop + client stale view) or third-party mod drop handlers
    -- can leave the character in.
    sq:AddWorldInventoryItem(cart, 0.5, 0.5, 0)

    local ch = makeCharacter(sq, inv)
    ch:setPrimaryHandItem(cart)
    ch:setSecondaryHandItem(cart)

    local forceDrop = makeVanillaForceDrop()
    forceDrop(ch)

    -- Vanilla adds a second world object — the dupe. Expected = 2 until
    -- TIS fixes the underlying bug upstream.
    return Assert.equal(sq:getWorldObjects():size(), 2,
        "vanilla forceDropHeavyItems SHOULD dupe when hand ref is stale (got "
        .. sq:getWorldObjects():size() .. ")")
end

-- ============================================================================
-- GUARD VERIFICATION
-- ============================================================================
-- The production fix (ForceDropGuard.makeGuardedForceDrop) wraps vanilla
-- forceDropHeavyItems and clears stale hand refs before the vanilla body
-- runs. Without an in-inventory / in-hand cart, the vanilla body has
-- nothing to drop → no dupe.

require "SaucedCarts/ForceDropGuard"

-- Test-local isCart check: the production SaucedCarts.isCart requires a
-- real Java userdata item; our mock carts are pure Lua tables. Tests
-- inject a sentinel flag check instead.
local function isCartForTest(item)
    return type(item) == "table" and item._type == "InventoryContainer"
        and item._isForceDrop == true
end

tests["force_drop_guard_prevents_dupe_with_stale_primary"] = function()
    local sq = makeMockSquare()
    local inv = makeInventory()
    local cart = makeCart("ShoppingCart")
    sq:AddWorldInventoryItem(cart, 0.5, 0.5, 0)  -- cart already on ground

    local ch = makeCharacter(sq, inv)
    ch:setPrimaryHandItem(cart)
    ch:setSecondaryHandItem(cart)

    local guarded = SaucedCarts.ForceDropGuard.makeGuardedForceDrop(
        makeVanillaForceDrop(), isCartForTest)
    guarded(ch)

    if not Assert.equal(sq:getWorldObjects():size(), 1,
        "guard prevents dupe when primary is stale (expected 1, got "
        .. sq:getWorldObjects():size() .. ")") then return false end
    if not Assert.isNil(ch:getPrimaryHandItem(), "guard cleared stale primary") then return false end
    return Assert.isNil(ch:getSecondaryHandItem(), "guard cleared stale secondary")
end

tests["force_drop_guard_prevents_dupe_when_not_in_inventory"] = function()
    -- Different pathology: cart is NOT in world but IS missing from
    -- inventory. Vanilla still calls AddWorldInventoryItem → dupe on next
    -- force-drop call. Guard catches this via the inventory:contains check.
    local sq = makeMockSquare()
    local inv = makeInventory()
    local cart = makeCart("ShoppingCart")
    -- Cart was removed from inventory by a prior drop, but no worldItem set.
    -- (e.g. server removed + added-with-transmit and the worldItem ref was
    -- nil on this side of the sync.)

    local ch = makeCharacter(sq, inv)
    ch:setPrimaryHandItem(cart)
    ch:setSecondaryHandItem(cart)

    local guarded = SaucedCarts.ForceDropGuard.makeGuardedForceDrop(
        makeVanillaForceDrop(), isCartForTest)
    guarded(ch)

    return Assert.equal(sq:getWorldObjects():size(), 0,
        "guard prevents world-item add when cart already out of inventory")
end

tests["force_drop_guard_allows_normal_drop"] = function()
    -- Baseline: with a legitimately-equipped cart (in inventory, not in
    -- world), guard should let vanilla do its normal drop.
    local sq = makeMockSquare()
    local inv = makeInventory()
    local cart = makeCart("ShoppingCart")
    inv:AddItem(cart)

    local ch = makeCharacter(sq, inv)
    ch:setPrimaryHandItem(cart)
    ch:setSecondaryHandItem(cart)

    local guarded = SaucedCarts.ForceDropGuard.makeGuardedForceDrop(
        makeVanillaForceDrop(), isCartForTest)
    guarded(ch)

    if not Assert.equal(sq:getWorldObjects():size(), 1,
        "guarded drop on clean state produces 1 world item") then return false end
    return Assert.isNil(ch:getPrimaryHandItem(), "primary cleared after normal drop")
end

-- Self-register
PZTestKit.registerTests("offline_forcedrop_dupe", tests)
print("[SaucedCarts:offline] ForceDropDupeTests registered (" .. #tests .. " tests)")

return tests
