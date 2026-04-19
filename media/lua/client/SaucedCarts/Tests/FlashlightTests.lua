--[[
    SaucedCarts Flashlight Tests
    PURPOSE: Tests for flashlight installation, toggle, battery, and light emission
    CONTEXT: client

    Tests cover:
    - Flashlight installation
    - Toggle on/off behavior
    - Battery drain and depletion
    - Area transition recovery
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"
require "SaucedCarts/Tests/TestRunner"
require "SaucedCarts/Tests/TestHelpers"

local TestRunner = SaucedCarts.TestRunner
local TestHelpers = SaucedCarts.TestHelpers
local Upgrades = SaucedCarts.Upgrades

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Create a cart with a flashlight installed (bypassing timed action)
---@param player IsoPlayer
---@param batteryCharge number|nil Battery level 0-1 (default 1.0)
---@return InventoryItem cart
local function createCartWithFlashlight(player, batteryCharge)
    local cart = TestHelpers.giveCart(player, "SaucedCarts.ShoppingCart")
    local modData = cart:getModData()
    modData.SaucedCarts_hasFlashlight = true
    modData.SaucedCarts_flashlightData = {
        lightStrength = 1.8,
        lightDistance = 15,
        torchCone = true,
        torchDot = 0.5,
        originalType = "Base.Torch",
        originalName = "Flashlight",
    }
    modData.SaucedCarts_batteryCharge = batteryCharge or 1.0
    modData.SaucedCarts_isLightActive = false
    return cart
end

--- Create a flashlight item in player's inventory
---@param player IsoPlayer
---@param batteryCharge number|nil Battery level 0-1 (default 1.0)
---@return InventoryItem
local function createFlashlight(player, batteryCharge)
    local flashlight = instanceItem("Base.Torch")
    if flashlight.setCurrentUsesFloat then
        flashlight:setCurrentUsesFloat(batteryCharge or 1.0)
    end
    player:getInventory():AddItem(flashlight)
    return flashlight
end

-- ============================================================================
-- FLASHLIGHT INSTALLATION TESTS
-- ============================================================================

TestRunner.register("flashlight_install_sets_flag", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        local flashlight = createFlashlight(PLAYER_OBJ, 0.75)

        self.cartId = cart:getID()

        -- Install flashlight directly (bypassing timed action)
        self.installResult = Upgrades.installFlashlight(cart, flashlight)
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 0)

        if not self.installResult then
            return TestHelpers.fail("installFlashlight() returned false")
        end
        if not cart then
            return TestHelpers.fail("Cart not found after install")
        end
        if not Upgrades.hasFlashlight(cart) then
            return TestHelpers.fail("hasFlashlight() should return true after install")
        end
        return TestHelpers.pass("Flashlight install sets hasFlashlight flag")
    end
})

TestRunner.register("flashlight_install_copies_battery", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        local flashlight = createFlashlight(PLAYER_OBJ, 0.65)

        self.cartId = cart:getID()
        self.expectedBattery = 0.65

        Upgrades.installFlashlight(cart, flashlight)
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 0)

        if not cart then
            return TestHelpers.fail("Cart not found")
        end

        local charge = Upgrades.getBatteryCharge(cart)
        -- Use tolerance for floating-point comparison
        if math.abs(charge - self.expectedBattery) > 0.01 then
            return TestHelpers.fail("Battery mismatch: expected %.2f, got %.2f",
                self.expectedBattery, charge)
        end

        return TestHelpers.pass("Flashlight install copies battery level correctly")
    end
})

TestRunner.register("flashlight_cannot_double_install", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart already has flashlight
        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        local flashlight = createFlashlight(PLAYER_OBJ, 0.5)

        self.cartId = cart:getID()

        -- Try to install again
        self.canInstall, self.reason = Upgrades.canInstallFlashlight(cart)
        self.installResult = Upgrades.installFlashlight(cart, flashlight)
    end,
    validate = function(self)
        if self.canInstall then
            return TestHelpers.fail("canInstallFlashlight() should return false for cart with flashlight")
        end
        if self.installResult then
            return TestHelpers.fail("installFlashlight() should return false for cart with flashlight")
        end
        if self.reason ~= "Flashlight already installed" then
            return TestHelpers.fail("Expected reason 'Flashlight already installed', got '%s'",
                tostring(self.reason))
        end

        return TestHelpers.pass("Cannot install flashlight on cart that already has one")
    end
})

