--[[
    SaucedCarts Functional Tests
    PURPOSE: Tests that verify cart operations work correctly
    CONTEXT: client

    Tests basic functionality: equipping, content preservation, repair effects.
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Tests/TestRunner"
require "SaucedCarts/Tests/TestHelpers"
require "SaucedCarts/TimedActions/ISCartPickupAction"
require "SaucedCarts/TimedActions/ISCartRepairAction"

local TestRunner = SaucedCarts.TestRunner
local TestHelpers = SaucedCarts.TestHelpers

-- ============================================================================
-- FUNCTIONAL TESTS
-- ============================================================================

TestRunner.register("cart_pickup_equips_both_hands", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Get clean test area
        local square = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            TestHelpers.fail("Could not get test square")
            return
        end

        -- Spawn cart
        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        TestHelpers.info("Testing pickup equips both hands, cart ID %d", self.cartId)

        -- Walk to cart and queue pickup
        luautils.walkAdj(PLAYER_OBJ, square)
        local worldItem = cart:getWorldItem()
        if worldItem then
            ISTimedActionQueue.add(ISCartPickupAction.FromWorldItem(PLAYER_OBJ, worldItem))
        end
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()
        local primary = PLAYER_OBJ:getPrimaryHandItem()
        local secondary = PLAYER_OBJ:getSecondaryHandItem()

        if not primary then
            return TestHelpers.fail("Nothing in primary hand")
        end
        if primary:getID() ~= self.cartId then
            return TestHelpers.fail("Wrong item in primary hand (ID %d, expected %d)", primary:getID(), self.cartId)
        end
        if primary ~= secondary then
            return TestHelpers.fail("Cart not in both hands (primary ~= secondary)")
        end
        return TestHelpers.pass("Cart equipped in both hands")
    end
})

TestRunner.register("cart_pickup_preserves_contents", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Get clean test area
        local square = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            TestHelpers.fail("Could not get test square")
            return
        end

        -- Spawn cart with items inside
        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        local container = cart:getItemContainer()
        container:AddItem("Base.Axe")
        container:AddItem("Base.Hammer")
        container:AddItem("Base.Screwdriver")

        self.cartId = cart:getID()
        self.itemCount = container:getItems():size()

        TestHelpers.info("Cart has %d items, testing pickup preserves contents", self.itemCount)

        -- Walk to cart and queue pickup
        luautils.walkAdj(PLAYER_OBJ, square)
        local worldItem = cart:getWorldItem()
        if worldItem then
            ISTimedActionQueue.add(ISCartPickupAction.FromWorldItem(PLAYER_OBJ, worldItem))
        end
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()
        local held = PLAYER_OBJ:getPrimaryHandItem()
        if not held then
            return TestHelpers.fail("No cart in hands")
        end

        local container = held:getItemContainer()
        if not container then
            return TestHelpers.fail("Cart has no container")
        end

        local count = container:getItems():size()
        if count ~= self.itemCount then
            return TestHelpers.fail("Items lost! Before: %d, After: %d", self.itemCount, count)
        end
        return TestHelpers.pass("Contents preserved: %d items", count)
    end
})

TestRunner.register("cart_repair_increases_condition", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Get clean test area
        local square, sx, sy, sz = TestHelpers.getCleanSquare(2, 2, 0)
        if not square then
            TestHelpers.fail("Could not get test square")
            return
        end

        -- Spawn damaged cart
        local cart = TestHelpers.spawnCart(square, "SaucedCarts.ShoppingCart")
        cart:setCondition(50)
        self.conditionBefore = cart:getCondition()
        self.cartId = cart:getID()

        -- Give player repair material
        local repairItem = TestHelpers.giveItem(PLAYER_OBJ, "Base.ScrapMetal")
        self.repairItemId = repairItem:getID()

        TestHelpers.info("Cart condition: %d, testing repair increases it", self.conditionBefore)

        -- Walk to cart and queue repair
        luautils.walkAdj(PLAYER_OBJ, square)
        ISTimedActionQueue.add(ISCartRepairAction:new(
            PLAYER_OBJ,
            self.cartId,
            self.repairItemId,
            true,  -- isGroundCart
            sx, sy, sz
        ))
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 10)
        if not cart then
            return TestHelpers.fail("Cart not found after repair")
        end

        local conditionAfter = cart:getCondition()
        if conditionAfter <= self.conditionBefore then
            return TestHelpers.fail("Condition not increased: %d -> %d", self.conditionBefore, conditionAfter)
        end
        return TestHelpers.pass("Condition increased: %d -> %d", self.conditionBefore, conditionAfter)
    end
})

return true
