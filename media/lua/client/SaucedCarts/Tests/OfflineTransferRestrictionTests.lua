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

-- ============================================================================
-- ISInventoryTransferAction.new hook: foreign cart->main-inventory transfers
-- are invalidated (VB_CommonSense "Equip from ground" interop, 2026-08-18).
-- Main inventory is the one destination the server-side isItemAllowed must
-- keep permitting (our equip pipeline transits it via direct AddItem), so
-- this client hook is the only gate that sees the foreign vanilla-transfer
-- path. Floor and vehicle destinations must stay untouched: floor is the
-- drop flow, vehicle is the trunk-stow flow.
-- ============================================================================

local function makeDest(parentClass, containerType)
    return {
        -- kit instanceof recognizes table mocks by _type (same convention as
        -- cartMock above)
        getParent = function() return parentClass and { _type = parentClass } or nil end,
        getType = function() return containerType or "none" end,
        getCapacityWeight = function() return 0 end,
        getCapacity = function() return 50 end,
    }
end

local function installHookOnStub()
    -- Fresh stub class per test; the module wrapper installs over it.
    local class = {}
    class.new = function(self, character, item, src, dest, time)
        return { isValid = function() return "original" end }
    end
    _G.ISInventoryTransferAction = class
    TR._resetTransferActionHook()
    TR._initTransferActionHook()
    return class
end

local function makeCharacter()
    return { getID = function() return 1 end }
end

tests["hook_invalidates_cart_to_main_inventory"] = function()
    local class = installHookOnStub()
    local action = class.new(class, makeCharacter(), cartMock(),
        makeDest("IsoGridSquare", "floor"), makeDest("IsoPlayer", "none"), 50)
    return Assert.equal(action:isValid(), false,
        "vanilla cart->main-inv transfer must be invalidated (queue discards it)")
end

tests["hook_leaves_non_cart_to_main_inventory_alone"] = function()
    local class = installHookOnStub()
    local action = class.new(class, makeCharacter(), plainItem(),
        makeDest("IsoGridSquare", "floor"), makeDest("IsoPlayer", "none"), 50)
    return Assert.equal(action:isValid(), "original",
        "ordinary loot into the pocket is none of our business")
end

tests["hook_leaves_cart_to_floor_alone"] = function()
    local class = installHookOnStub()
    local action = class.new(class, makeCharacter(), cartMock(),
        makeDest("IsoPlayer", "none"), makeDest("IsoGridSquare", "floor"), 50)
    return Assert.equal(action:isValid(), "original",
        "cart drop-to-floor must survive (the drop flow)")
end

tests["hook_leaves_cart_to_vehicle_alone"] = function()
    local class = installHookOnStub()
    local action = class.new(class, makeCharacter(), cartMock(),
        makeDest("IsoGridSquare", "floor"), makeDest("BaseVehicle", "TruckBed"), 50)
    return Assert.equal(action:isValid(), "original",
        "cart into a vehicle trunk must survive (the stow flow)")
end

return tests