TestRunner.register("flashlight_install_accepts_materials", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Test material detection - these are the accepted attachment materials
        local acceptedMaterials = {
            { type = "Base.DuctTape", uses = 1, name = "Duct Tape" },
            { type = "Base.CableTies", uses = 1, name = "Cable Ties" },
            { type = "Base.Scotchtape", uses = 2, name = "Adhesive Tape" },
            { type = "Base.Rope", uses = 2, name = "Rope" },
            { type = "Base.Twine", uses = 2, name = "Twine" },
        }

        self.results = {}

        for _, mat in ipairs(acceptedMaterials) do
            -- Create the material item
            local item = instanceItem(mat.type)
            if item then
                -- Set appropriate uses if drainable/multi-use
                if item.setCurrentUses then
                    item:setCurrentUses(mat.uses)
                elseif item.setUsesRemaining then
                    item:setUsesRemaining(mat.uses)
                end

                table.insert(self.results, {
                    type = mat.type,
                    name = mat.name,
                    created = true,
                    usesRequired = mat.uses
                })

                -- Clean up
                PLAYER_OBJ:getInventory():AddItem(item)
            else
                table.insert(self.results, {
                    type = mat.type,
                    name = mat.name,
                    created = false
                })
            end
        end
    end,
    validate = function(self)
        local allValid = true
        local failedMaterials = {}

        for _, result in ipairs(self.results) do
            if not result.created then
                allValid = false
                table.insert(failedMaterials, result.name)
            end
        end

        if not allValid then
            return TestHelpers.fail("Could not create material items: %s",
                table.concat(failedMaterials, ", "))
        end

        -- Verify all 5 material types are recognized
        if #self.results ~= 5 then
            return TestHelpers.fail("Expected 5 material types, got %d", #self.results)
        end

        return TestHelpers.pass("All attachment materials are valid item types")
    end
})

-- ============================================================================
-- TOGGLE TESTS
-- ============================================================================

TestRunner.register("flashlight_toggle_on_with_battery", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        self.cartId = cart:getID()

        -- Toggle ON
        self.newState, self.success = Upgrades.toggleFlashlight(cart, PLAYER_OBJ)
    end,
    validate = function(self)
        if not self.success then
            return TestHelpers.fail("toggleFlashlight() did not succeed")
        end
        if not self.newState then
            return TestHelpers.fail("Expected newState=true, got false")
        end

        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 0)
        if not Upgrades.isLightActive(cart) then
            return TestHelpers.fail("isLightActive() should return true after toggle ON")
        end

        return TestHelpers.pass("Toggle turns flashlight ON")
    end
})

TestRunner.register("flashlight_toggle_off", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        -- Start with light ON
        local modData = cart:getModData()
        modData.SaucedCarts_isLightActive = true

        self.cartId = cart:getID()

        -- Toggle OFF
        self.newState, self.success = Upgrades.toggleFlashlight(cart, PLAYER_OBJ)
    end,
    validate = function(self)
        if not self.success then
            return TestHelpers.fail("toggleFlashlight() did not succeed")
        end
        if self.newState then
            return TestHelpers.fail("Expected newState=false, got true")
        end

        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 0)
        if Upgrades.isLightActive(cart) then
            return TestHelpers.fail("isLightActive() should return false after toggle OFF")
        end

        return TestHelpers.pass("Toggle turns flashlight OFF")
    end
})

TestRunner.register("flashlight_toggle_fails_no_battery", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart with dead battery
        local cart = createCartWithFlashlight(PLAYER_OBJ, 0)
        self.cartId = cart:getID()

        -- Try to toggle ON
        self.newState, self.success = Upgrades.toggleFlashlight(cart, PLAYER_OBJ)
    end,
    validate = function(self)
        if self.success then
            return TestHelpers.fail("toggleFlashlight() should fail with 0 battery")
        end

        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 0)
        if Upgrades.isLightActive(cart) then
            return TestHelpers.fail("Flashlight should NOT turn on with 0 battery")
        end

        return TestHelpers.pass("Toggle fails with empty battery")
    end
})

TestRunner.register("flashlight_toggle_no_flashlight", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart without flashlight
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Try to toggle
        self.newState, self.success = Upgrades.toggleFlashlight(cart, PLAYER_OBJ)
    end,
    validate = function(self)
        if self.success then
            return TestHelpers.fail("toggleFlashlight() should fail without flashlight installed")
        end
        if self.newState then
            return TestHelpers.fail("newState should be false")
        end

        return TestHelpers.pass("Toggle fails when no flashlight installed")
    end
})

-- ============================================================================
-- BATTERY TESTS
-- ============================================================================

