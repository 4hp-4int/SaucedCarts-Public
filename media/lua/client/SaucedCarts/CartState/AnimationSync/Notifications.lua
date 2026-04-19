-- ============================================================================
-- SaucedCarts/CartState/AnimationSync/Notifications.lua
-- ============================================================================
-- PURPOSE: Handle server notifications for instant drop operations.
--          Server sends cartBroke/cartDamaged notifications after performing
--          server-authoritative instant drop.
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Network"

---@class SaucedCartsAnimSyncNotifications
local Notifications = {}

-- =============================================================================
-- NETWORK HANDLERS
-- =============================================================================

--- Handler: Server notifies cart broke during instant drop
SaucedCarts.Network.registerClientHandler("cartBroke", function(args)
    local player = getSpecificPlayer(0)
    if player and SaucedCarts.Notifications then
        SaucedCarts.Notifications.cartBroke(player)
    end
end)

--- Handler: Server notifies cart damaged (low condition warning)
SaucedCarts.Network.registerClientHandler("cartDamaged", function(args)
    local player = getSpecificPlayer(0)
    if player and SaucedCarts.Notifications then
        SaucedCarts.Notifications.cartDamaged(player)
    end
end)

-- =============================================================================
-- MODULE INFO
-- =============================================================================

SaucedCarts.debug("AnimationSync/Notifications module loaded")

return Notifications
