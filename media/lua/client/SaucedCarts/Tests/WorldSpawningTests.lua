--[[
    SaucedCarts WorldSpawning Tests
    PURPOSE: Tests for spawn location registration and building limit logic
    CONTEXT: client

    Tests cover:
    - SpawnLocations API (getSpawnEntriesForRoom, addSpawnRooms, etc.)
    - Building limit enforcement (hasBuildingReachedLimit, incrementBuildingCount)
    - Sandbox setting effects (getMaxCartsPerBuilding)
    - Debug API (getQueueSize, clearSpawnTracking)
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Tests/TestRunner"
require "SaucedCarts/Tests/TestHelpers"

local TestRunner = SaucedCarts.TestRunner
local TestHelpers = SaucedCarts.TestHelpers

-- ============================================================================
-- SPAWN LOCATIONS API TESTS
-- ============================================================================

TestRunner.register("spawn_getSpawnEntriesForRoom_valid", {
    run = function(self)
        -- Get entries for a known room (gigamart has 25% chance)
        self.entries = SaucedCarts.getSpawnEntriesForRoom("gigamart")
    end,
    validate = function(self)
        if not self.entries then
            return TestHelpers.fail("getSpawnEntriesForRoom('gigamart') returned nil")
        end
        if type(self.entries) ~= "table" then
            return TestHelpers.fail("Expected table, got %s", type(self.entries))
        end
        if #self.entries == 0 then
            return TestHelpers.fail("Entries array is empty")
        end
        -- Check first entry has expected structure
        local entry = self.entries[1]
        if not entry.type or not entry.chance then
            return TestHelpers.fail("Entry missing type or chance field")
        end
        if entry.type ~= "SaucedCarts.ShoppingCart" then
            return TestHelpers.fail("Expected ShoppingCart, got %s", entry.type)
        end
        return TestHelpers.pass("getSpawnEntriesForRoom('gigamart') returns %d entries", #self.entries)
    end
})

TestRunner.register("spawn_getSpawnEntriesForRoom_invalid", {
    run = function(self)
        -- Get entries for a non-existent room
        self.entries = SaucedCarts.getSpawnEntriesForRoom("nonexistent_room_xyz_12345")
    end,
    validate = function(self)
        if self.entries ~= nil then
            return TestHelpers.fail("Expected nil for unknown room, got %s", type(self.entries))
        end
        return TestHelpers.pass("getSpawnEntriesForRoom returns nil for unknown room")
    end
})

TestRunner.register("spawn_getSpawnLocationCount", {
    run = function(self)
        self.count = SaucedCarts.getSpawnLocationCount()
    end,
    validate = function(self)
        if type(self.count) ~= "number" then
            return TestHelpers.fail("Expected number, got %s", type(self.count))
        end
        if self.count < 1 then
            return TestHelpers.fail("Expected at least 1 room, got %d", self.count)
        end
        return TestHelpers.pass("getSpawnLocationCount() returns %d rooms", self.count)
    end
})

TestRunner.register("spawn_getSpawnRoomNames_sorted", {
    run = function(self)
        self.rooms = SaucedCarts.getSpawnRoomNames()
    end,
    validate = function(self)
        if type(self.rooms) ~= "table" then
            return TestHelpers.fail("Expected table, got %s", type(self.rooms))
        end
        if #self.rooms < 1 then
            return TestHelpers.fail("Expected at least 1 room name")
        end
        -- Check sorted order
        for i = 2, #self.rooms do
            if self.rooms[i] < self.rooms[i-1] then
                return TestHelpers.fail("Room names not sorted: %s before %s", self.rooms[i-1], self.rooms[i])
            end
        end
        return TestHelpers.pass("getSpawnRoomNames() returns %d sorted rooms", #self.rooms)
    end
})

TestRunner.register("spawn_addSpawnRooms_registers", {
    run = function(self)
        -- Use a unique room name to avoid conflicts
        local testRoom = "test_spawn_room_" .. os.time()
        self.testRoom = testRoom

        -- Before: should be nil
        self.beforeEntries = SaucedCarts.getSpawnEntriesForRoom(testRoom)

        -- Add spawn room for a test cart type
        SaucedCarts.addSpawnRooms("TestMod.TestCart", {{room = testRoom, chance = 42}})

        -- After: should have entry
        self.afterEntries = SaucedCarts.getSpawnEntriesForRoom(testRoom)
    end,
    validate = function(self)
        if self.beforeEntries ~= nil then
            return TestHelpers.fail("Test room already existed before registration")
        end
        if not self.afterEntries then
            return TestHelpers.fail("Room not registered after addSpawnRooms")
        end
        if #self.afterEntries ~= 1 then
            return TestHelpers.fail("Expected 1 entry, got %d", #self.afterEntries)
        end
        local entry = self.afterEntries[1]
        if entry.type ~= "TestMod.TestCart" then
            return TestHelpers.fail("Expected TestMod.TestCart, got %s", entry.type)
        end
        if entry.chance ~= 42 then
            return TestHelpers.fail("Expected chance 42, got %d", entry.chance)
        end
        return TestHelpers.pass("addSpawnRooms() registers new room '%s'", self.testRoom)
    end
})

TestRunner.register("spawn_addSpawnRooms_updates_duplicate", {
    run = function(self)
        -- Use a unique room name
        local testRoom = "test_dup_room_" .. os.time()
        self.testRoom = testRoom

        -- Add first entry
        SaucedCarts.addSpawnRooms("TestMod.DupCart", {{room = testRoom, chance = 10}})
        self.firstEntries = SaucedCarts.getSpawnEntriesForRoom(testRoom)
        self.firstChance = self.firstEntries and self.firstEntries[1] and self.firstEntries[1].chance

        -- Add duplicate with different chance (should update, not add)
        SaucedCarts.addSpawnRooms("TestMod.DupCart", {{room = testRoom, chance = 50}})
        self.afterEntries = SaucedCarts.getSpawnEntriesForRoom(testRoom)
    end,
    validate = function(self)
        if not self.afterEntries then
            return TestHelpers.fail("No entries after duplicate add")
        end
        -- Should still be 1 entry (updated, not added)
        if #self.afterEntries ~= 1 then
            return TestHelpers.fail("Expected 1 entry after duplicate, got %d", #self.afterEntries)
        end
        local entry = self.afterEntries[1]
        if entry.chance ~= 50 then
            return TestHelpers.fail("Duplicate should update chance to 50, got %d", entry.chance)
        end
        return TestHelpers.pass("addSpawnRooms() updates duplicate (chance %d -> %d)", self.firstChance, entry.chance)
    end
})

-- ============================================================================
-- BUILDING LIMIT TESTS (require WorldSpawning module)
-- ============================================================================

TestRunner.register("spawn_getMaxCartsPerBuilding", {
    run = function(self)
        local ws = SaucedCarts.WorldSpawning
        if not ws or not ws._getMaxCartsPerBuilding then
            self.skipped = true
            return
        end
        self.max = ws._getMaxCartsPerBuilding()
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("WorldSpawning._getMaxCartsPerBuilding not available")
        end
        if type(self.max) ~= "number" then
            return TestHelpers.fail("Expected number, got %s", type(self.max))
        end
        if self.max < 1 then
            return TestHelpers.fail("Max should be >= 1, got %d", self.max)
        end
        return TestHelpers.pass("getMaxCartsPerBuilding() returns %d", self.max)
    end
})

TestRunner.register("spawn_hasBuildingReachedLimit_false", {
    run = function(self)
        local ws = SaucedCarts.WorldSpawning
        if not ws or not ws._hasBuildingReachedLimit or not ws._resetSpawnTracking then
            self.skipped = true
            return
        end
        -- Clean slate
        ws._resetSpawnTracking()

        -- Fresh building should not be at limit
        self.atLimit = ws._hasBuildingReachedLimit("test_building_limit_false_" .. os.time())
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("WorldSpawning test APIs not available")
        end
        if self.atLimit ~= false then
            return TestHelpers.fail("Fresh building should not be at limit")
        end
        return TestHelpers.pass("hasBuildingReachedLimit returns false for fresh building")
    end
})

TestRunner.register("spawn_hasBuildingReachedLimit_true", {
    run = function(self)
        local ws = SaucedCarts.WorldSpawning
        if not ws or not ws._hasBuildingReachedLimit or not ws._incrementBuildingCount or not ws._getMaxCartsPerBuilding or not ws._resetSpawnTracking then
            self.skipped = true
            return
        end
        -- Clean slate
        ws._resetSpawnTracking()

        local buildingKey = "test_building_limit_true_" .. os.time()
        local max = ws._getMaxCartsPerBuilding()
        self.max = max

        -- Increment to max
        for i = 1, max do
            ws._incrementBuildingCount(buildingKey)
        end

        -- Should now be at limit
        self.atLimit = ws._hasBuildingReachedLimit(buildingKey)
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("WorldSpawning test APIs not available")
        end
        if self.atLimit ~= true then
            return TestHelpers.fail("Building with %d carts should be at limit", self.max)
        end
        return TestHelpers.pass("hasBuildingReachedLimit returns true after %d increments", self.max)
    end
})

TestRunner.register("spawn_incrementBuildingCount", {
    run = function(self)
        local ws = SaucedCarts.WorldSpawning
        if not ws or not ws._incrementBuildingCount or not ws._getSpawnedBuildings or not ws._resetSpawnTracking then
            self.skipped = true
            return
        end
        -- Clean slate
        ws._resetSpawnTracking()

        local buildingKey = "test_building_increment_" .. os.time()
        self.buildingKey = buildingKey

        -- Before
        local buildings = ws._getSpawnedBuildings()
        self.beforeCount = buildings[buildingKey] or 0

        -- Increment
        ws._incrementBuildingCount(buildingKey)

        -- After
        self.afterCount = buildings[buildingKey] or 0
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("WorldSpawning test APIs not available")
        end
        if self.beforeCount ~= 0 then
            return TestHelpers.fail("Building should start at 0, got %d", self.beforeCount)
        end
        if self.afterCount ~= 1 then
            return TestHelpers.fail("After increment should be 1, got %d", self.afterCount)
        end
        return TestHelpers.pass("incrementBuildingCount: %d -> %d", self.beforeCount, self.afterCount)
    end
})

-- ============================================================================
-- DEBUG API TESTS
-- ============================================================================

TestRunner.register("spawn_resetSpawnTracking_clears", {
    run = function(self)
        local ws = SaucedCarts.WorldSpawning
        if not ws or not ws._resetSpawnTracking or not ws._incrementBuildingCount or not ws._getSpawnedBuildings then
            self.skipped = true
            return
        end

        -- Add some tracking data
        local buildingKey = "test_building_clear_" .. os.time()
        ws._incrementBuildingCount(buildingKey)
        ws._incrementBuildingCount(buildingKey)

        local buildings = ws._getSpawnedBuildings()
        self.beforeCount = buildings[buildingKey] or 0

        -- Reset
        ws._resetSpawnTracking()

        -- Check after
        buildings = ws._getSpawnedBuildings()
        self.afterCount = buildings[buildingKey] or 0
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("WorldSpawning test APIs not available")
        end
        if self.beforeCount < 1 then
            return TestHelpers.fail("Should have data before reset")
        end
        if self.afterCount ~= 0 then
            return TestHelpers.fail("Should be 0 after reset, got %d", self.afterCount)
        end
        return TestHelpers.pass("resetSpawnTracking clears building data (%d -> %d)", self.beforeCount, self.afterCount)
    end
})

TestRunner.register("spawn_getQueueSize_api", {
    run = function(self)
        local ws = SaucedCarts.WorldSpawning
        if not ws or not ws.getQueueSize then
            self.skipped = true
            return
        end
        self.queueSize = ws.getQueueSize()
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("WorldSpawning.getQueueSize not available")
        end
        if type(self.queueSize) ~= "number" then
            return TestHelpers.fail("Expected number, got %s", type(self.queueSize))
        end
        if self.queueSize < 0 then
            return TestHelpers.fail("Queue size should be >= 0, got %d", self.queueSize)
        end
        return TestHelpers.pass("getQueueSize() returns %d", self.queueSize)
    end
})

SaucedCarts.debug("WorldSpawningTests module loaded")
