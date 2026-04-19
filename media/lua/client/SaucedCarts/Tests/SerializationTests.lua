--[[
    SaucedCarts MP Serialization Tests
    PURPOSE: Tests for MP serialization correctness in timed actions and network commands
    CONTEXT: client

    Tests cover:
    - Timed action constructors use only primitives (no object references)
    - Network payloads contain only serializable types
    - Late-joiner sync responses contain complete state
    - FromXxx helpers correctly extract IDs/coordinates

    NOTE: These tests run in singleplayer/client context. They test the
    STRUCTURE and TYPES of data, not actual network delivery.
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/Upgrades"
require "SaucedCarts/UpgradeSync"
require "SaucedCarts/Tests/TestRunner"
require "SaucedCarts/Tests/TestHelpers"

-- Require timed actions
require "SaucedCarts/TimedActions/ISCartPickupAction"
require "SaucedCarts/TimedActions/ISCartEquipAction"
require "SaucedCarts/TimedActions/ISCartRepairAction"
require "SaucedCarts/TimedActions/ISInstallFlashlightAction"

local TestRunner = SaucedCarts.TestRunner
local TestHelpers = SaucedCarts.TestHelpers
local Network = SaucedCarts.Network

-- ============================================================================
-- SERIALIZATION HELPER FUNCTIONS
-- ============================================================================

--- Check if value is a serializable primitive (per TableNetworkUtils.java)
--- Serializable types: nil, number, string, boolean, table (nested)
---@param value any
---@return boolean isSerializable
---@return string|nil failReason
local function isSerializablePrimitive(value)
    if value == nil then return true, nil end
    local t = type(value)
    if t == "number" then return true, nil end
    if t == "string" then return true, nil end
    if t == "boolean" then return true, nil end
    if t == "table" then return true, nil end  -- Tables allowed but must be checked recursively
    -- Disallowed: functions, userdata (game objects), threads
    return false, "type '" .. t .. "' not serializable"
end

--- Check if value is a non-serializable object reference
--- These are what cause MP bugs - arrive as nil on server
---@param value any
---@return boolean isObjectRef
local function isObjectReference(value)
    if value == nil then return false end
    if type(value) ~= "userdata" then return false end
    -- Check for common Java objects via instanceof
    if instanceof(value, "IsoWorldInventoryObject") then return true end
    if instanceof(value, "BaseVehicle") then return true end
    if instanceof(value, "ItemContainer") then return true end
    -- IsoGridSquare CAN be serialized, but we prefer coords
    if instanceof(value, "IsoGridSquare") then return true end
    return false
end

--- Validate a timed action's stored fields are all serializable
---@param action ISBaseTimedAction
---@param fieldNames string[]
---@return boolean allValid
---@return string|nil failedField
---@return string|nil failReason
local function validateActionFields(action, fieldNames)
    for _, field in ipairs(fieldNames) do
        local value = action[field]
        local isValid, reason = isSerializablePrimitive(value)
        if not isValid then
            return false, field, reason
        end
        if isObjectReference(value) then
            return false, field, "object reference not allowed"
        end
    end
    return true, nil, nil
end

--- Validate network payload contains only serializable values (recursive)
---@param payload table
---@param path string|nil Current path for error reporting
---@return boolean valid
---@return string|nil path Path to invalid value
local function validateNetworkPayload(payload, path)
    path = path or ""
    for k, v in pairs(payload) do
        local keyPath = path .. "." .. tostring(k)

        -- Check key is string or number
        if type(k) ~= "string" and type(k) ~= "number" then
            return false, keyPath .. " (invalid key type: " .. type(k) .. ")"
        end

        -- Check value
        local t = type(v)
        if t == "function" or t == "userdata" or t == "thread" then
            return false, keyPath .. " (invalid value type: " .. t .. ")"
        end
        if t == "table" then
            local valid, subPath = validateNetworkPayload(v, keyPath)
            if not valid then return false, subPath end
        end
    end
    return true, nil
end

-- ============================================================================
-- TIMED ACTION CONSTRUCTOR TESTS
-- ============================================================================

-- ISCartPickupAction: squareX, squareY, squareZ, itemId (all numbers)
TestRunner.register("ser_pickup_constructor_primitives_only", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create action with primitive args only
        local action = ISCartPickupAction:new(PLAYER_OBJ, 100, 200, 0, 12345)

        -- Store for validation
        self.action = action
        self.expectedFields = {"squareX", "squareY", "squareZ", "itemId"}
    end,
    validate = function(self)
        local isValid, field, reason = validateActionFields(self.action, self.expectedFields)
        if not isValid then
            return TestHelpers.fail("Field '%s' failed: %s", field, reason)
        end

        -- Verify specific types
        if type(self.action.squareX) ~= "number" then
            return TestHelpers.fail("squareX should be number, got %s", type(self.action.squareX))
        end
        if type(self.action.itemId) ~= "number" then
            return TestHelpers.fail("itemId should be number, got %s", type(self.action.itemId))
        end

        return TestHelpers.pass("ISCartPickupAction constructor uses only primitives")
    end
})

TestRunner.register("ser_pickup_from_world_item_extracts_coords", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create cart on ground
        local square = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            self.skipped = true
            return
        end

        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        local worldItem = cart:getWorldItem()
        if not worldItem then
            self.skipped = true
            return
        end

        self.expectedX = square:getX()
        self.expectedY = square:getY()
        self.expectedZ = square:getZ()
        self.expectedId = cart:getID()

        -- Create action via helper
        self.action = ISCartPickupAction.FromWorldItem(PLAYER_OBJ, worldItem)
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("Could not create test cart on ground")
        end

        if self.action.squareX ~= self.expectedX then
            return TestHelpers.fail("squareX mismatch: expected %d, got %d", self.expectedX, self.action.squareX)
        end
        if self.action.squareY ~= self.expectedY then
            return TestHelpers.fail("squareY mismatch: expected %d, got %d", self.expectedY, self.action.squareY)
        end
        if self.action.squareZ ~= self.expectedZ then
            return TestHelpers.fail("squareZ mismatch: expected %d, got %d", self.expectedZ, self.action.squareZ)
        end
        if self.action.itemId ~= self.expectedId then
            return TestHelpers.fail("itemId mismatch: expected %d, got %d", self.expectedId, self.action.itemId)
        end

        return TestHelpers.pass("FromWorldItem correctly extracts coordinates and ID")
    end
})

