-- ============================================================================
-- SaucedCarts/Debug/TestCommands.lua
-- ============================================================================
-- PURPOSE: Debug commands for running unit tests
--
-- CONTEXT: CLIENT ONLY
--
-- USAGE:
--   SaucedCartsDebug.runTests()                    -- Run all tests
--   SaucedCartsDebug.runTest("cart_pickup_no_duplicate") -- Run specific test
--   SaucedCartsDebug.listTests()                   -- List available tests
--   SaucedCartsDebug.stopTests()                   -- Stop running tests
-- ============================================================================

if isServer() and not isClient() then return {} end

require "SaucedCarts/Core"
require "SaucedCarts/Tests/SaucedCartsTests"
require "SaucedCarts/Tests/SaucedCartsTestsPanel"

local TestCommands = {}

--- Run all SaucedCarts tests
--- Results are written to Zomboid/Lua/SaucedCartsTestResults.txt
function TestCommands.runTests()
    if not SaucedCarts.Tests then
        print("[SaucedCarts] ERROR: Test framework not loaded")
        return
    end

    local count = SaucedCarts.Tests.getCount()
    print("[SaucedCarts] Running " .. count .. " tests...")
    print("[SaucedCarts] Results will be saved to: Zomboid/Lua/SaucedCartsTestResults.txt")

    SaucedCarts.Tests.runAll()
end

--- Run a single test by name
---@param testName string Name of the test to run
function TestCommands.runTest(testName)
    if not SaucedCarts.Tests then
        print("[SaucedCarts] ERROR: Test framework not loaded")
        return
    end

    if not testName then
        print("[SaucedCarts] ERROR: Please specify a test name")
        print("[SaucedCarts] Usage: SaucedCartsDebug.runTest(\"cart_pickup_no_duplicate\")")
        return
    end

    local tests = SaucedCarts.Tests.getTests()
    if not tests[testName] then
        print("[SaucedCarts] ERROR: Unknown test: " .. testName)
        TestCommands.listTests()
        return
    end

    print("[SaucedCarts] Running test: " .. testName)
    SaucedCarts.Tests.runOne(testName)
end

--- List all available tests
function TestCommands.listTests()
    if not SaucedCarts.Tests then
        print("[SaucedCarts] ERROR: Test framework not loaded")
        return
    end

    SaucedCarts.Tests.list()
end

--- Stop running tests
function TestCommands.stopTests()
    if not SaucedCarts.Tests then
        print("[SaucedCarts] ERROR: Test framework not loaded")
        return
    end

    SaucedCarts.Tests.stop()
    print("[SaucedCarts] Tests stopped")
end

--- Get test count
---@return number
function TestCommands.getTestCount()
    if not SaucedCarts.Tests then
        return 0
    end
    return SaucedCarts.Tests.getCount()
end

--- Open the test panel UI
function TestCommands.openTestPanel()
    if not SaucedCartsTestsPanel then
        print("[SaucedCarts] ERROR: Test panel not loaded")
        return
    end

    SaucedCartsTestsPanel.open()
    print("[SaucedCarts] Test panel opened")
end

return TestCommands
