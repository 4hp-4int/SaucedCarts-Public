--[[
    SaucedCarts Test Runner
    PURPOSE: Core test framework - registration, execution, and validation
    CONTEXT: client

    Usage:
        local TestRunner = require "SaucedCarts/Tests/TestRunner"
        TestRunner.register("test_name", { run = function(self) ... end, validate = function(self) ... end })
        TestRunner.runAll()
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Tests/TestHelpers"
require "SaucedCarts/Tests/TestFileOutput"

---@class SaucedCartsTestRunner
local TestRunner = {}

-- All registered tests
local Tests = {}

-- Player state (set by setup())
local PLAYER_OBJ
local PLAYER_INV
local PLAYER_SQR

-- Test execution state
local testsToRun = {}
local currentTest = nil
local pause = 0
local tickRegistered = false
local testStartTime = 0

local TestHelpers = SaucedCarts.TestHelpers
local TestFileOutput = SaucedCarts.TestFileOutput

-- ============================================================================
-- SETUP
-- ============================================================================

--- Initialize player references for tests
---@return boolean success
local function setup()
    PLAYER_OBJ = getSpecificPlayer(0)
    if not PLAYER_OBJ then
        print("[SaucedCarts:TEST] ERROR: No player found")
        return false
    end
    PLAYER_INV = PLAYER_OBJ:getInventory()
    PLAYER_SQR = PLAYER_OBJ:getCurrentSquare()
    return true
end

--- Get current player object (for tests)
---@return IsoPlayer|nil
function TestRunner.getPlayer()
    return PLAYER_OBJ
end

--- Get current player inventory (for tests)
---@return ItemContainer|nil
function TestRunner.getPlayerInventory()
    return PLAYER_INV
end

--- Get current player square (for tests)
---@return IsoGridSquare|nil
function TestRunner.getPlayerSquare()
    return PLAYER_SQR
end

--- Run setup and return success
---@return boolean
function TestRunner.setup()
    return setup()
end

-- ============================================================================
-- TEST REGISTRATION
-- ============================================================================

--- Register a test
---@param name string Unique test name
---@param test table Test definition with run() and validate() methods
function TestRunner.register(name, test)
    if Tests[name] then
        SaucedCarts.error("Test already registered: " .. name)
        return
    end
    if not test.run or not test.validate then
        SaucedCarts.error("Test must have run() and validate() methods: " .. name)
        return
    end
    Tests[name] = test
end

--- Get all registered tests
---@return table
function TestRunner.getTests()
    return Tests
end

--- Get test count
---@return number
function TestRunner.getCount()
    local count = 0
    for _ in pairs(Tests) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- TEST EXECUTION
-- ============================================================================

local function PostValidate(name)
    if Tests[name] and Tests[name].validate then
        local success = Tests[name]:validate()
        if not success then
            TestFileOutput.writef("  Test '%s' FAILED", name)
        else
            TestFileOutput.writef("  Test '%s' PASSED", name)
        end

        -- Update UI panel if it exists
        if SaucedCartsTestsPanel and SaucedCartsTestsPanel.updateResult then
            SaucedCartsTestsPanel.updateResult(name, success)
        end
    end
end

local function RunTest(name)
    currentTest = name
    pause = getTimestampMs() + 500  -- Small pause before checking result
    testStartTime = getTimestampMs()

    TestFileOutput.writef("\n[TEST] %s", name)

    PLAYER_OBJ = getSpecificPlayer(0)
    if not PLAYER_OBJ then
        TestFileOutput.write("  ERROR: No player")
        return
    end

    PLAYER_INV = PLAYER_OBJ:getInventory()
    PLAYER_SQR = PLAYER_OBJ:getCurrentSquare()

    -- Full cleanup: clear player, remove ground carts, restore health
    TestHelpers.fullCleanup(PLAYER_OBJ)

    -- Update UI panel if it exists
    if SaucedCartsTestsPanel and SaucedCartsTestsPanel.markRunning then
        SaucedCartsTestsPanel.markRunning(name)
    end

    -- Say test name for visual feedback
    PLAYER_OBJ:Say(name)

    -- Run the test
    Tests[name]:run()
end

local function OnTick()
    local playerObj = getSpecificPlayer(0)
    if not playerObj then return end

    local queue = ISTimedActionQueue.getTimedActionQueue(playerObj)

    -- Check if action queue is empty
    if not queue or not queue.queue or not queue.queue[1] then
        if currentTest then
            -- Validate after action completes
            PostValidate(currentTest)
            currentTest = nil
            pause = getTimestampMs() + 1000  -- Pause before next test
        end

        -- Wait for pause
        if pause > getTimestampMs() then
            return
        end

        -- No more tests?
        if #testsToRun == 0 then
            TestFileOutput.write("\n=== All Tests Complete ===")
            TestFileOutput.close()
            Events.OnTick.Remove(OnTick)
            tickRegistered = false
            return
        end

        -- Run next test
        local testName = testsToRun[1]
        table.remove(testsToRun, 1)
        RunTest(testName)
    end
end

--- Run a single test by name
---@param name string Test name
function TestRunner.runOne(name)
    if not Tests[name] then
        print("[SaucedCarts:TEST] Unknown test: " .. tostring(name))
        return
    end

    TestFileOutput.open()
    TestFileOutput.writef("Running test: %s", name)

    table.insert(testsToRun, name)

    if not tickRegistered then
        Events.OnTick.Add(OnTick)
        tickRegistered = true
    end
end

--- Run all tests
function TestRunner.runAll()
    TestFileOutput.open()
    TestFileOutput.writef("Running %d tests...", TestRunner.getCount())

    table.wipe(testsToRun)
    for name, _ in pairs(Tests) do
        table.insert(testsToRun, name)
    end

    -- Sort for consistent order
    table.sort(testsToRun)

    if not tickRegistered then
        Events.OnTick.Add(OnTick)
        tickRegistered = true
    end
end

--- Stop running tests
function TestRunner.stop()
    table.wipe(testsToRun)
    currentTest = nil
    TestFileOutput.write("\n=== Tests Stopped ===")
    TestFileOutput.close()
end

--- List all available tests
function TestRunner.list()
    print("=== SaucedCarts Tests ===")
    local names = {}
    for name, _ in pairs(Tests) do
        table.insert(names, name)
    end
    table.sort(names)
    for _, name in ipairs(names) do
        print("  " .. name)
    end
    print(string.format("Total: %d tests", #names))
end

-- Store in SaucedCarts namespace
SaucedCarts.TestRunner = TestRunner

return TestRunner