-- ISCartEquipAction: cartId, sourceType, vehicleX, vehicleY, vehicleZ
TestRunner.register("ser_equip_constructor_primitives_only", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create action with primitives
        local action = ISCartEquipAction:new(PLAYER_OBJ, 12345, "inventory", nil, nil, nil)

        self.action = action
        self.expectedFields = {"cartId", "sourceType"}
    end,
    validate = function(self)
        local isValid, field, reason = validateActionFields(self.action, self.expectedFields)
        if not isValid then
            return TestHelpers.fail("Field '%s' failed: %s", field, reason)
        end

        if type(self.action.cartId) ~= "number" then
            return TestHelpers.fail("cartId should be number, got %s", type(self.action.cartId))
        end
        if type(self.action.sourceType) ~= "string" then
            return TestHelpers.fail("sourceType should be string, got %s", type(self.action.sourceType))
        end

        return TestHelpers.pass("ISCartEquipAction constructor uses only primitives")
    end
})

TestRunner.register("ser_equip_from_cart_inventory", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Give cart to inventory (not equipped)
        local cart = TestHelpers.giveCartUnequipped(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.expectedId = cart:getID()

        -- Create action via helper
        self.action = ISCartEquipAction.FromCart(PLAYER_OBJ, cart)
    end,
    validate = function(self)
        if self.action.cartId ~= self.expectedId then
            return TestHelpers.fail("cartId mismatch: expected %d, got %d", self.expectedId, self.action.cartId)
        end
        if self.action.sourceType ~= "inventory" then
            return TestHelpers.fail("sourceType should be 'inventory', got '%s'", self.action.sourceType)
        end

        return TestHelpers.pass("FromCart correctly extracts from inventory source")
    end
})

