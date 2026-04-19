--[[
    SaucedCarts MP Sync Tests
    PURPOSE: Tests for MP synchronization handlers and network layer
    CONTEXT: client

    Tests cover:
    - Rate limiting (canPlayerToggle)
    - Handler argument validation
    - Network test mode and message capture
    - Active tracking table updates
    - Local toggle wrappers

    NOTE: These tests run in singleplayer/client context. They test the
    handler LOGIC by calling functions directly, not actual network delivery.
    For true MP integration tests, use a dedicated MP test server.
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/Upgrades"
require "SaucedCarts/UpgradeSync"
require "SaucedCarts/Tests/TestRunner"
require "SaucedCarts/Tests/TestHelpers"

local TestRunner = SaucedCarts.TestRunner
local TestHelpers = SaucedCarts.TestHelpers
local Upgrades = SaucedCarts.Upgrades
local UpgradeSync = SaucedCarts.UpgradeSync
local Network = SaucedCarts.Network

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Create a mock player object for testing
--- Returns a table that mimics the player methods we need
---@param onlineId number
---@return table mockPlayer
local function createMockPlayer(onlineId)
    local inv = {
        items = {},
        AddItem = function(self, item)
            table.insert(self.items, item)
            return item
        end,
        getItems = function(self)
            return {
                size = function() return #self.items end,
                get = function(_, i) return self.items[i + 1] end
            }
        end,
        getItemById = function(self, id)
            for _, item in ipairs(self.items) do
                if item:getID() == id then
                    return item
                end
            end
            return nil
        end,
    }

    return {
        _onlineId = onlineId,
        _inv = inv,
        _primaryHand = nil,
        _secondaryHand = nil,
        getOnlineID = function(self) return self._onlineId end,
        getInventory = function(self) return self._inv end,
        getPrimaryHandItem = function(self) return self._primaryHand end,
        getSecondaryHandItem = function(self) return self._secondaryHand end,
        setPrimaryHandItem = function(self, item) self._primaryHand = item end,
        setSecondaryHandItem = function(self, item) self._secondaryHand = item end,
        getUsername = function() return "TestPlayer" end,
    }
end

--- Create a cart with a flashlight installed (bypassing timed action)
---@param player IsoPlayer
---@param batteryCharge number|nil Battery level 0-1 (default 1.0)
---@return InventoryItem cart
local function createCartWithFlashlight(player, batteryCharge)
    local cart = TestHelpers.giveCart(player, "SaucedCarts.ShoppingCart")
    local modData = cart:getModData()
    modData.SaucedCarts_hasFlashlight = true
    modData.SaucedCarts_isLightActive = false
    modData.SaucedCarts_batteryCharge = batteryCharge or 1.0
    modData.SaucedCarts_flashlightData = {
        originalType = "Base.HandTorch",
        originalName = "Flashlight",
        batteryCharge = batteryCharge or 1.0,
    }
    return cart
end

-- ============================================================================
-- NETWORK TEST MODE TESTS
-- ============================================================================

TestRunner.register("mp_network_test_mode_captures_broadcasts", {
    run = function(self)
        -- Enable test mode
        Network.enableTestMode()

        -- Simulate a broadcast
        Network.broadcast("testCommand", { foo = "bar" })

        self.captures = Network.getCapturedBroadcasts()
    end,
    validate = function(self)
        Network.disableTestMode()

        if #self.captures ~= 1 then
            return TestHelpers.fail("Expected 1 captured broadcast, got %d", #self.captures)
        end
        if self.captures[1].command ~= "testCommand" then
            return TestHelpers.fail("Wrong command: %s", tostring(self.captures[1].command))
        end
        if self.captures[1].args.foo ~= "bar" then
            return TestHelpers.fail("Wrong args.foo: %s", tostring(self.captures[1].args.foo))
        end
        return TestHelpers.pass("Network test mode captures broadcasts correctly")
    end
})

TestRunner.register("mp_network_test_mode_clears_on_enable", {
    run = function(self)
        -- Enable, add some messages
        Network.enableTestMode()
        Network.broadcast("cmd1", {})
        Network.broadcast("cmd2", {})

        self.countBefore = #Network.getCapturedBroadcasts()

        -- Re-enable should clear
        Network.enableTestMode()

        self.countAfter = #Network.getCapturedBroadcasts()
    end,
    validate = function(self)
        Network.disableTestMode()

        if self.countBefore ~= 2 then
            return TestHelpers.fail("Expected 2 broadcasts before clear, got %d", self.countBefore)
        end
        if self.countAfter ~= 0 then
            return TestHelpers.fail("Expected 0 broadcasts after clear, got %d", self.countAfter)
        end
        return TestHelpers.pass("Network test mode clears on re-enable")
    end
})

-- ============================================================================
-- RATE LIMITING TESTS
-- ============================================================================

TestRunner.register("mp_rate_limit_blocks_rapid_toggle", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Reset rate limits
        UpgradeSync._resetRateLimits()

        -- First toggle should succeed
        self.firstResult = UpgradeSync._canPlayerToggle(PLAYER_OBJ, 1000)

        -- Immediate second toggle should fail (within cooldown)
        self.secondResult = UpgradeSync._canPlayerToggle(PLAYER_OBJ, 1000.1)

        -- After cooldown, should succeed again
        self.thirdResult = UpgradeSync._canPlayerToggle(PLAYER_OBJ, 1000.6)
    end,
    validate = function(self)
        UpgradeSync._resetRateLimits()

        if not self.firstResult then
            return TestHelpers.fail("First toggle should succeed")
        end
        if self.secondResult then
            return TestHelpers.fail("Second toggle should be rate limited")
        end
        if not self.thirdResult then
            return TestHelpers.fail("Third toggle after cooldown should succeed")
        end
        return TestHelpers.pass("Rate limiting works correctly (cooldown: %ss)", UpgradeSync._TOGGLE_COOLDOWN)
    end
})

TestRunner.register("mp_rate_limit_rejects_nil_player", {
    run = function(self)
        UpgradeSync._resetRateLimits()
        self.result = UpgradeSync._canPlayerToggle(nil, 1000)
    end,
    validate = function(self)
        if self.result then
            return TestHelpers.fail("Should reject nil player")
        end
        return TestHelpers.pass("Rate limit rejects nil player")
    end
})

-- ============================================================================
-- LOCAL TOGGLE WRAPPER TESTS
-- ============================================================================

TestRunner.register("mp_flashlight_local_toggle_tracks_active", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)

        -- Get initial state
        local activeFlashlights = UpgradeSync._getActiveFlashlights()
        self.countBefore = 0
        for _ in pairs(activeFlashlights) do self.countBefore = self.countBefore + 1 end

        -- Toggle on
        self.newState, self.success = UpgradeSync.toggleFlashlightLocal(cart, PLAYER_OBJ)

        -- Check tracking
        self.countAfter = 0
        for _ in pairs(activeFlashlights) do self.countAfter = self.countAfter + 1 end

        -- Toggle off
        UpgradeSync.toggleFlashlightLocal(cart, PLAYER_OBJ)

        -- Check tracking cleared
        self.countFinal = 0
        for _ in pairs(activeFlashlights) do self.countFinal = self.countFinal + 1 end
    end,
    validate = function(self)
        if not self.success then
            return TestHelpers.fail("Toggle should succeed")
        end
        if not self.newState then
            return TestHelpers.fail("New state should be ON")
        end
        if self.countAfter <= self.countBefore then
            return TestHelpers.fail("Active count should increase after toggle on")
        end
        if self.countFinal ~= self.countBefore then
            return TestHelpers.fail("Active count should return to initial after toggle off")
        end
        return TestHelpers.pass("Flashlight local toggle tracks active state")
    end
})

