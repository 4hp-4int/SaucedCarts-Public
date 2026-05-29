--[[
    SaucedCarts/Tests/OfflineTransferRestrictionTests.lua
    =====================================================

    Coverage for the transferItemsByWeight fast-path discriminator.

    transferItemsByWeight is VANILLA's ISInventoryPane method, called on
    essentially every UI inventory transfer. Our hook (TransferRestrictions)
    wraps it only to block/filter CARTS. transferInvolvesCart is the cheap
    pre-scan that gates the fast path: when it returns false, the wrapper
    delegates straight to vanilla with no destination classification,
    table-building, notifications, or logging.

    These tests lock that discriminator: a transfer with no cart must report
    false (so the common case stays a pass-through), and a cart in any
    position — bare, mixed, or stack-wrapped (context-menu format) — must
    report true.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"
local TR = require "SaucedCarts/Restrictions/TransferRestrictions"

-- Recognize Lua-table cart mocks (additive — real userdata items still pass
-- through the original implementation). Mirrors the OfflineCapacityOverride
-- test pattern.
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table"
        and item._type == "InventoryContainer"
        and item.getFullType
        and (item:getFullType() or ""):find("^SaucedCarts%.") then
        return true
    end
    return origSafeIsCart(item)
end

local function cartMock()
    local c = F.item({ fullType = "SaucedCarts.TestCart" })
    c._type = "InventoryContainer"   -- safeIsCart recognizes this + instanceof routing
    return c
end

local function plainItem()
    return F.item({ fullType = "Base.Stone" })   -- _type stays "InventoryItem"
end

local tests = {}

tests["transferInvolvesCart_is_callable"] = function()
    return Assert.equal(type(TR._transferInvolvesCart), "function",
        "discriminator exposed as a test hook (module loaded offline)")
end

tests["transferInvolvesCart_false_for_empty_list"] = function()
    return Assert.equal(TR._transferInvolvesCart({}), false,
        "empty transfer involves no cart -> fast-path delegates to vanilla")
end

tests["transferInvolvesCart_false_for_non_cart_items"] = function()
    return Assert.equal(TR._transferInvolvesCart({ plainItem(), plainItem() }), false,
        "plain-item transfer involves no cart (the common case)")
end

tests["transferInvolvesCart_true_when_cart_present"] = function()
    return Assert.equal(TR._transferInvolvesCart({ cartMock() }), true,
        "a bare cart item is detected")
end

tests["transferInvolvesCart_true_for_mixed_list"] = function()
    return Assert.equal(TR._transferInvolvesCart({ plainItem(), cartMock(), plainItem() }), true,
        "a cart anywhere in the list is detected")
end

tests["transferInvolvesCart_true_for_stack_wrapped_cart"] = function()
    -- Context-menu stack format: { items = { item, ... } }
    return Assert.equal(TR._transferInvolvesCart({ { items = { cartMock() } } }), true,
        "cart wrapped in a stack table is unwrapped + detected")
end

tests["transferInvolvesCart_false_for_stack_wrapped_non_cart"] = function()
    return Assert.equal(TR._transferInvolvesCart({ { items = { plainItem() } } }), false,
        "stack-wrapped plain item involves no cart")
end

return tests
