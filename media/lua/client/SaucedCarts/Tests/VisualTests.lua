--[[
    SaucedCarts Visual State Tests
    PURPOSE: Tests for cart fill state calculation and model switching
    CONTEXT: client

    Carts display different models based on fill level:
    - empty (0-32% full)
    - partial (33-65% full)
    - full (66%+ full)
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/CartVisuals"
require "SaucedCarts/Tests/TestRunner"
require "SaucedCarts/Tests/TestHelpers"

local TestRunner = SaucedCarts.TestRunner
local TestHelpers = SaucedCarts.TestHelpers

-- ============================================================================
-- FILL STATE CALCULATION TESTS
-- ============================================================================

TestRunner.register("visual_fillState_empty", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create an empty cartokay the
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Calculate fill state (should be empty)
        self.fillState = SaucedCarts.calculateFillState(cart)

        TestHelpers.info("Empty cart fill state: %s", self.fillState)
    end,
    validate = function(self)
        if self.fillState ~= "empty" then
            return TestHelpers.fail("Expected 'empty', got '%s'", self.fillState)
        end
        return TestHelpers.pass("Empty cart correctly returns 'empty' state")
    end
})

TestRunner.register("visual_fillState_partial", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create a cart and fill to ~50% (partial range is 33-65%)
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        local container = cart:getItemContainer()
        local capacity = container:getCapacity()

        -- Add items until we're around 50% capacity
        -- Each Base.Plank weighs 3.0, so add enough to reach ~50% of capacity
        local targetWeight = capacity * 0.5
        local added = 0
        while container:getCapacityWeight() < targetWeight and added < 20 do
            container:AddItem("Base.Plank")
            added = added + 1
        end

        self.usedWeight = container:getCapacityWeight()
        self.capacity = capacity
        self.fillPercent = self.usedWeight / self.capacity

        -- Calculate fill state
        self.fillState = SaucedCarts.calculateFillState(cart)

        TestHelpers.info("Partial cart: %.1f/%.1f (%.0f%%) -> %s",
            self.usedWeight, self.capacity, self.fillPercent * 100, self.fillState)
    end,
    validate = function(self)
        -- Verify we're actually in partial range (33-65%)
        if self.fillPercent < 0.33 or self.fillPercent >= 0.66 then
            return TestHelpers.fail("Test setup error: fill %.0f%% not in partial range (33-65%%)",
                self.fillPercent * 100)
        end

        if self.fillState ~= "partial" then
            return TestHelpers.fail("Expected 'partial', got '%s' at %.0f%% fill",
                self.fillState, self.fillPercent * 100)
        end
        return TestHelpers.pass("Partially filled cart correctly returns 'partial' state")
    end
})

TestRunner.register("visual_fillState_full", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create a cart and fill to ~80% (full is 66%+)
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        local container = cart:getItemContainer()
        local capacity = container:getCapacity()

        -- Add items until we're around 80% capacity
        local targetWeight = capacity * 0.8
        local added = 0
        while container:getCapacityWeight() < targetWeight and added < 30 do
            container:AddItem("Base.Plank")
            added = added + 1
        end

        self.usedWeight = container:getCapacityWeight()
        self.capacity = capacity
        self.fillPercent = self.usedWeight / self.capacity

        -- Calculate fill state
        self.fillState = SaucedCarts.calculateFillState(cart)

        TestHelpers.info("Full cart: %.1f/%.1f (%.0f%%) -> %s",
            self.usedWeight, self.capacity, self.fillPercent * 100, self.fillState)
    end,
    validate = function(self)
        -- Verify we're actually in full range (66%+)
        if self.fillPercent < 0.66 then
            return TestHelpers.fail("Test setup error: fill %.0f%% not in full range (66%%+)",
                self.fillPercent * 100)
        end

        if self.fillState ~= "full" then
            return TestHelpers.fail("Expected 'full', got '%s' at %.0f%% fill",
                self.fillState, self.fillPercent * 100)
        end
        return TestHelpers.pass("Full cart correctly returns 'full' state")
    end
})

-- ============================================================================
-- MODEL NAME TESTS
-- ============================================================================

