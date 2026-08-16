--[[
    SaucedCarts — ConsumeWithCart tests
    ===================================

    Field report (2026-08-16): "the cart disappears when you drink." Vanilla
    consume actions are already cart-compatible mechanically (no equip,
    stopOnWalk=false, :complete() defined) but their start() calls
    setOverrideHandModels(<utensil-or-nil>, item), and ModelManager renders
    ONLY the override items while an action override is active — nil primary
    = empty primary hand = no cart model for the whole action.

    ConsumeWithCart wraps the three vanilla consume actions' start() to
    re-assert the equipped cart as the primary override AFTER the vanilla
    override. These tests pin:
      - the re-assert happens (cart primary, consumable secondary), and
        specifically AFTER the vanilla call (last write wins)
      - non-cart primary items are left alone
      - no primary item at all is left alone
      - the wrap is idempotent (double-install keeps one original call)
      - a throwing character accessor can't break the action
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/ConsumeWithCart"

local wrapStart = SaucedCarts.ConsumeWithCart._wrapStart

-- ============================================================================
-- MOCKS
-- ============================================================================

local function makeCart()
    return {
        _type = "InventoryContainer",
        _fullType = "SaucedCarts.ShoppingCart",
        getID = function() return 900 end,
        getFullType = function(self) return self._fullType end,
    }
end

local function makeBottle()
    return {
        _fullType = "Base.WaterBottleFull",
        getID = function() return 901 end,
        getFullType = function(self) return self._fullType end,
    }
end

local function makeCharacter(primaryItem)
    return {
        _primary = primaryItem,
        getPrimaryHandItem = function(self) return self._primary end,
    }
end

-- A stand-in vanilla consume action class: start() performs the vanilla
-- override (nil primary, consumable secondary) and records every override
-- call in order.
local function makeActionClass()
    local class = {}
    class._origStartCalls = 0
    class.start = function(self)
        class._origStartCalls = class._origStartCalls + 1
        self:setOverrideHandModels(nil, self.item)
    end
    return class
end

local function makeActionInstance(class, character, item)
    return {
        character = character,
        item = item,
        _overrideCalls = {},
        setOverrideHandModels = function(self, primary, secondary)
            table.insert(self._overrideCalls, { primary = primary, secondary = secondary })
        end,
        start = class.start,
    }
end

-- Extend safeIsCart for table mocks. Additive and NEVER restored: the kit
-- collects tests at load time and runs them later, so a load-time restore
-- would land before any test executes (OfflineDropActionTests pattern).
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

tests["cart_reasserted_as_primary_after_vanilla_override"] = function()
    local class = makeActionClass()
    wrapStart(class, "MockConsume")
    local cart = makeCart()
    local bottle = makeBottle()
    local action = makeActionInstance(class, makeCharacter(cart), bottle)

    action:start()

    local calls = action._overrideCalls
    if not Assert.equal(#calls, 2, "vanilla override then our re-assert") then return false end
    if not Assert.isNil(calls[1].primary, "vanilla call had nil primary") then return false end
    if not Assert.equal(calls[2].primary, cart, "our call re-asserts the cart as primary") then return false end
    return Assert.equal(calls[2].secondary, bottle,
        "consumable stays in the secondary slot for the left-arm overlay")
end

tests["non_cart_primary_left_alone"] = function()
    local class = makeActionClass()
    wrapStart(class, "MockConsume")
    local axe = { _fullType = "Base.Axe", getFullType = function(self) return self._fullType end }
    local action = makeActionInstance(class, makeCharacter(axe), makeBottle())

    action:start()

    return Assert.equal(#action._overrideCalls, 1,
        "only the vanilla override runs when the primary item is not a cart")
end

tests["empty_hands_left_alone"] = function()
    local class = makeActionClass()
    wrapStart(class, "MockConsume")
    local action = makeActionInstance(class, makeCharacter(nil), makeBottle())

    action:start()

    return Assert.equal(#action._overrideCalls, 1,
        "only the vanilla override runs with nothing in the primary hand")
end

tests["wrap_is_idempotent"] = function()
    local class = makeActionClass()
    wrapStart(class, "MockConsume")
    wrapStart(class, "MockConsume")  -- second install must be a no-op
    local action = makeActionInstance(class, makeCharacter(makeCart()), makeBottle())

    action:start()

    if not Assert.equal(class._origStartCalls, 1, "original start ran exactly once") then return false end
    return Assert.equal(#action._overrideCalls, 2,
        "double-wrap would have produced a third override call")
end

tests["throwing_character_never_breaks_the_action"] = function()
    local class = makeActionClass()
    wrapStart(class, "MockConsume")
    local hostileChr = {
        getPrimaryHandItem = function() error("boom") end,
    }
    local action = makeActionInstance(class, hostileChr, makeBottle())

    local ok = pcall(function() action:start() end)

    if not Assert.isTrue(ok, "wrapped start must not propagate the error") then return false end
    return Assert.equal(class._origStartCalls, 1, "vanilla start still ran")
end

tests["missing_class_is_skipped"] = function()
    return Assert.isFalse(wrapStart(nil, "NotLoaded"),
        "wrapping a missing action class reports false without erroring")
end

return tests
