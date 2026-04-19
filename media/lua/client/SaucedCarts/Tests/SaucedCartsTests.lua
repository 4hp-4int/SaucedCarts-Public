--[[
    SaucedCarts Test Definitions
    PURPOSE: Main entry point for test framework - loads all test modules
    CONTEXT: client

    This file loads the test runner and all test modules, then exports
    the public API via SaucedCarts.Tests namespace.

    Test Modules:
    - DuplicationTests.lua: Pickup, drop, repair duplication detection
    - FunctionalTests.lua: Equip, content preservation, repair effects
    - OrphanTests.lua: Orphan detection, marking, and recovery
    - VisualTests.lua: Fill state calculation and model switching
    - CoreTests.lua: Core API, durability, container restrictions
    - FlashlightTests.lua: Flashlight installation, toggle, battery
    - MPSyncTests.lua: MP synchronization handlers and network layer
    - WorldSpawningTests.lua: Spawn locations, building limits, queue API
    - SerializationTests.lua: MP serialization correctness (constructors, payloads)
]]

-- Context guard
if isServer() and not isClient() then return end

-- Load core test framework
require "SaucedCarts/Tests/TestRunner"

-- Load all test modules (they register themselves with TestRunner)
require "SaucedCarts/Tests/DuplicationTests"
require "SaucedCarts/Tests/FunctionalTests"
require "SaucedCarts/Tests/OrphanTests"
require "SaucedCarts/Tests/VisualTests"
require "SaucedCarts/Tests/CoreTests"
require "SaucedCarts/Tests/FlashlightTests"
require "SaucedCarts/Tests/MPSyncTests"
require "SaucedCarts/Tests/WorldSpawningTests"
require "SaucedCarts/Tests/SerializationTests"

-- Export public API via SaucedCarts.Tests namespace
SaucedCarts.Tests = {
    -- Run methods
    runAll = SaucedCarts.TestRunner.runAll,
    runOne = SaucedCarts.TestRunner.runOne,
    stop = SaucedCarts.TestRunner.stop,

    -- Query methods
    getTests = SaucedCarts.TestRunner.getTests,
    getCount = SaucedCarts.TestRunner.getCount,
    list = SaucedCarts.TestRunner.list,
}

return SaucedCarts.Tests