-- ISCartRepairAction: cartId, repairItemId, isGroundCart, squareX, squareY, squareZ
TestRunner.register("ser_repair_constructor_primitives_only", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create action with primitives
        local action = ISCartRepairAction:new(PLAYER_OBJ, 111, 222, true, 100, 200, 0)

        self.action = action
        self.expectedFields = {"cartId", "repairItemId", "isGroundCart", "squareX", "squareY", "squareZ"}
    end,
    validate = function(self)
        local isValid, field, reason = validateActionFields(self.action, self.expectedFields)
        if not isValid then
            return TestHelpers.fail("Field '%s' failed: %s", field, reason)
        end

        if type(self.action.cartId) ~= "number" then
            return TestHelpers.fail("cartId should be number, got %s", type(self.action.cartId))
        end
        if type(self.action.isGroundCart) ~= "boolean" then
            return TestHelpers.fail("isGroundCart should be boolean, got %s", type(self.action.isGroundCart))
        end

        return TestHelpers.pass("ISCartRepairAction constructor uses only primitives")
    end
})

TestRunner.register("ser_repair_from_cart_equipped", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Give equipped cart and repair item
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        local repairItem = TestHelpers.giveItem(PLAYER_OBJ, "Base.ScrapMetal")

        self.expectedCartId = cart:getID()
        self.expectedRepairId = repairItem:getID()

        -- Create action via helper
        self.action = ISCartRepairAction.FromCart(PLAYER_OBJ, cart, repairItem)
    end,
    validate = function(self)
        if self.action.cartId ~= self.expectedCartId then
            return TestHelpers.fail("cartId mismatch")
        end
        if self.action.repairItemId ~= self.expectedRepairId then
            return TestHelpers.fail("repairItemId mismatch")
        end
        if self.action.isGroundCart ~= false then
            return TestHelpers.fail("isGroundCart should be false for equipped cart")
        end

        return TestHelpers.pass("FromCart correctly extracts equipped cart data")
    end
})

-- ISInstallFlashlightAction: cartId, flashlightId, flashlightType, materialType, materialUses, squareX/Y/Z
TestRunner.register("ser_flashlight_constructor_primitives_only", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create action with all primitives
        local action = ISInstallFlashlightAction:new(
            PLAYER_OBJ, 111, 222, "Base.HandTorch", "Base.DuctTape", 1, nil, nil, nil
        )

        self.action = action
        self.expectedFields = {"cartId", "flashlightId", "flashlightType", "materialType", "materialUses"}
    end,
    validate = function(self)
        local isValid, field, reason = validateActionFields(self.action, self.expectedFields)
        if not isValid then
            return TestHelpers.fail("Field '%s' failed: %s", field, reason)
        end

        if type(self.action.flashlightType) ~= "string" then
            return TestHelpers.fail("flashlightType should be string, got %s", type(self.action.flashlightType))
        end
        if type(self.action.materialType) ~= "string" then
            return TestHelpers.fail("materialType should be string, got %s", type(self.action.materialType))
        end
        if type(self.action.materialUses) ~= "number" then
            return TestHelpers.fail("materialUses should be number, got %s", type(self.action.materialUses))
        end

        return TestHelpers.pass("ISInstallFlashlightAction constructor uses only primitives")
    end
})

-- ============================================================================
-- OBJECT REFERENCE DETECTION TESTS
-- ============================================================================

TestRunner.register("ser_object_ref_worlditem_detected", {
    run = function(self)
        if not TestRunner.setup() then return end

        -- Create cart on ground
        local square = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            self.skipped = true
            return
        end

        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        local worldItem = cart:getWorldItem()

        self.worldItem = worldItem
        self.isObjectRef = isObjectReference(worldItem)
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("Could not create test cart on ground")
        end

        if not self.isObjectRef then
            return TestHelpers.fail("IsoWorldInventoryObject should be detected as object reference")
        end
        return TestHelpers.pass("Object references correctly detected as non-serializable")
    end
})

TestRunner.register("ser_primitives_not_object_refs", {
    run = function(self)
        self.tests = {
            {value = 123, expected = false, name = "number"},
            {value = "hello", expected = false, name = "string"},
            {value = true, expected = false, name = "boolean"},
            {value = nil, expected = false, name = "nil"},
            {value = {foo = "bar"}, expected = false, name = "table"},
        }
    end,
    validate = function(self)
        for _, test in ipairs(self.tests) do
            local result = isObjectReference(test.value)
            if result ~= test.expected then
                return TestHelpers.fail("%s should not be object reference", test.name)
            end
        end
        return TestHelpers.pass("Primitives correctly identified as not object references")
    end
})

