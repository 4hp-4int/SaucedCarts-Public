-- ============================================================================
-- SaucedCarts/Debug/RegistrationCommands.lua
-- ============================================================================
-- PURPOSE: Registration testing debug commands
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"
require "SaucedCarts/CartData"

local Utils = require "SaucedCarts/Debug/Utils"

local RegistrationCommands = {}

--- List all available cart types with their properties
--- Prints cart name, capacity, and speed modifier to console
function RegistrationCommands.listCarts()
    print("=== Registered Cart Types (" .. SaucedCarts.getCartTypeCount() .. ") ===")
    for fullType, data in pairs(SaucedCarts.CartTypes) do
        print("  " .. fullType)
        print("    Name: " .. data.name)
        print("    Capacity: " .. data.capacity .. ", Speed: " .. (data.runSpeedModifier * 100) .. "%")
        print("    Weight: " .. data.baseWeight .. "kg, Durability: " .. data.conditionMax)
        if data.spawnLocations and #data.spawnLocations > 0 then
            print("    Spawns in: " .. #data.spawnLocations .. " location(s)")
        else
            print("    Spawns in: (no world spawns)")
        end
    end
    print("==========================================")
end

--- Alias for listCarts (for addon developers)
RegistrationCommands.listRegistered = RegistrationCommands.listCarts

--- Check if a specific cart type is registered
--- Useful for addon developers to verify their registration worked
---@param fullType string Full item type (e.g., "MyMod.MyCart") or short name
function RegistrationCommands.checkRegistration(fullType)
    if not fullType then
        print("[SaucedCarts] Usage: SaucedCartsDebug.checkRegistration(\"MyMod.MyCart\")")
        return
    end

    local resolved = Utils.resolveCartType(fullType)
    if resolved then
        local data = SaucedCarts.CartTypes[resolved]
        print("[SaucedCarts] Cart type '" .. resolved .. "' is registered")
        print("  Name: " .. data.name)
        print("  Capacity: " .. data.capacity)
        print("  Weight Reduction: " .. data.weightReduction .. "%")
        print("  Speed: " .. (data.runSpeedModifier * 100) .. "%")
        print("  Durability: " .. data.conditionMax)
        print("  Repair Item: " .. data.repairItem)
        if data.spawnLocations and #data.spawnLocations > 0 then
            print("  Spawn Locations: " .. table.concat(data.spawnLocations, ", "))
            print("  Spawn Weight: " .. data.spawnWeight)
        else
            print("  Spawn Locations: (none - no world spawns)")
        end
    else
        print("[SaucedCarts] Cart type '" .. fullType .. "' is NOT registered")
        print("[SaucedCarts] Registered types: " .. Utils.getAvailableCartTypes())
    end
end

--- Test the registration API with various inputs (for development/testing)
--- Attempts several invalid registrations to verify error handling
function RegistrationCommands.testRegistration()
    print("=== Testing Registration API ===")

    -- Test 1: Missing name
    print("\nTest 1: Missing required 'name' field")
    local ok, err = SaucedCarts.registerCart("TestMod.Test1", {capacity = 50})
    print("  Result: " .. (ok and "PASS (unexpected)" or "FAIL as expected: " .. tostring(err)))

    -- Test 2: Invalid fullType format
    print("\nTest 2: Invalid fullType format")
    ok, err = SaucedCarts.registerCart("BadFormat", {name = "Test"})
    print("  Result: " .. (ok and "PASS (unexpected)" or "FAIL as expected: " .. tostring(err)))

    -- Test 3: Out of range value
    print("\nTest 3: Capacity out of range")
    ok, err = SaucedCarts.registerCart("TestMod.Test3", {name = "Test", capacity = 9999})
    print("  Result: " .. (ok and "PASS (unexpected)" or "FAIL as expected: " .. tostring(err)))

    -- Test 4: Wrong type for field
    print("\nTest 4: Wrong type for capacity")
    ok, err = SaucedCarts.registerCart("TestMod.Test4", {name = "Test", capacity = "fifty"})
    print("  Result: " .. (ok and "PASS (unexpected)" or "FAIL as expected: " .. tostring(err)))

    -- Test 5: Valid registration (should succeed)
    print("\nTest 5: Valid registration")
    ok, err = SaucedCarts.registerCart("TestMod.TestCart", {
        name = "Test Cart",
        description = "A test cart for debugging",
        capacity = 30,
    })
    print("  Result: " .. (ok and "PASS - registered successfully" or "FAIL: " .. tostring(err)))

    -- Test 6: Duplicate registration
    print("\nTest 6: Duplicate registration")
    ok, err = SaucedCarts.registerCart("TestMod.TestCart", {name = "Duplicate"})
    print("  Result: " .. (ok and "PASS (unexpected)" or "FAIL as expected: " .. tostring(err)))

    print("\n=== Registration Tests Complete ===")
end

return RegistrationCommands