TestRunner.register("visual_modelName_matches_state", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Get model names for each state
        self.emptyModel = SaucedCarts.buildCartModelName(cart, "empty")
        self.partialModel = SaucedCarts.buildCartModelName(cart, "partial")
        self.fullModel = SaucedCarts.buildCartModelName(cart, "full")

        TestHelpers.info("Models: empty=%s, partial=%s, full=%s",
            self.emptyModel, self.partialModel, self.fullModel)
    end,
    validate = function(self)
        -- ShoppingCart should use the standard model names
        if self.emptyModel ~= "ShoppingCartModel" then
            return TestHelpers.fail("Expected 'ShoppingCartModel' for empty, got '%s'", self.emptyModel)
        end
        if self.partialModel ~= "ShoppingCartPartialModel" then
            return TestHelpers.fail("Expected 'ShoppingCartPartialModel' for partial, got '%s'", self.partialModel)
        end
        if self.fullModel ~= "ShoppingCartFullModel" then
            return TestHelpers.fail("Expected 'ShoppingCartFullModel' for full, got '%s'", self.fullModel)
        end
        return TestHelpers.pass("Model names correctly match fill states")
    end
})

-- ============================================================================
-- VISUAL UPDATE TESTS
-- ============================================================================

TestRunner.register("visual_update_changes_moddata", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create empty cart
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Manually set initial state (updateCartVisual won't set it if empty->empty)
        local modData = cart:getModData()
        modData.SaucedCarts_fillState = "empty"
        self.initialState = modData.SaucedCarts_fillState

        -- Fill cart to "full" level (66%+)
        local container = cart:getItemContainer()
        local capacity = container:getCapacity()
        local targetWeight = capacity * 0.8
        local added = 0
        while container:getCapacityWeight() < targetWeight and added < 30 do
            container:AddItem("Base.Plank")
            added = added + 1
        end

        -- Update visual - should detect change from empty to full
        self.changed = SaucedCarts.updateCartVisual(cart, PLAYER_OBJ)
        self.finalState = modData.SaucedCarts_fillState

        TestHelpers.info("Visual update: %s -> %s (changed=%s)",
            tostring(self.initialState), tostring(self.finalState), tostring(self.changed))
    end,
    validate = function(self)
        if self.initialState ~= "empty" then
            return TestHelpers.fail("Initial state should be 'empty', got '%s'", tostring(self.initialState))
        end
        if not self.changed then
            return TestHelpers.fail("updateCartVisual() should return true when state changes")
        end
        if self.finalState ~= "full" then
            return TestHelpers.fail("Final state should be 'full', got '%s'", tostring(self.finalState))
        end
        return TestHelpers.pass("Visual update correctly tracks state in ModData")
    end
})

TestRunner.register("visual_update_no_change_returns_false", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create empty cart
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Set initial state so first update will be a "no change"
        local modData = cart:getModData()
        modData.SaucedCarts_fillState = "empty"

        -- First update with empty cart should return false (already empty)
        self.firstUpdate = SaucedCarts.updateCartVisual(cart, PLAYER_OBJ)

        -- Second update should also return false
        self.secondUpdate = SaucedCarts.updateCartVisual(cart, PLAYER_OBJ)

        TestHelpers.info("First update=%s, second update=%s",
            tostring(self.firstUpdate), tostring(self.secondUpdate))
    end,
    validate = function(self)
        -- Both updates should return false (empty -> empty, no change)
        if self.firstUpdate then
            return TestHelpers.fail("First update should return false (empty->empty)")
        end
        if self.secondUpdate then
            return TestHelpers.fail("Second update should return false (no state change)")
        end
        return TestHelpers.pass("Repeated update correctly returns false when no change")
    end
})

TestRunner.register("visual_getVisualModels_returns_table", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        self.visualModels = SaucedCarts.getVisualModels(cart)
        self.modelType = type(self.visualModels)

        TestHelpers.info("getVisualModels returned type: %s", self.modelType)
    end,
    validate = function(self)
        if self.modelType ~= "table" then
            return TestHelpers.fail("Expected table, got %s", tostring(self.modelType))
        end
        if not self.visualModels.empty then
            return TestHelpers.fail("visualModels.empty is nil")
        end
        if not self.visualModels.partial then
            return TestHelpers.fail("visualModels.partial is nil")
        end
        if not self.visualModels.full then
            return TestHelpers.fail("visualModels.full is nil")
        end
        return TestHelpers.pass("getVisualModels() returns valid table with all states")
    end
})

-- ============================================================================
-- GROUND CART VISUAL TESTS
-- ============================================================================

