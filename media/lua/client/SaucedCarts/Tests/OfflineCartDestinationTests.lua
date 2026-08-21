--[[
    SaucedCarts — cart destination rule (isItemAllowed gate)
    ========================================================

    ContainerRestrictions.isCartDestinationBlocked is the pure rule behind
    the __classmetatables isItemAllowed override — the server-authoritative
    answer to "may a CART item enter this container?". Extracted for
    coverage in v2.1.20 (the wrapper itself needs real Java classes).

    The matrix these tests pin (v2.1.20 semantics):
      floor (type or square parent)        -> ALLOWED  (drop flow)
      vehicle (type or BaseVehicle/
               VehiclePart parent)         -> ALLOWED  (trunk stow, v2.1.14
                                                        vanilla parity)
      player main inventory (IsoPlayer)    -> BLOCKED  (the v2.1.20 flip —
                                                        the old allowance was
                                                        a vestige and taught
                                                        compliant mods to
                                                        pocket carts)
      bags / furniture / unknown           -> BLOCKED
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/ContainerRestrictions"

local blocked = SaucedCarts.ContainerRestrictions.isCartDestinationBlocked

local function parentOf(class) return { _type = class } end

local tests = {}

tests["floor_type_allowed"] = function()
    return Assert.isFalse(blocked("floor", nil), "floor container type allows carts")
end

tests["floor_type_allowed_regardless_of_parent"] = function()
    -- type check runs FIRST: mod-wrapped containers with odd parents but a
    -- correct type (the Tetris compat rationale) still classify right
    return Assert.isFalse(blocked("Floor", parentOf("SomeModObject")),
        "floor type wins even with an unknown parent (case-insensitive)")
end

tests["square_parent_allowed"] = function()
    return Assert.isFalse(blocked("none", parentOf("IsoGridSquare")), "ground parent allows carts")
end

tests["vehicle_container_type_allowed"] = function()
    return Assert.isFalse(blocked("TruckBed", parentOf("SomeModObject")),
        "vehicle container type allows carts without a capacity block")
end

tests["base_vehicle_parent_allowed"] = function()
    return Assert.isFalse(blocked("none", parentOf("BaseVehicle")), "BaseVehicle parent allows carts")
end

tests["vehicle_part_parent_allowed"] = function()
    return Assert.isFalse(blocked("none", parentOf("VehiclePart")), "VehiclePart parent allows carts")
end

tests["player_main_inventory_blocked"] = function()
    -- THE v2.1.20 flip. If this ever goes back to allowed, every
    -- isItemAllowed-consulting path starts pocketing carts again
    -- (Common Sense transferIfNeeded, vanilla multi-selection Grab, Picking
    -- Meister's area-pickup filter).
    return Assert.isTrue(blocked("none", parentOf("IsoPlayer")),
        "player main inventory must be blocked for carts")
end

tests["bag_parent_blocked"] = function()
    return Assert.isTrue(blocked("none", parentOf("InventoryItem")), "bags/containers block carts")
end

tests["unknown_everything_blocked"] = function()
    return Assert.isTrue(blocked(nil, nil), "no type, no parent -> block (fail closed)")
end

return tests
