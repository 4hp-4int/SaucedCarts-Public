--[[
    SaucedCarts Orphan Recovery Tests
    PURPOSE: Tests for orphan cart detection, marking, and item recovery
    CONTEXT: client

    Orphan carts are carts whose type is no longer registered (addon removed).
    These tests verify the detection and recovery systems work correctly.
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Migration"
require "SaucedCarts/Tests/TestRunner"
require "SaucedCarts/Tests/TestHelpers"

local TestRunner = SaucedCarts.TestRunner
local TestHelpers = SaucedCarts.TestHelpers

-- ============================================================================
-- ORPHAN DETECTION TESTS
-- ============================================================================

TestRunner.register("orphan_mark_and_detect", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Give player a registered cart
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Verify it's NOT an orphan initially
        self.wasOrphanBefore = SaucedCarts.Migration.isOrphan(cart)

        -- Mark it as orphan (simulates addon removal)
        SaucedCarts.Migration.markAsOrphan(cart)

        -- Check if it's now detected as orphan
        self.isOrphanAfter = SaucedCarts.Migration.isOrphan(cart)

        TestHelpers.info("Testing orphan mark/detect, cart ID %d", self.cartId)
    end,
    validate = function(self)
        if self.wasOrphanBefore then
            return TestHelpers.fail("Cart was already orphan before marking")
        end
        if not self.isOrphanAfter then
            return TestHelpers.fail("Cart not detected as orphan after marking")
        end
        return TestHelpers.pass("markAsOrphan() and isOrphan() work correctly")
    end
})

TestRunner.register("orphan_clear_status", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Give player a cart and mark as orphan
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        SaucedCarts.Migration.markAsOrphan(cart)
        self.wasOrphanAfterMark = SaucedCarts.Migration.isOrphan(cart)

        -- Clear orphan status
        SaucedCarts.Migration.clearOrphanStatus(cart)
        self.isOrphanAfterClear = SaucedCarts.Migration.isOrphan(cart)

        TestHelpers.info("Testing orphan clear, cart ID %d", self.cartId)
    end,
    validate = function(self)
        if not self.wasOrphanAfterMark then
            return TestHelpers.fail("Cart not marked as orphan")
        end
        if self.isOrphanAfterClear then
            return TestHelpers.fail("Orphan status not cleared")
        end
        return TestHelpers.pass("clearOrphanStatus() works correctly")
    end
})

-- ============================================================================
-- ORPHAN RECOVERY TESTS
-- ============================================================================

TestRunner.register("orphan_recovery_transfers_items", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Give player a cart with items inside
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Add items to cart
        local container = cart:getItemContainer()
        container:AddItem("Base.Axe")
        container:AddItem("Base.Hammer")
        container:AddItem("Base.Screwdriver")
        self.itemCountBefore = container:getItems():size()

        -- Mark as orphan
        SaucedCarts.Migration.markAsOrphan(cart)

        -- Count player inventory items before recovery (excluding the cart)
        local invBefore = PLAYER_OBJ:getInventory():getItems():size()
        self.invCountBefore = invBefore - 1  -- Subtract the cart itself

        TestHelpers.info("Orphan cart has %d items, testing recovery", self.itemCountBefore)

        -- Perform recovery
        local success, result = SaucedCarts.Migration.recoverOrphanCart(cart, PLAYER_OBJ)
        self.recoverySuccess = success
        self.recoveredCount = result
    end,
    validate = function(self)
        if not self.recoverySuccess then
            return TestHelpers.fail("Recovery failed: %s", tostring(self.recoveredCount))
        end

        if self.recoveredCount ~= self.itemCountBefore then
            return TestHelpers.fail("Wrong item count recovered: expected %d, got %d",
                self.itemCountBefore, self.recoveredCount)
        end

        -- Count player inventory now
        local PLAYER_OBJ = TestRunner.getPlayer()
        local invAfter = PLAYER_OBJ:getInventory():getItems():size()

        -- Should have: original items + recovered items (cart was removed)
        local expectedCount = self.invCountBefore + self.itemCountBefore
        if invAfter ~= expectedCount then
            return TestHelpers.fail("Inventory count wrong: expected %d, got %d", expectedCount, invAfter)
        end

        return TestHelpers.pass("Recovered %d items from orphan cart", self.recoveredCount)
    end
})