TestRunner.register("visual_ground_fillState_empty", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Get clean test area
        local square, sx, sy, sz = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            TestHelpers.fail("Could not get test square")
            return
        end

        -- Store coordinates for validation
        self.squareX = sx
        self.squareY = sy
        self.squareZ = sz

        -- Spawn empty cart on ground
        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Set initial state to "full" so updateCartVisual detects a change to "empty"
        -- This forces applyModel() to be called, setting the correct model name
        local modData = cart:getModData()
        modData.SaucedCarts_fillState = "full"

        -- Apply visual update - will detect full -> empty change
        SaucedCarts.updateCartVisual(cart, PLAYER_OBJ)

        TestHelpers.info("Ground cart spawned at %d,%d,%d with ID %d", sx, sy, sz, self.cartId)
    end,
    validate = function(self)
        -- Re-find the cart on the ground
        local cart, worldItem = TestHelpers.findGroundCartOnSquare(
            self.squareX, self.squareY, self.squareZ, self.cartId)

        if not cart then
            return TestHelpers.fail("Cart not found on ground at %d,%d,%d",
                self.squareX, self.squareY, self.squareZ)
        end

        if not worldItem then
            return TestHelpers.fail("Cart has no world item (not on ground)")
        end

        -- Verify the world static model is the empty model
        local worldModel = cart:getWorldStaticModel()
        if worldModel ~= "ShoppingCartModel" then
            return TestHelpers.fail("Expected 'ShoppingCartModel', got '%s'", tostring(worldModel))
        end

        return TestHelpers.pass("Empty ground cart has correct world model: %s", worldModel)
    end
})

TestRunner.register("visual_ground_fillState_partial", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Get clean test area
        local square, sx, sy, sz = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            TestHelpers.fail("Could not get test square")
            return
        end

        -- Store coordinates for validation
        self.squareX = sx
        self.squareY = sy
        self.squareZ = sz

        -- Spawn cart on ground
        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        local container = cart:getItemContainer()
        local capacity = container:getCapacity()

        -- Add items until we're around 50% capacity (partial range is 33-65%)
        local targetWeight = capacity * 0.5
        local added = 0
        while container:getCapacityWeight() < targetWeight and added < 20 do
            container:AddItem("Base.Plank")
            added = added + 1
        end

        -- Apply visual update to set the model
        SaucedCarts.updateCartVisual(cart, PLAYER_OBJ)

        TestHelpers.info("Ground partial cart: added %d items at %d,%d,%d", added, sx, sy, sz)
    end,
    validate = function(self)
        -- Re-find the cart on the ground
        local cart, worldItem = TestHelpers.findGroundCartOnSquare(
            self.squareX, self.squareY, self.squareZ, self.cartId)

        if not cart then
            return TestHelpers.fail("Cart not found on ground at %d,%d,%d",
                self.squareX, self.squareY, self.squareZ)
        end

        if not worldItem then
            return TestHelpers.fail("Cart has no world item (not on ground)")
        end

        -- Verify the world static model is the partial model
        local worldModel = cart:getWorldStaticModel()
        if worldModel ~= "ShoppingCartPartialModel" then
            return TestHelpers.fail("Expected 'ShoppingCartPartialModel', got '%s'", tostring(worldModel))
        end

        return TestHelpers.pass("Partial ground cart has correct world model: %s", worldModel)
    end
})

TestRunner.register("visual_ground_fillState_full", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Get clean test area
        local square, sx, sy, sz = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            TestHelpers.fail("Could not get test square")
            return
        end

        -- Store coordinates for validation
        self.squareX = sx
        self.squareY = sy
        self.squareZ = sz

        -- Spawn cart on ground
        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        local container = cart:getItemContainer()
        local capacity = container:getCapacity()

        -- Add items until we're around 80% capacity (full is 66%+)
        local targetWeight = capacity * 0.8
        local added = 0
        while container:getCapacityWeight() < targetWeight and added < 30 do
            container:AddItem("Base.Plank")
            added = added + 1
        end

        -- Apply visual update to set the model
        SaucedCarts.updateCartVisual(cart, PLAYER_OBJ)

        TestHelpers.info("Ground full cart: added %d items at %d,%d,%d", added, sx, sy, sz)
    end,
    validate = function(self)
        -- Re-find the cart on the ground
        local cart, worldItem = TestHelpers.findGroundCartOnSquare(
            self.squareX, self.squareY, self.squareZ, self.cartId)

        if not cart then
            return TestHelpers.fail("Cart not found on ground at %d,%d,%d",
                self.squareX, self.squareY, self.squareZ)
        end

        if not worldItem then
            return TestHelpers.fail("Cart has no world item (not on ground)")
        end

        -- Verify the world static model is the full model
        local worldModel = cart:getWorldStaticModel()
        if worldModel ~= "ShoppingCartFullModel" then
            return TestHelpers.fail("Expected 'ShoppingCartFullModel', got '%s'", tostring(worldModel))
        end

        return TestHelpers.pass("Full ground cart has correct world model: %s", worldModel)
    end
})