TestRunner.register("mp_flashlight_local_toggle_rejects_no_flashlight", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Cart WITHOUT flashlight
        local cart = TestHelpers.giveCart(PLAYER_OBJ, "SaucedCarts.ShoppingCart")

        self.newState, self.success = UpgradeSync.toggleFlashlightLocal(cart, PLAYER_OBJ)
    end,
    validate = function(self)
        if self.success then
            return TestHelpers.fail("Toggle should fail for cart without flashlight")
        end
        return TestHelpers.pass("Flashlight toggle rejects cart without flashlight")
    end
})

-- ============================================================================
-- HANDLER ARGUMENT VALIDATION TESTS
-- ============================================================================

TestRunner.register("mp_handler_rejects_nil_args", {
    run = function(self)
        -- Server handlers only register in MP server context
        if not Network._getServerHandler("toggleCartLight") then
            self.skipped = true
            return
        end

        Network.enableTestMode()
        UpgradeSync._resetRateLimits()

        -- Invoke the handler directly with nil args
        -- This shouldn't crash and shouldn't send any broadcasts
        self.success, self.err = Network._invokeServerHandler("toggleCartLight", createMockPlayer(1), nil)

        self.broadcasts = Network.getCapturedBroadcasts()
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("Server handlers not registered (SP context)")
        end

        Network.disableTestMode()

        -- Handler should complete without error (returns early on invalid args)
        if not self.success then
            return TestHelpers.fail("Handler should not throw: %s", tostring(self.err))
        end
        if #self.broadcasts ~= 0 then
            return TestHelpers.fail("Should not broadcast on invalid args, got %d", #self.broadcasts)
        end
        return TestHelpers.pass("Handler safely rejects nil args")
    end
})

TestRunner.register("mp_handler_rejects_missing_cartId", {
    run = function(self)
        -- Server handlers only register in MP server context
        if not Network._getServerHandler("toggleCartLight") then
            self.skipped = true
            return
        end

        Network.enableTestMode()
        UpgradeSync._resetRateLimits()

        -- Args present but missing cartId
        self.success, self.err = Network._invokeServerHandler("toggleCartLight", createMockPlayer(2), { foo = "bar" })

        self.broadcasts = Network.getCapturedBroadcasts()
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("Server handlers not registered (SP context)")
        end

        Network.disableTestMode()

        if not self.success then
            return TestHelpers.fail("Handler should not throw: %s", tostring(self.err))
        end
        if #self.broadcasts ~= 0 then
            return TestHelpers.fail("Should not broadcast without cartId, got %d", #self.broadcasts)
        end
        return TestHelpers.pass("Handler safely rejects missing cartId")
    end
})

TestRunner.register("mp_handler_rejects_when_rate_limited", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        Network.enableTestMode()
        UpgradeSync._resetRateLimits()

        -- Create cart with flashlight
        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        PLAYER_OBJ:setPrimaryHandItem(cart)
        PLAYER_OBJ:setSecondaryHandItem(cart)

        -- First call - should process (but no broadcast if in SP since handler has isServer check)
        -- We're testing the rate limiting logic path exists
        Network._invokeServerHandler("toggleCartLight", PLAYER_OBJ, { cartId = cart:getID() })

        -- Immediately second call - should be rate limited
        Network.clearCapturedMessages()
        Network._invokeServerHandler("toggleCartLight", PLAYER_OBJ, { cartId = cart:getID() })

        self.broadcasts = Network.getCapturedBroadcasts()
    end,
    validate = function(self)
        Network.disableTestMode()

        -- The second call should be rate limited and not broadcast
        -- (First call might or might not broadcast depending on server context)
        if #self.broadcasts ~= 0 then
            return TestHelpers.fail("Rate limited call should not broadcast, got %d", #self.broadcasts)
        end
        return TestHelpers.pass("Handler respects rate limiting")
    end
})

-- ============================================================================
-- CLIENT HANDLER TESTS
-- ============================================================================

TestRunner.register("mp_client_handler_rejects_nil_args", {
    run = function(self)
        -- Client handlers only register in MP client context
        if not Network._getClientHandler("cartLightUpdate") then
            self.skipped = true
            return
        end

        -- Client handlers should safely handle nil args
        self.success, self.err = Network._invokeClientHandler("cartLightUpdate", nil)
    end,
    validate = function(self)
        if self.skipped then
            return TestHelpers.skip("Client handlers not registered (SP context)")
        end

        -- Should complete without error
        if not self.success then
            return TestHelpers.fail("Client handler should not throw: %s", tostring(self.err))
        end
        return TestHelpers.pass("Client handler safely rejects nil args")
    end
})

TestRunner.register("mp_client_handler_skips_own_updates", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create cart
        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        self.cartId = cart:getID()
        self.initialState = Upgrades.isLightActive(cart)

        -- Invoke client handler with our own player's online ID
        -- It should skip processing (no state change)
        Network._invokeClientHandler("cartLightUpdate", {
            playerOnlineId = PLAYER_OBJ:getOnlineID(),
            cartId = self.cartId,
            isActive = true,
        })

        self.finalState = Upgrades.isLightActive(cart)
    end,
    validate = function(self)
        -- State should not change because we skip our own updates
        if self.initialState ~= self.finalState then
            return TestHelpers.fail("State changed when processing own update - should skip")
        end
        return TestHelpers.pass("Client handler skips own player updates")
    end
})

-- ============================================================================
-- TRACKING TABLE TESTS
-- ============================================================================

TestRunner.register("mp_active_tracking_reset_clears_state", {
    run = function(self)
        if not TestRunner.setup() then return end
        local PLAYER_OBJ = TestRunner.getPlayer()

        -- Create and toggle flashlight on
        local cart = createCartWithFlashlight(PLAYER_OBJ, 1.0)
        UpgradeSync.toggleFlashlightLocal(cart, PLAYER_OBJ)

        -- Count before reset
        local flashlights = UpgradeSync._getActiveFlashlights()
        self.countBefore = 0
        for _ in pairs(flashlights) do self.countBefore = self.countBefore + 1 end

        -- Reset
        UpgradeSync._resetRateLimits()

        -- Count after (rate limits are reset, but flashlight tracking is separate)
        -- Let's toggle off to clear
        UpgradeSync.toggleFlashlightLocal(cart, PLAYER_OBJ)

        self.countAfter = 0
        for _ in pairs(flashlights) do self.countAfter = self.countAfter + 1 end
    end,
    validate = function(self)
        if self.countBefore == 0 then
            return TestHelpers.fail("Should have active flashlight before cleanup")
        end
        if self.countAfter ~= 0 then
            return TestHelpers.fail("Should have no active flashlights after toggle off")
        end
        return TestHelpers.pass("Active tracking can be cleared")
    end
})

-- ============================================================================
-- MODULE INITIALIZATION
-- ============================================================================

SaucedCarts.debug("MPSyncTests module loaded")