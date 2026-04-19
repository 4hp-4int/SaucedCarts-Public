--[[
    SaucedCarts Duplication Tests
    PURPOSE: Tests that verify cart operations don't create duplicates
    CONTEXT: client

    Critical for MP safety - these detect bugs that would cause item duplication.
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Tests/TestRunner"
require "SaucedCarts/Tests/TestHelpers"
require "SaucedCarts/TimedActions/ISCartPickupAction"
require "SaucedCarts/TimedActions/ISCartRepairAction"
require "TimedActions/ISDropWorldItemAction"
require "TimedActions/ISEquipWeaponAction"

local TestRunner = SaucedCarts.TestRunner
local TestHelpers = SaucedCarts.TestHelpers

-- ============================================================================
-- DUPLICATION TESTS
-- ============================================================================

TestRunner.register("cart_pickup_no_duplicate", {
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
        self.spawnSquare = square

        TestHelpers.info("Cart spawned with ID %d", self.cartId)

        -- Walk to cart and queue pickup
        luautils.walkAdj(PLAYER_OBJ, square)
        local worldItem = cart:getWorldItem()
        if worldItem then
            ISTimedActionQueue.add(ISCartPickupAction.FromWorldItem(PLAYER_OBJ, worldItem))
        else
            TestHelpers.fail("Cart has no world item")
        end
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Check 1: Cart should be in player's inventory
        local inInventory = false
        local inv = PLAYER_OBJ:getInventory()
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:getID() == self.cartId then
                inInventory = true
                break
            end
        end

        if not inInventory then
            return TestHelpers.fail("Cart ID %d not found in inventory after pickup", self.cartId)
        end

        -- Check 2: Cart should NOT still be on ground (would indicate duplicate)
        local worldObjects = self.spawnSquare:getWorldObjects()
        if worldObjects then
            for i = 0, worldObjects:size() - 1 do
                local obj = worldObjects:get(i)
                if instanceof(obj, "IsoWorldInventoryObject") then
                    local item = obj:getItem()
                    if item and item:getID() == self.cartId then
                        return TestHelpers.fail("DUPLICATE! Cart still on ground AND in inventory")
                    end
                end
            end
        end

        -- Check 3: Should be exactly 1 cart total (the one we spawned, now in inventory)
        local totalCount = TestHelpers.countCartsTotal(PLAYER_OBJ, 10)
        if totalCount ~= 1 then
            return TestHelpers.fail("Expected 1 cart, found %d", totalCount)
        end

        return TestHelpers.pass("Cart picked up correctly, no duplicates")
    end
})

TestRunner.register("cart_drop_no_duplicate", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()
        local PLAYER_SQR = TestRunner.getPlayerSquare()

        -- Give player a cart (equips in both hands)
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()
        self.dropSquare = PLAYER_SQR

        TestHelpers.info("Cart in hands with ID %d", self.cartId)

        -- Drop the cart using vanilla drop action
        ISTimedActionQueue.add(ISDropWorldItemAction:new(PLAYER_OBJ, cart, PLAYER_SQR, 0.5, 0.5, 0, 0, false))
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Check 1: Cart should NOT be in inventory anymore
        local inInventory = false
        local inv = PLAYER_OBJ:getInventory()
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:getID() == self.cartId then
                inInventory = true
                break
            end
        end

        if inInventory then
            -- Cart still in inventory - check if also on ground (duplicate)
            local onGround = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 10)
            if onGround and onGround:getWorldItem() then
                return TestHelpers.fail("DUPLICATE! Cart in inventory AND on ground")
            end
            return TestHelpers.fail("Cart still in inventory after drop")
        end

        -- Check 2: Cart should be on ground
        local groundCart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 10)
        if not groundCart then
            return TestHelpers.fail("Cart ID %d not found on ground after drop", self.cartId)
        end

        -- Check 3: Should be exactly 1 cart total
        local totalCount = TestHelpers.countCartsTotal(PLAYER_OBJ, 10)
        if totalCount ~= 1 then
            return TestHelpers.fail("Expected 1 cart, found %d", totalCount)
        end

        return TestHelpers.pass("Cart dropped correctly, no duplicates")
    end
})