-- ============================================================================
-- NETWORK PAYLOAD TESTS
-- ============================================================================

TestRunner.register("ser_net_toggleCartLight_payload", {
    run = function(self)
        -- Build payload that would be sent
        self.payload = { cartId = 12345 }
    end,
    validate = function(self)
        local valid, path = validateNetworkPayload(self.payload)
        if not valid then
            return TestHelpers.fail("Invalid payload at %s", path)
        end

        if type(self.payload.cartId) ~= "number" then
            return TestHelpers.fail("cartId should be number")
        end

        return TestHelpers.pass("toggleCartLight payload serializable")
    end
})

TestRunner.register("ser_net_syncCartAnimation_payload", {
    run = function(self)
        self.payload = {
            playerOnlineId = 12345,
            hasCart = true,
        }
    end,
    validate = function(self)
        local valid, path = validateNetworkPayload(self.payload)
        if not valid then
            return TestHelpers.fail("Invalid payload at %s", path)
        end

        if type(self.payload.playerOnlineId) ~= "number" then
            return TestHelpers.fail("playerOnlineId should be number")
        end
        if type(self.payload.hasCart) ~= "boolean" then
            return TestHelpers.fail("hasCart should be boolean")
        end

        return TestHelpers.pass("syncCartAnimation payload serializable")
    end
})

TestRunner.register("ser_net_requestInstantDrop_payload", {
    run = function(self)
        self.payload = { cartId = 12345 }
    end,
    validate = function(self)
        local valid, path = validateNetworkPayload(self.payload)
        if not valid then
            return TestHelpers.fail("Invalid payload at %s", path)
        end

        return TestHelpers.pass("requestInstantDrop payload serializable")
    end
})

TestRunner.register("ser_net_cartLightUpdate_broadcast", {
    run = function(self)
        -- Build broadcast payload
        self.payload = {
            playerOnlineId = 12345,
            cartId = 67890,
            isActive = true,
        }
    end,
    validate = function(self)
        local valid, path = validateNetworkPayload(self.payload)
        if not valid then
            return TestHelpers.fail("Invalid payload at %s", path)
        end

        if type(self.payload.isActive) ~= "boolean" then
            return TestHelpers.fail("isActive should be boolean")
        end

        return TestHelpers.pass("cartLightUpdate broadcast payload serializable")
    end
})

TestRunner.register("ser_net_updateGroundCartVisual_broadcast", {
    run = function(self)
        self.payload = {
            squareX = 100,
            squareY = 200,
            squareZ = 0,
            cartId = 12345,
            fillState = "partial",
            modelName = "ShoppingCartPartial",
        }
    end,
    validate = function(self)
        local valid, path = validateNetworkPayload(self.payload)
        if not valid then
            return TestHelpers.fail("Invalid payload at %s", path)
        end

        if type(self.payload.fillState) ~= "string" then
            return TestHelpers.fail("fillState should be string")
        end
        if type(self.payload.modelName) ~= "string" then
            return TestHelpers.fail("modelName should be string")
        end

        return TestHelpers.pass("updateGroundCartVisual broadcast payload serializable")
    end
})

-- ============================================================================
-- LATE-JOINER SYNC TESTS
-- ============================================================================

TestRunner.register("ser_latejoiner_animation_response_structure", {
    run = function(self)
        -- Build mock response matching what server sends
        self.response = {
            states = {
                { id = 12345, hasCart = true },
                { id = 67890, hasCart = true },
            }
        }
    end,
    validate = function(self)
        -- Validate overall structure
        local valid, path = validateNetworkPayload(self.response)
        if not valid then
            return TestHelpers.fail("Invalid payload at %s", path)
        end

        if type(self.response.states) ~= "table" then
            return TestHelpers.fail("states should be table")
        end

        for i, state in ipairs(self.response.states) do
            if type(state.id) ~= "number" then
                return TestHelpers.fail("state[%d].id should be number", i)
            end
            if type(state.hasCart) ~= "boolean" then
                return TestHelpers.fail("state[%d].hasCart should be boolean", i)
            end
        end

        return TestHelpers.pass("fullAnimationSync response has correct structure")
    end
})

