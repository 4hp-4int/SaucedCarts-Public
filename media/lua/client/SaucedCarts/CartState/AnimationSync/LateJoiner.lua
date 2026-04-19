-- ============================================================================
-- SaucedCarts/CartState/AnimationSync/LateJoiner.lua
-- ============================================================================
-- PURPOSE: Handle late-joiner animation sync for MP.
--          When a player joins mid-game, request full animation state from
--          server to see correct animations for already-equipped carts.
--
-- CONTEXT: CLIENT ONLY (MP)
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Network"

-- Import RemotePlayer for tracking
local RemotePlayer = require "SaucedCarts/CartState/AnimationSync/RemotePlayer"

---@class SaucedCartsLateJoiner
local LateJoiner = {}

-- =============================================================================
-- NETWORK HANDLER
-- =============================================================================

--- Handle full animation state from server (response to late-join request)
SaucedCarts.Network.registerClientHandler("fullAnimationSync", function(args)
    if not args or not args.states then
        SaucedCarts.debug("LateJoiner: invalid fullAnimationSync args")
        return
    end

    local localPlayer = getSpecificPlayer(0)
    local localOnlineId = localPlayer and localPlayer:getOnlineID()

    local applied = 0
    for _, state in ipairs(args.states) do
        -- Skip self (we already know our own state)
        if state.id ~= localOnlineId then
            local targetPlayer = getPlayerByOnlineID(state.id)
            if targetPlayer and state.hasCart then
                -- Track for continuous re-application (engine overwrites animation vars)
                RemotePlayer.trackPlayer(state.id)

                targetPlayer:setVariable("Weapon", "cart")
                targetPlayer:setVariable("RightHandMask", "holdingcartright")
                targetPlayer:setVariable("LeftHandMask", "holdingcartleft")
                targetPlayer:resetEquippedHandsModels()
                applied = applied + 1
            end
        end
    end

    SaucedCarts.debug(function() return "LateJoiner: fullAnimationSync applied to " .. applied .. " players (tracking enabled)" end)
end)

-- =============================================================================
-- SYNC REQUEST
-- =============================================================================

--- Request full animation state from server on player creation
local function onCreatePlayer(playerIndex, player)
    if not isClient() then return end
    if not player then return end
    local onlineId = player:getOnlineID()
    if not onlineId then return end  -- SP, no sync needed

    -- Request on next tick (network needs time to stabilize)
    local requestSent = false
    local function sendRequest()
        if requestSent then return end
        requestSent = true
        SaucedCarts.Network.sendToServer(player, "requestAnimationSync", {})
        SaucedCarts.debug("LateJoiner: requested animation sync for late-join")
        Events.OnTick.Remove(sendRequest)
    end
    Events.OnTick.Add(sendRequest)
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

Events.OnCreatePlayer.Add(onCreatePlayer)

SaucedCarts.debug("AnimationSync/LateJoiner module loaded")

return LateJoiner
