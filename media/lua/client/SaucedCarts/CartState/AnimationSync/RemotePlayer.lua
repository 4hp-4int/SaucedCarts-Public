-- ============================================================================
-- SaucedCarts/CartState/AnimationSync/RemotePlayer.lua
-- ============================================================================
-- PURPOSE: Track and maintain animation state for remote players holding carts.
--          The engine's network sync overwrites animation variables, so we must
--          continuously re-apply them for remote players.
--
-- CONTEXT: CLIENT ONLY (MP)
--
-- CRITICAL: The engine's network sync (IsoPlayer.java:1253) calls:
--   setVariable("Weapon", WeaponType.getWeaponType(this).getType())
-- Since carts aren't HandWeapons, this returns UNARMED (""), overwriting our value.
-- We must continuously re-apply animation variables for remote players.
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Network"

---@class SaucedCartsRemotePlayer
local RemotePlayer = {}

-- =============================================================================
-- STATE
-- =============================================================================

-- Track remote players with carts equipped (onlineId -> true)
local remoteCartPlayers = {}

-- =============================================================================
-- ANIMATION MAINTENANCE
-- =============================================================================

--- Re-apply animation variables for remote players (engine overwrites them)
local function maintainRemoteAnimations()
    local localPlayer = getSpecificPlayer(0)
    local localOnlineId = localPlayer and localPlayer:getOnlineID()

    for onlineId in pairs(remoteCartPlayers) do
        if onlineId ~= localOnlineId then
            local targetPlayer = getPlayerByOnlineID(onlineId)
            if targetPlayer then
                -- Check if they still have a cart equipped
                local primary = targetPlayer:getPrimaryHandItem()
                if primary and SaucedCarts.isCart(primary) then
                    -- Re-apply animation variables (engine may have overwritten)
                    targetPlayer:setVariable("Weapon", "cart")
                    targetPlayer:setVariable("RightHandMask", "holdingcartright")
                    targetPlayer:setVariable("LeftHandMask", "holdingcartleft")
                else
                    -- They dropped the cart, remove from tracking
                    remoteCartPlayers[onlineId] = nil
                end
            else
                -- Player disconnected or out of range
                remoteCartPlayers[onlineId] = nil
            end
        end
    end
end

-- Run every 10 ticks (~6x per second) to maintain animation state
local animTickCounter = 0
local function onTickMaintainAnimations()
    animTickCounter = animTickCounter + 1
    if animTickCounter >= 10 then
        animTickCounter = 0
        maintainRemoteAnimations()
    end
end

-- =============================================================================
-- NETWORK HANDLER
-- =============================================================================

--- Handle animation update broadcasts from server
SaucedCarts.Network.registerClientHandler("updateCartAnimation", function(args)
    -- Validate args
    if not args or args.playerOnlineId == nil or args.hasCart == nil then
        SaucedCarts.debug("RemotePlayer: invalid updateCartAnimation args")
        return
    end

    -- Find the player by online ID
    local targetPlayer = getPlayerByOnlineID(args.playerOnlineId)
    if not targetPlayer then
        SaucedCarts.debug(function() return "RemotePlayer: player " .. tostring(args.playerOnlineId) .. " not found" end)
        return
    end

    -- Skip if this is the local player (they already have correct animations)
    -- Use ID comparison (not object comparison) for reliability
    local localPlayer = getSpecificPlayer(0)
    local localOnlineId = localPlayer and localPlayer:getOnlineID()
    if args.playerOnlineId == localOnlineId then
        SaucedCarts.debug("RemotePlayer: skipping animation sync for local player")
        return
    end

    -- Apply animation variables and update tracking
    if args.hasCart then
        -- Track for continuous re-application (engine overwrites animation vars)
        remoteCartPlayers[args.playerOnlineId] = true

        targetPlayer:setVariable("Weapon", "cart")
        targetPlayer:setVariable("RightHandMask", "holdingcartright")
        targetPlayer:setVariable("LeftHandMask", "holdingcartleft")
        -- Force animator/model refresh
        targetPlayer:resetEquippedHandsModels()
        SaucedCarts.debug(function() return "RemotePlayer: set cart animations for remote player " ..
            tostring(args.playerOnlineId) .. " (tracking enabled)" end)
    else
        -- Remove from tracking
        remoteCartPlayers[args.playerOnlineId] = nil

        targetPlayer:setVariable("Weapon", "")
        targetPlayer:setVariable("RightHandMask", "")
        targetPlayer:setVariable("LeftHandMask", "")
        -- Force animator/model refresh
        targetPlayer:resetEquippedHandsModels()
        SaucedCarts.debug(function() return "RemotePlayer: cleared animations for remote player " ..
            tostring(args.playerOnlineId) .. " (tracking removed)" end)
    end
end)

-- =============================================================================
-- PUBLIC API
-- =============================================================================

--- Start tracking a remote player as having a cart
---@param onlineId number The player's online ID
function RemotePlayer.trackPlayer(onlineId)
    remoteCartPlayers[onlineId] = true
end

--- Stop tracking a remote player
---@param onlineId number The player's online ID
function RemotePlayer.untrackPlayer(onlineId)
    remoteCartPlayers[onlineId] = nil
end

--- Check if a player is being tracked
---@param onlineId number The player's online ID
---@return boolean
function RemotePlayer.isTracking(onlineId)
    return remoteCartPlayers[onlineId] == true
end

--- Get count of tracked remote players (for debugging)
---@return number
function RemotePlayer.getTrackedCount()
    local count = 0
    for _ in pairs(remoteCartPlayers) do
        count = count + 1
    end
    return count
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Only register tick handler in MP client context
if isClient() then
    Events.OnTick.Add(onTickMaintainAnimations)
end

SaucedCarts.debug("AnimationSync/RemotePlayer module loaded")

return RemotePlayer
