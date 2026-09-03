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
-- COMPLETE-PATH HARNESS
-- ============================================================================
-- The mocks above only model what isValid reads. ISDropWorldItemAction.complete
-- is a different surface: it mutates hands, inventory and the world, and its
-- correctness depends on WHICH VM it is running on. Extend rather than replace,
-- so the isValid tests above keep working unchanged.

local function makeDroppableCart(opts)
    opts = opts or {}
    local cart = makeCart(opts)
    cart._modData = {}
    cart._worldItem = nil
    cart.getModData      = function(self) return self._modData end
    cart.getCondition    = function(self) return opts.condition or 100 end
    cart.setCondition    = function(self, v) self._condition = v end
    cart.getConditionMax = function(self) return opts.conditionMax or 100 end
    cart.getWorldItem    = function(self) return self._worldItem end
    cart.setWorldItem    = function(self, w) self._worldItem = w end
    cart.getItemContainer = function(self) return nil end
    return cart
end

--- Character with the surface complete() touches, plus spies.
local function makeDropCharacter(inv)
    local chr = makeCharacter(inv)
    chr._removedFromHands = 0
    chr._vars = {}
    chr.removeFromHands = function(self) self._removedFromHands = self._removedFromHands + 1 end
    chr.setVariable     = function(self, k, v) self._vars[k] = v end
    chr.getOnlineID     = function(self) return 7 end
    return chr
end

local function makeDropSquare()
    local sq = makeSquare(0)
    sq._added = 0
    sq.AddWorldInventoryItem = function(self, item) self._added = self._added + 1; return item end
    sq.getX = function() return 0 end
    sq.getY = function() return 0 end
    sq.getZ = function() return 0 end
    return sq
end

--- Drive complete() in a chosen VM context with the durability outcome forced,
--- so the test targets the break branch rather than the durability maths.
--- Always restores, even on throw — a leaked isClient stub poisons whichever
--- test Kahlua's arbitrary order runs next.
---@param opts table { client=bool, server=bool, newCondition=number }
---@return table observations
local function runComplete(opts)
    local inv  = makeInventory()
    local cart = makeDroppableCart({ id = 900 })
    -- Drive the REAL projection rather than stubbing its verdict: the fix asks
    -- Durability.projectCondition, which reads distancePushed. 11000 tiles at
    -- the 110-tiles-per-damage rate is 100 damage, exactly enough to take a
    -- 100-condition cart to zero.
    cart:getModData().SaucedCarts_distancePushed = opts.distancePushed or 11000
    inv:AddItem(cart)
    local chr = makeDropCharacter(inv)
    local sq  = makeDropSquare()
    chr._sq = sq

    local obs = { removeCalls = 0, syncDeleteCalls = 0 }
    inv.Remove = function(self, item)
        obs.removeCalls = obs.removeCalls + 1
        for i, it in ipairs(self._items) do
            if it == item then table.remove(self._items, i); break end
        end
    end

    local origIsClient = _G.isClient
    local origIsServer = _G.isServer
    local origSend     = _G.sendRemoveItemFromContainer
    local origApply    = SaucedCarts.Durability.applyAccumulatedDamage
    local origDrop     = SaucedCarts.Durability.dropContentsAndDestroy
    local origVisual   = SaucedCarts.updateCartVisual

    _G.isClient = function() return opts.client end
    _G.isServer = function() return opts.server end
    _G.sendRemoveItemFromContainer = function() obs.syncDeleteCalls = obs.syncDeleteCalls + 1 end
    -- Force the break branch; the durability maths has its own tests.
    SaucedCarts.Durability.applyAccumulatedDamage = function() return opts.newCondition or 0 end
    SaucedCarts.Durability.dropContentsAndDestroy = function() obs.contentsDropped = true; return true end
    SaucedCarts.updateCartVisual = function() end

    SaucedCarts.Network.enableTestMode()
    SaucedCarts.Network.clearCapturedMessages()

    local action = setmetatable({
        character = chr, item = cart, sq = sq, isPlaceItem = false,
    }, { __index = ISDropWorldItemAction })

    local ok, err = pcall(function() ISDropWorldItemAction.complete(action) end)

    obs.toServer = SaucedCarts.Network.getCapturedToServer and
        SaucedCarts.Network.getCapturedToServer() or {}
    SaucedCarts.Network.disableTestMode()

    _G.isClient = origIsClient
    _G.isServer = origIsServer
    _G.sendRemoveItemFromContainer = origSend
    SaucedCarts.Durability.applyAccumulatedDamage = origApply
    SaucedCarts.Durability.dropContentsAndDestroy = origDrop
    SaucedCarts.updateCartVisual = origVisual

    if not ok then error(err) end
    obs.stillInInventory = inv:contains(cart)
    return obs
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