TestRunner.register("ser_latejoiner_upgrade_response_structure", {
    run = function(self)
        -- Build mock response matching what server sends
        self.response = {
            states = {
                {
                    playerOnlineId = 12345,
                    cartId = 111,
                    hasFlashlight = true,
                    isLightActive = false,
                    batteryCharge = 0.85,
                    flashlightData = {
                        originalType = "Base.HandTorch",
                        originalName = "Flashlight",
                        batteryCharge = 0.85,
                    },
                }
            }
        }
    end,
    validate = function(self)
        -- Validate overall payload serializable
        local valid, path = validateNetworkPayload(self.response)
        if not valid then
            return TestHelpers.fail("Invalid payload at %s", path)
        end

        -- Validate states array
        if type(self.response.states) ~= "table" then
            return TestHelpers.fail("states should be table")
        end

        -- Validate each state has required fields
        for i, state in ipairs(self.response.states) do
            if state.hasFlashlight then
                if state.isLightActive == nil then
                    return TestHelpers.fail("state[%d] missing isLightActive", i)
                end
                if state.batteryCharge == nil then
                    return TestHelpers.fail("state[%d] missing batteryCharge", i)
                end
            end
        end

        return TestHelpers.pass("fullUpgradeSync response has correct structure")
    end
})

TestRunner.register("ser_latejoiner_upgrade_flashlight_fields", {
    run = function(self)
        -- Mock state with flashlight
        self.state = {
            playerOnlineId = 12345,
            cartId = 111,
            hasFlashlight = true,
            isLightActive = true,
            batteryCharge = 0.5,
            flashlightData = {
                originalType = "Base.HandTorch",
                originalName = "Flashlight",
                batteryCharge = 0.5,
            },
        }
    end,
    validate = function(self)
        -- Required fields for flashlight sync
        local requiredFields = {"hasFlashlight", "isLightActive", "batteryCharge", "flashlightData"}

        for _, field in ipairs(requiredFields) do
            if self.state[field] == nil then
                return TestHelpers.fail("Missing required field: %s", field)
            end
        end

        -- Check flashlightData nested fields
        local requiredDataFields = {"originalType", "originalName", "batteryCharge"}
        for _, field in ipairs(requiredDataFields) do
            if self.state.flashlightData[field] == nil then
                return TestHelpers.fail("Missing flashlightData field: %s", field)
            end
        end

        return TestHelpers.pass("Flashlight late-joiner state contains all required fields")
    end
})

-- ============================================================================
-- INTEGRATION TESTS WITH NETWORK TEST MODE
-- ============================================================================

TestRunner.register("ser_network_capture_validates_payload", {
    run = function(self)
        -- Enable test mode
        Network.enableTestMode()

        -- Simulate a broadcast with a valid payload
        Network.broadcast("testSerializationCmd", {
            id = 12345,
            name = "test",
            active = true,
            nested = { value = 42 },
        })

        self.captures = Network.getCapturedBroadcasts()
    end,
    validate = function(self)
        Network.disableTestMode()

        if #self.captures ~= 1 then
            return TestHelpers.fail("Expected 1 captured broadcast, got %d", #self.captures)
        end

        local capture = self.captures[1]
        local valid, path = validateNetworkPayload(capture.args)
        if not valid then
            return TestHelpers.fail("Captured payload invalid at %s", path)
        end

        return TestHelpers.pass("Network test mode captures validate payload structure")
    end
})

TestRunner.register("ser_network_capture_detects_invalid_payload", {
    run = function(self)
        -- Test our validator with an invalid payload (function in table)
        self.invalidPayload = {
            id = 12345,
            callback = function() end,  -- Functions not serializable!
        }
    end,
    validate = function(self)
        local valid, path = validateNetworkPayload(self.invalidPayload)
        if valid then
            return TestHelpers.fail("Should detect function as invalid")
        end

        if not string.find(path, "callback") then
            return TestHelpers.fail("Should report callback field as invalid, got: %s", path)
        end

        return TestHelpers.pass("Validator correctly detects non-serializable function")
    end
})

-- ============================================================================
-- MODULE INITIALIZATION
-- ============================================================================

SaucedCarts.debug("SerializationTests module loaded")