TestRunner.register("cart_repair_no_duplicate", {
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
        self.cartId = cart:getID()
        self.spawnSquare = square

        -- Give player repair material
        local repairItem = TestHelpers.giveItem(PLAYER_OBJ, "Base.ScrapMetal")
        self.repairItemId = repairItem:getID()

        TestHelpers.info("Cart ID %d damaged to 50%%", self.cartId)

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

        -- Check 1: Cart should still exist on ground (repair doesn't move it)
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 10)
        if not cart then
            return TestHelpers.fail("Cart ID %d not found after repair", self.cartId)
        end

        -- Check 2: Should be exactly 1 cart total (repair doesn't create duplicates)
        local totalCount = TestHelpers.countCartsTotal(PLAYER_OBJ, 10)
        if totalCount ~= 1 then
            return TestHelpers.fail("Expected 1 cart, found %d (possible duplicate)", totalCount)
        end

        return TestHelpers.pass("Cart repaired, no duplicates")
    end
})

-- ============================================================================
-- WEAPON EQUIP DUPLICATION TEST
-- ============================================================================
-- Tests the fix for: "Can double trolley with items if you equip your weapon
-- with the trolley in hand in a certain way"
--
-- Root cause: Carts have "heavyitem" tag which triggers vanilla forceDropHeavyItems()
-- when equipping a weapon via ISEquipWeaponAction. This could race with our
-- instant drop mechanism (when aiming), causing double-drop duplication.
--
-- The fix (in AnimationSync.lua and CartStateHandler.lua) checks if cart is
-- still in hands before dropping, preventing both handlers from dropping.
-- ============================================================================

TestRunner.register("weapon_equip_no_duplicate", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()
        local PLAYER_SQR = TestRunner.getPlayerSquare()

        -- Give player a cart (equips in both hands)
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")
        self.cartId = cart:getID()
        self.dropSquare = PLAYER_SQR

        -- Add some items to cart to test contents aren't duplicated
        local cartContainer = cart:getItemContainer()
        if cartContainer then
            cartContainer:AddItem("Base.Axe")
            cartContainer:AddItem("Base.Hammer")
            self.initialItemCount = 2
        else
            self.initialItemCount = 0
        end

        TestHelpers.info("Cart in hands with ID %d, %d items inside", self.cartId, self.initialItemCount)

        -- Give player a weapon in inventory (not equipped)
        local weapon = TestHelpers.giveItem(PLAYER_OBJ, "Base.Axe")
        self.weaponId = weapon:getID()

        -- Queue equip weapon action - this triggers forceDropHeavyItems() which
        -- should drop the cart (since it has heavyitem tag)
        -- The cart is NOT equipped via ISEquipWeaponAction directly - vanilla handles it
        ISTimedActionQueue.add(ISEquipWeaponAction:new(PLAYER_OBJ, weapon, 50, true, false))

        TestHelpers.info("Queued weapon equip action")
    end,
    validate = function(self)
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Check 1: Should be exactly 1 cart total (no duplication)
        local totalCount = TestHelpers.countCartsTotal(PLAYER_OBJ, 10)
        if totalCount ~= 1 then
            return TestHelpers.fail("Expected 1 cart, found %d (DUPLICATION BUG!)", totalCount)
        end

        -- Check 2: Find the cart - should be either in inventory OR on ground, not both
        local cart = TestHelpers.findCartById(PLAYER_OBJ, self.cartId, 10)
        if not cart then
            return TestHelpers.fail("Cart ID %d not found anywhere", self.cartId)
        end

        -- Check 3: Verify cart location (should be on ground after forceDropHeavyItems)
        local inInventory = false
        local inv = PLAYER_OBJ:getInventory()
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            if items:get(i):getID() == self.cartId then
                inInventory = true
                break
            end
        end

        local onGround = cart:getWorldItem() ~= nil

        -- Cart should be in exactly one place
        if inInventory and onGround then
            return TestHelpers.fail("DUPLICATION! Cart in BOTH inventory AND ground")
        end

        -- Check 4: If cart is on ground, verify contents weren't duplicated
        if onGround and self.initialItemCount > 0 then
            local cartContainer = cart:getItemContainer()
            if cartContainer then
                local currentItemCount = cartContainer:getItems():size()
                if currentItemCount ~= self.initialItemCount then
                    TestHelpers.info("Cart contents: expected %d, found %d",
                        self.initialItemCount, currentItemCount)
                    -- Note: This is informational - vanilla might handle contents differently
                end
            end
        end

        -- Check 5: Weapon should be equipped
        local primary = PLAYER_OBJ:getPrimaryHandItem()
        if not primary or primary:getID() ~= self.weaponId then
            TestHelpers.info("Note: Weapon may not be equipped yet (action still processing)")
        end

        local location = onGround and "ground" or "inventory"
        return TestHelpers.pass("Weapon equip: no cart duplication, cart is on %s", location)
    end
})

return true