TestRunner.register("orphan_recovery_removes_cart", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Give player a cart
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()

        -- Mark as orphan
        SaucedCarts.Migration.markAsOrphan(cart)

        TestHelpers.info("Testing orphan cart removal after recovery, ID %d", self.cartId)

        -- Perform recovery
        SaucedCarts.Migration.recoverOrphanCart(cart, PLAYER_OBJ)
    end,
    validate = function(self)
        -- Check that cart with our ID is no longer in inventory
        local PLAYER_OBJ = TestRunner.getPlayer()
        local inv = PLAYER_OBJ:getInventory()
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:getID() == self.cartId then
                return TestHelpers.fail("Orphan cart still in inventory after recovery")
            end
        end

        return TestHelpers.pass("Orphan cart removed after recovery")
    end
})

-- ============================================================================
-- LOOKS LIKE CART DETECTION TESTS
-- ============================================================================

TestRunner.register("orphan_looksLikeCart_prefix", {
    run = function(self)
        if not TestRunner.setup() then return end

        -- Create a SaucedCarts item (should be detected)
        local cart = instanceItem("SaucedCarts.ShoppingCart")
        self.cartResult = SaucedCarts.Migration.looksLikeCart(cart)

        -- Create a non-cart container item (should NOT be detected)
        local bag = instanceItem("Base.Bag_BigHikingBag")
        self.bagResult = SaucedCarts.Migration.looksLikeCart(bag)

        TestHelpers.info("Testing looksLikeCart() prefix detection")
    end,
    validate = function(self)
        if not self.cartResult then
            return TestHelpers.fail("SaucedCarts.ShoppingCart not detected by looksLikeCart()")
        end
        if self.bagResult then
            return TestHelpers.fail("Base.Bag_BigHikingBag incorrectly detected as cart")
        end
        return TestHelpers.pass("looksLikeCart() correctly detects SaucedCarts prefix")
    end
})

TestRunner.register("orphan_looksLikeCart_moddata", {
    run = function(self)
        if not TestRunner.setup() then return end

        -- Create a bag and add our ModData markers (simulates old cart data)
        local bag = instanceItem("Base.Bag_BigHikingBag")
        local modData = bag:getModData()
        modData.SaucedCarts_schemaVersion = 1

        self.markedBagResult = SaucedCarts.Migration.looksLikeCart(bag)

        -- Clean bag without markers
        local cleanBag = instanceItem("Base.Bag_BigHikingBag")
        self.cleanBagResult = SaucedCarts.Migration.looksLikeCart(cleanBag)

        TestHelpers.info("Testing looksLikeCart() ModData detection")
    end,
    validate = function(self)
        if not self.markedBagResult then
            return TestHelpers.fail("Container with SaucedCarts ModData not detected")
        end
        if self.cleanBagResult then
            return TestHelpers.fail("Clean bag incorrectly detected as cart")
        end
        return TestHelpers.pass("looksLikeCart() correctly detects ModData markers")
    end
})

-- ============================================================================
-- FIND ORPHANS TEST
-- ============================================================================

TestRunner.register("orphan_findOrphans_lists_all", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Give player multiple carts
        local cart1 = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        local cart2 = instanceItem("SaucedCarts.ShoppingCart")
        PLAYER_OBJ:getInventory():AddItem(cart2)
        local cart3 = instanceItem("SaucedCarts.ShoppingCart")
        PLAYER_OBJ:getInventory():AddItem(cart3)

        self.cart1Id = cart1:getID()
        self.cart2Id = cart2:getID()
        self.cart3Id = cart3:getID()

        -- Mark only cart1 and cart3 as orphans (not cart2)
        SaucedCarts.Migration.markAsOrphan(cart1)
        SaucedCarts.Migration.markAsOrphan(cart3)

        -- Find orphans
        self.orphans = SaucedCarts.Migration.findOrphans(PLAYER_OBJ)

        TestHelpers.info("Testing findOrphans with 2 of 3 carts marked")
    end,
    validate = function(self)
        if #self.orphans ~= 2 then
            return TestHelpers.fail("Expected 2 orphans, found %d", #self.orphans)
        end

        -- Check that the right carts are in the list
        local foundCart1, foundCart3 = false, false
        for _, orphan in ipairs(self.orphans) do
            if orphan:getID() == self.cart1Id then foundCart1 = true end
            if orphan:getID() == self.cart3Id then foundCart3 = true end
        end

        if not foundCart1 then
            return TestHelpers.fail("Cart1 not found in orphans list")
        end
        if not foundCart3 then
            return TestHelpers.fail("Cart3 not found in orphans list")
        end

        return TestHelpers.pass("findOrphans() correctly found 2 orphan carts")
    end
})

return true