-- ============================================================================
-- complete(): a cart that BREAKS on drop must not be removed client-side
-- ============================================================================
-- Player report (MP): "I unequipped it and dropped it completely out of my
-- inventory... a few minutes later the server still seemed to think I was
-- carrying it. The weight kept increasing over time, causing Pain, Muscle
-- Strain and increasingly severe Weight moodles. God Mode didn't fix it."
--
-- The escalation is vanilla's and needs no help from us: above HEAVY_LOAD
-- level 2, BodyDamage:2313-2326 adds back muscle strain and health damage;
-- BodyDamage:2070-2082 then shrinks maxWeight as the INJURED moodle rises, so
-- the SAME carried weight reads as heavier each cycle. One stale item is
-- enough to start it, and God Mode stops damage without removing the item.
--
-- So the bug we own is a single stale reference. ISDropWorldItemAction.complete
-- replicates (it defines complete), so its cart-break branch runs on the
-- player's client too, where it does a LOCAL inventory Remove plus a
-- sendRemoveItemFromContainer the server rejects — SyncItemDeletePacket is
-- requiredCapability = Capability.EditItem, admin only (verified 42.20.4).
-- Client loses the cart, server keeps it: exactly the reported shape.
--
-- The unequip path already solved this: it delegates to requestInstantDrop and
-- returns without touching the inventory (ContainerRestrictions:270). The drop
-- path must do the same.

tests["mp_client_breaking_cart_is_not_removed_locally"] = function()
    local obs = runComplete({ client = true, server = false, newCondition = 0 })

    if not Assert.equal(obs.removeCalls, 0,
        "an MP client must not remove the cart from its own inventory — the "
        .. "server never hears about it and keeps counting the weight") then
        return false
    end
    return Assert.isTrue(obs.stillInInventory,
        "cart stays in the client's inventory until the server confirms")
end

tests["mp_client_breaking_cart_never_sends_syncitemdelete"] = function()
    -- sendRemoveItemFromContainer from a client is SyncItemDelete, which needs
    -- Capability.EditItem. On a non-admin it is refused outright, and under a
    -- punishing AntiCheatPermission policy it is a kick or a ban.
    local obs = runComplete({ client = true, server = false, newCondition = 0 })
    return Assert.equal(obs.syncDeleteCalls, 0,
        "no admin-only delete packet is sent from a player's client")
end

tests["mp_client_breaking_cart_delegates_to_the_server"] = function()
    -- Not enough to do nothing: the break still has to happen, server-side.
    local obs = runComplete({ client = true, server = false, newCondition = 0 })
    local sawDelegation = false
    for _, m in ipairs(obs.toServer or {}) do
        if m.command == "requestInstantDrop" then sawDelegation = true end
    end
    return Assert.isTrue(sawDelegation,
        "the client asks the server to perform the drop, as the unequip path does")
end

tests["sp_breaking_cart_still_drops_locally"] = function()
    -- Precision: singleplayer has no server to delegate to, and the local path
    -- is correct there. The fix must be MP-scoped, not a blanket disable.
    local obs = runComplete({ client = false, server = false, newCondition = 0 })
    if not Assert.equal(obs.removeCalls, 1,
        "SP still removes the broken cart locally") then return false end
    return Assert.isTrue(obs.contentsDropped,
        "and still spills its contents")
end

return tests
