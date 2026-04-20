--[[
    SaucedCarts — Drop action (V hotkey / context-menu "Drop") tests
    ================================================================

    Vanilla ISDropWorldItemAction:isValid has a hardcoded 50kg floor-weight
    gate — if (ground weight + item:getUnequippedWeight()) > 50, the drop
    is rejected as "invalid" and ISTimedActionQueue clears the action as
    "bugged". Our capacity override lets carts hold >50kg of contents, so
    a loaded cart's unequipped weight reliably trips the gate.

    Regression reported 2026-04-19: "when I press V hotkey to drop, bugged
    action in SP". Root cause was the unmodified vanilla isValid check.
    Fix wraps isValid so the floor-weight gate is skipped for cart items.

    These tests lock the carve-out so any future rewrite of the drop hook
    that removes the isValid wrapper will fail here.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/ContainerRestrictions"

-- Vanilla ISDropWorldItemAction source isn't in pz-test-kit's vanilla_requires
-- by default. Register a minimal stand-in that models the fields our wrapper
-- reads; ContainerRestrictions overwrites isValid at install time so the
-- wrapped version is what we test against.
ISDropWorldItemAction = ISDropWorldItemAction or {}
ISDropWorldItemAction.Type = "ISDropWorldItemAction"
if not ISDropWorldItemAction.isValid then
    ISDropWorldItemAction.isValid = function(self)
        local ground = self.sq and self.sq:getTotalWeightOfItemsOnFloor() or 0
        local itemW = self.item and self.item:getUnequippedWeight() or 0
        if ground + itemW > 50 then return false end
        return self.character:getInventory():contains(self.item)
    end
end
if not ISDropWorldItemAction.complete then
    ISDropWorldItemAction.complete = function(self) return true end
end

-- Re-run the init now that the stub exists.
if SaucedCarts.ContainerRestrictions and SaucedCarts.ContainerRestrictions.initDropActionHook then
    SaucedCarts.ContainerRestrictions.initDropActionHook()
end

-- ============================================================================
-- MOCKS
-- ============================================================================

local function makeSquare(groundWeight)
    return {
        _groundW = groundWeight or 0,
        getTotalWeightOfItemsOnFloor = function(self) return self._groundW end,
        isAdjacentTo = function(self, other) return true end,
        isBlockedTo = function(self, other) return false end,
    }
end

local function makeInventory()
    local inv = { _items = {} }
    inv.contains = function(self, item)
        for _, it in ipairs(self._items) do if it == item then return true end end
        return false
    end
    inv.containsID = function(self, id)
        for _, it in ipairs(self._items) do
            if it.getID and it:getID() == id then return true end
        end
        return false
    end
    inv.AddItem = function(self, item) table.insert(self._items, item); return item end
    return inv
end

local function makeCharacter(inv)
    return {
        _inv = inv,
        getInventory = function(self) return self._inv end,
        getCurrentSquare = function(self) return self._sq end,
    }
end

local function makeCart(opts)
    opts = opts or {}
    return {
        _weight = opts.weight or 60,   -- loaded cart, trips vanilla 50-cap
        _fullType = "SaucedCarts.ShoppingCart",
        _type = "InventoryContainer",
        getID = function(self) return opts.id or 200 end,
        getUnequippedWeight = function(self) return self._weight end,
        getFullType = function(self) return self._fullType end,
    }
end

local function makeLooseItem(opts)
    opts = opts or {}
    return {
        _weight = opts.weight or 60,
        _fullType = opts.fullType or "Base.Generator",
        getID = function(self) return opts.id or 300 end,
        getUnequippedWeight = function(self) return self._weight end,
        getFullType = function(self) return self._fullType end,
    }
end

-- Extend safeIsCart so our Lua-table mock cart qualifies without disturbing
-- the real implementation.
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item._fullType and item._fullType:find("^SaucedCarts") then
        return true
    end
    return origSafeIsCart(item)
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

tests["loaded_cart_drop_bypasses_vanilla_50kg_floor_cap"] = function()
    local inv = makeInventory()
    local cart = makeCart({ weight = 60 })   -- > 50kg
    inv:AddItem(cart)
    local chr = makeCharacter(inv)
    local sq = makeSquare(0)
    chr._sq = sq

    local action = setmetatable({
        character = chr, item = cart, sq = sq, isPlaceItem = false,
    }, { __index = ISDropWorldItemAction })

    return Assert.isTrue(
        ISDropWorldItemAction.isValid(action),
        "loaded 60kg cart should be valid to drop despite vanilla 50kg cap"
    )
end

tests["loaded_cart_valid_even_with_ground_weight"] = function()
    -- Adversarial: ground already has 40kg, cart is 60kg. Vanilla would
    -- reject at 100 > 50. Our wrapper skips the check.
    local inv = makeInventory()
    local cart = makeCart({ weight = 60 })
    inv:AddItem(cart)
    local chr = makeCharacter(inv)
    local sq = makeSquare(40)
    chr._sq = sq

    local action = setmetatable({
        character = chr, item = cart, sq = sq, isPlaceItem = false,
    }, { __index = ISDropWorldItemAction })

    return Assert.isTrue(
        ISDropWorldItemAction.isValid(action),
        "cart drop valid with 40kg ground + 60kg cart (100 > 50)"
    )
end

tests["non_cart_still_respects_vanilla_50kg_cap"] = function()
    -- Carve-out must be cart-only. A heavy non-cart item (generator)
    -- still goes through vanilla's original isValid and is rejected by
    -- the weight gate. Otherwise we'd be breaking the floor-cap for
    -- every item, not just our carts.
    local inv = makeInventory()
    local heavyItem = makeLooseItem({ weight = 60 })
    inv:AddItem(heavyItem)
    local chr = makeCharacter(inv)
    local sq = makeSquare(0)
    chr._sq = sq

    local action = setmetatable({
        character = chr, item = heavyItem, sq = sq, isPlaceItem = false,
    }, { __index = ISDropWorldItemAction })

    return Assert.isFalse(
        ISDropWorldItemAction.isValid(action),
        "non-cart 60kg item should still be rejected by vanilla 50kg cap"
    )
end

tests["cart_not_in_inventory_invalid"] = function()
    -- Last-mile safety: even with the weight carve-out, the action still
    -- requires the cart to be in the character's inventory. Otherwise the
    -- engine would try to drop a ghost item.
    local inv = makeInventory()
    local cart = makeCart({ weight = 60 })
    -- Intentionally NOT added to inventory
    local chr = makeCharacter(inv)
    local sq = makeSquare(0)
    chr._sq = sq

    local action = setmetatable({
        character = chr, item = cart, sq = sq, isPlaceItem = false,
    }, { __index = ISDropWorldItemAction })

    return Assert.isFalse(
        ISDropWorldItemAction.isValid(action),
        "cart not in inventory -> invalid (engine safety)"
    )
end

return tests