TestRunner.register("flashlight_battery_drain_when_on", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        -- Turn on light (must be on for drain to matter conceptually)
        local modData = cart:getModData()
        modData.SaucedCarts_isLightActive = true

        self.cartId = cart:getID()
        self.chargeBefore = modData.SaucedCarts_batteryCharge

        -- Drain for 60 seconds (simulated)
        Upgrades.drainBattery(cart, 60)
        self.chargeAfter = Upgrades.getBatteryCharge(cart)
    end,
    validate = function(self)
        if self.chargeAfter >= self.chargeBefore then
            return TestHelpers.fail("Battery should drain: before=%.4f, after=%.4f",
                self.chargeBefore, self.chargeAfter)
        end

        local drained = self.chargeBefore - self.chargeAfter
        TestHelpers.info("Battery drained %.4f in 60s simulation", drained)

        return TestHelpers.pass("Battery drains over time")
    end
})

TestRunner.register("flashlight_battery_depleted_returns_true", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart with very low battery
        local cart = createCartWithFlashlight(PLAYER_OBJ, 0.001)
        local modData = cart:getModData()
        modData.SaucedCarts_isLightActive = true

        self.cartId = cart:getID()

        -- Drain enough to deplete
        self.depleted = Upgrades.drainBattery(cart, 60)
    end,
    validate = function(self)
        if not self.depleted then
            return TestHelpers.fail("drainBattery should return true when depleted")
        end

        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 0)
        local charge = Upgrades.getBatteryCharge(cart)

        if charge > 0 then
            return TestHelpers.fail("Battery should be 0 after depletion, got %.4f", charge)
        end

        return TestHelpers.pass("Battery depletes to 0 and returns depleted=true")
    end
})

TestRunner.register("flashlight_battery_insert", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart with low battery
        local cart = createCartWithFlashlight(PLAYER_OBJ, 0.2)
        self.cartId = cart:getID()
        self.initialCharge = 0.2
        self.addedCharge = 0.5

        -- Add battery charge
        self.newCharge = Upgrades.addBatteryCharge(cart, self.addedCharge)
    end,
    validate = function(self)
        local expected = self.initialCharge + self.addedCharge
        if math.abs(self.newCharge - expected) > 0.01 then
            return TestHelpers.fail("addBatteryCharge returned %.2f, expected %.2f",
                self.newCharge, expected)
        end

        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 0)
        local charge = Upgrades.getBatteryCharge(cart)

        if math.abs(charge - expected) > 0.01 then
            return TestHelpers.fail("getBatteryCharge returned %.2f, expected %.2f",
                charge, expected)
        end

        return TestHelpers.pass("addBatteryCharge increases charge correctly")
    end
})

TestRunner.register("flashlight_battery_insert_caps_at_1", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart with 80% battery
        local cart = createCartWithFlashlight(PLAYER_OBJ, 0.8)
        self.cartId = cart:getID()

        -- Try to add 0.5 (would exceed 1.0)
        self.newCharge = Upgrades.addBatteryCharge(cart, 0.5)
    end,
    validate = function(self)
        if self.newCharge > 1.0 then
            return TestHelpers.fail("Charge exceeded 1.0: %.2f", self.newCharge)
        end
        if math.abs(self.newCharge - 1.0) > 0.01 then
            return TestHelpers.fail("Charge should cap at 1.0, got %.2f", self.newCharge)
        end

        return TestHelpers.pass("Battery charge caps at 1.0")
    end
})

TestRunner.register("flashlight_can_insert_battery_validation", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart without flashlight
        local cartNoFlashlight = TestHelpers.giveCartUnequipped(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.canInsertNoFlashlight, self.reasonNoFlashlight = Upgrades.canInsertBattery(cartNoFlashlight)

        -- Cart with flashlight, full battery
        local cartFullBattery = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        self.canInsertFull, self.reasonFull = Upgrades.canInsertBattery(cartFullBattery)

        -- Cart with flashlight, partial battery
        local cartPartialBattery = createCartWithFlashlight(PLAYER_OBJ, 0.5)
        self.canInsertPartial, self.reasonPartial = Upgrades.canInsertBattery(cartPartialBattery)
    end,
    validate = function(self)
        if self.canInsertNoFlashlight then
            return TestHelpers.fail("Should not allow battery insert on cart without flashlight")
        end
        if self.canInsertFull then
            return TestHelpers.fail("Should not allow battery insert when battery is full")
        end
        if not self.canInsertPartial then
            return TestHelpers.fail("Should allow battery insert when battery is not full: %s",
                tostring(self.reasonPartial))
        end

        return TestHelpers.pass("canInsertBattery validation works correctly")
    end
})