TestRunner.register("visual_ground_update_changes_moddata", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Get clean test area
        local square, sx, sy, sz = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            TestHelpers.fail("Could not get test square")
            return
        end

        -- Store coordinates for validation
        self.squareX = sx
        self.squareY = sy
        self.squareZ = sz

        -- Spawn empty cart on ground
        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Manually set initial state
        local modData = cart:getModData()
        modData.SaucedCarts_fillState = "empty"

        -- Fill cart to "full" level (66%+)
        local container = cart:getItemContainer()
        local capacity = container:getCapacity()
        local targetWeight = capacity * 0.8
        local added = 0
        while container:getCapacityWeight() < targetWeight and added < 30 do
            container:AddItem("Base.Plank")
            added = added + 1
        end

        -- Update visual - should detect change from empty to full
        SaucedCarts.updateCartVisual(cart, PLAYER_OBJ)

        TestHelpers.info("Ground visual update: added %d items at %d,%d,%d", added, sx, sy, sz)
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Re-find the cart on the ground
        local cart, worldItem = TestHelpers.findGroundCartOnSquare(
            self.squareX, self.squareY, self.squareZ, self.cartId)

        if not cart then
            return TestHelpers.fail("Cart not found on ground at %d,%d,%d",
                self.squareX, self.squareY, self.squareZ)
        end

        if not worldItem then
            return TestHelpers.fail("Cart has no world item (not on ground)")
        end

        -- Check the ModData state
        local modData = cart:getModData()
        local fillState = modData.SaucedCarts_fillState

        if fillState ~= "full" then
            return TestHelpers.fail("ModData fill state should be 'full', got '%s'", tostring(fillState))
        end

        -- Also verify calculateFillState agrees
        local calculatedState = SaucedCarts.calculateFillState(cart)
        if calculatedState ~= "full" then
            return TestHelpers.fail("Calculated state should be 'full', got '%s'", tostring(calculatedState))
        end

        return TestHelpers.pass("Ground cart visual update correctly tracks state in ModData")
    end
})

TestRunner.register("visual_ground_has_world_item", {
    run = function(self)
        if not TestRunner.setup() then return end

        -- Get clean test area
        local square, sx, sy, sz = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            TestHelpers.fail("Could not get test square")
            return
        end

        -- Store coordinates for validation
        self.squareX = sx
        self.squareY = sy
        self.squareZ = sz

        -- Spawn cart on ground
        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        TestHelpers.info("Ground cart spawned at %d,%d,%d with ID %d", sx, sy, sz, self.cartId)
    end,
    validate = function(self)
        -- Re-find the cart on the ground
        local cart, worldItem = TestHelpers.findGroundCartOnSquare(
            self.squareX, self.squareY, self.squareZ, self.cartId)

        if not cart then
            return TestHelpers.fail("Cart not found on ground at %d,%d,%d",
                self.squareX, self.squareY, self.squareZ)
        end

        if not worldItem then
            return TestHelpers.fail("Ground cart should have a world item")
        end

        -- Verify the world item's square matches expected coordinates
        local worldSquare = worldItem:getSquare()
        if not worldSquare then
            return TestHelpers.fail("World item has no square")
        end

        local actualX, actualY, actualZ = worldSquare:getX(), worldSquare:getY(), worldSquare:getZ()
        if actualX ~= self.squareX or actualY ~= self.squareY or actualZ ~= self.squareZ then
            return TestHelpers.fail("World item at wrong location: expected %d,%d,%d got %d,%d,%d",
                self.squareX, self.squareY, self.squareZ, actualX, actualY, actualZ)
        end

        return TestHelpers.pass("Ground cart correctly has world item on expected square")
    end
})

return true