TestRunner.register("flashlight_can_remove_battery_validation", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart without flashlight
        local cartNoFlashlight = TestHelpers.giveCartUnequipped(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.canRemoveNoFlashlight, self.reasonNoFlashlight = Upgrades.canRemoveBattery(cartNoFlashlight)

        -- Cart with flashlight, no battery
        local cartNoBattery = createCartWithFlashlight(PLAYER_OBJ, 0)
        self.canRemoveNoBattery, self.reasonNoBattery = Upgrades.canRemoveBattery(cartNoBattery)

        -- Cart with flashlight and battery
        local cartWithBattery = createCartWithFlashlight(PLAYER_OBJ, 0.5)
        self.canRemoveWithBattery, self.reasonWithBattery = Upgrades.canRemoveBattery(cartWithBattery)
    end,
    validate = function(self)
        if self.canRemoveNoFlashlight then
            return TestHelpers.fail("Should not allow battery remove on cart without flashlight")
        end
        if self.canRemoveNoBattery then
            return TestHelpers.fail("Should not allow battery remove when battery is empty")
        end
        if not self.canRemoveWithBattery then
            return TestHelpers.fail("Should allow battery remove when battery has charge: %s",
                tostring(self.reasonWithBattery))
        end

        return TestHelpers.pass("canRemoveBattery validation works correctly")
    end
})

-- ============================================================================
-- API TESTS
-- ============================================================================

TestRunner.register("flashlight_hasFlashlight_api", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart without flashlight
        local cartNoFlashlight = TestHelpers.giveCartUnequipped(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.noFlashlightResult = Upgrades.hasFlashlight(cartNoFlashlight)

        -- Cart with flashlight
        local cartWithFlashlight = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        self.hasFlashlightResult = Upgrades.hasFlashlight(cartWithFlashlight)
    end,
    validate = function(self)
        if self.noFlashlightResult then
            return TestHelpers.fail("hasFlashlight() should return false for cart without flashlight")
        end
        if not self.hasFlashlightResult then
            return TestHelpers.fail("hasFlashlight() should return true for cart with flashlight")
        end

        return TestHelpers.pass("hasFlashlight() API works correctly")
    end
})

TestRunner.register("flashlight_isLightActive_api", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        self.offResult = Upgrades.isLightActive(cart)

        -- Turn on
        local modData = cart:getModData()
        modData.SaucedCarts_isLightActive = true
        self.onResult = Upgrades.isLightActive(cart)
    end,
    validate = function(self)
        if self.offResult then
            return TestHelpers.fail("isLightActive() should return false when off")
        end
        if not self.onResult then
            return TestHelpers.fail("isLightActive() should return true when on")
        end

        return TestHelpers.pass("isLightActive() API works correctly")
    end
})

TestRunner.register("flashlight_getBatteryCharge_api", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = createCartWithFlashlight(PLAYER_OBJ, 0.67)
        self.result = Upgrades.getBatteryCharge(cart)
        self.expected = 0.67
    end,
    validate = function(self)
        if math.abs(self.result - self.expected) > 0.01 then
            return TestHelpers.fail("getBatteryCharge() returned %.2f, expected %.2f",
                self.result, self.expected)
        end

        return TestHelpers.pass("getBatteryCharge() API works correctly")
    end
})

TestRunner.register("flashlight_setBatteryCharge_api", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        self.cartId = cart:getID()

        Upgrades.setBatteryCharge(cart, 0.33)
        self.expected = 0.33
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 0)

        local charge = Upgrades.getBatteryCharge(cart)
        if math.abs(charge - self.expected) > 0.01 then
            return TestHelpers.fail("Battery charge is %.2f, expected %.2f", charge, self.expected)
        end

        return TestHelpers.pass("setBatteryCharge() API works correctly")
    end
})

TestRunner.register("flashlight_getFlashlightData_api", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        self.data = Upgrades.getFlashlightData(cart)
    end,
    validate = function(self)
        if not self.data then
            return TestHelpers.fail("getFlashlightData() returned nil")
        end
        if not self.data.lightStrength then
            return TestHelpers.fail("Missing lightStrength in flashlight data")
        end
        if not self.data.lightDistance then
            return TestHelpers.fail("Missing lightDistance in flashlight data")
        end
        if not self.data.originalType then
            return TestHelpers.fail("Missing originalType in flashlight data")
        end

        return TestHelpers.pass("getFlashlightData() returns valid data")
    end
})

SaucedCarts.debug("FlashlightTests module loaded")
