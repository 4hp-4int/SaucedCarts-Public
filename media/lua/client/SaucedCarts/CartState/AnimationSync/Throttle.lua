-- ============================================================================
-- SaucedCarts/CartState/AnimationSync/Throttle.lua
-- ============================================================================
-- PURPOSE: Throttle animation sync messages to prevent network flooding.
--          Coalesces rapid equip/unequip state changes to one send per
--          cooldown window.
--
-- CONTEXT: CLIENT ONLY (MP)
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Network"

---@class SaucedCartsAnimSyncThrottle
local Throttle = {}

-- =============================================================================
-- STATE
-- =============================================================================

local lastAnimSyncTime = {}      -- playerKey -> timestamp
local lastAnimSyncState = {}     -- playerKey -> last state announced (nil = never)
local pendingAnimSync = {}       -- playerKey -> { hasCart, sendAt, player }
local pendingAnimSyncCount = 0   -- Fast empty check (avoids next() which Kahlua may not have)
local ANIM_SYNC_COOLDOWN_MS = 250

-- =============================================================================
-- THROTTLED SEND
-- =============================================================================

--- Send animation sync with throttling (coalesces rapid changes)
---@param player IsoPlayer
---@param hasCart boolean
function Throttle.send(player, hasCart)
    if not isClient() then return end
    local onlineId = player:getOnlineID()
    if not onlineId then return end  -- SP, no sync needed

    local key = onlineId

    -- Level-triggered: only a CHANGE is worth a packet. The same state now
    -- arrives from two sources — our own onCartEquip/onCartDrop events and
    -- the hand-state transition in CartStateHandler — and both the server's
    -- equippedState table and every observer's RemotePlayer tracking are
    -- level-triggered too, so a repeat announcement is pure noise. A pending
    -- (queued) entry is the latest intent, so it wins over the last send.
    local known = lastAnimSyncState[key]
    local pending = pendingAnimSync[key]
    if pending then known = pending.hasCart end
    if known == hasCart then
        SaucedCarts.debug(function() return "Throttle: skipped duplicate (hasCart=" .. tostring(hasCart) .. ")" end)
        return
    end

    local now = getTimestampMs()
    local lastSent = lastAnimSyncTime[key] or 0

    if now - lastSent >= ANIM_SYNC_COOLDOWN_MS then
        -- Send immediately
        SaucedCarts.Network.sendToServer(player, "syncCartAnimation", {
            playerOnlineId = onlineId,
            hasCart = hasCart,
        })
        lastAnimSyncTime[key] = now
        lastAnimSyncState[key] = hasCart
        if pendingAnimSync[key] then
            pendingAnimSync[key] = nil
            pendingAnimSyncCount = pendingAnimSyncCount - 1
        end
        SaucedCarts.debug(function() return "Throttle: sent immediately (hasCart=" .. tostring(hasCart) .. ")" end)
    else
        -- Queue for later (coalesces rapid changes)
        if not pendingAnimSync[key] then
            pendingAnimSyncCount = pendingAnimSyncCount + 1
        end
        pendingAnimSync[key] = {
            hasCart = hasCart,
            sendAt = lastSent + ANIM_SYNC_COOLDOWN_MS,
            player = player,
        }
        SaucedCarts.debug(function() return "Throttle: queued (hasCart=" .. tostring(hasCart) .. ")" end)
    end
end

-- =============================================================================
-- TICK PROCESSING
-- =============================================================================

--- Process pending animation syncs on tick
local function processPendingAnimSyncs()
    -- Early exit if nothing pending (fast path for 99% of ticks)
    if pendingAnimSyncCount <= 0 then return end

    local now = getTimestampMs()

    -- Collect keys to process first (don't modify during iteration)
    local toProcess = {}
    for key, pending in pairs(pendingAnimSync) do
        if now >= pending.sendAt then
            table.insert(toProcess, key)
        end
    end

    -- Process collected entries
    for _, key in ipairs(toProcess) do
        local pending = pendingAnimSync[key]
        if pending then
            local player = pending.player
            local onlineId = player and player:getOnlineID()
            if player and onlineId then
                SaucedCarts.Network.sendToServer(player, "syncCartAnimation", {
                    playerOnlineId = onlineId,
                    hasCart = pending.hasCart,
                })
                lastAnimSyncTime[key] = now
                lastAnimSyncState[key] = pending.hasCart
                SaucedCarts.debug(function() return "Throttle: sent queued (hasCart=" .. tostring(pending.hasCart) .. ")" end)
            end
            pendingAnimSync[key] = nil
            pendingAnimSyncCount = pendingAnimSyncCount - 1
        end
    end
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

--- Cleanup tracking for a specific player key (on death/disconnect)
---@param key any Player key (online ID)
function Throttle.cleanup(key)
    lastAnimSyncTime[key] = nil
    lastAnimSyncState[key] = nil
    if pendingAnimSync[key] then
        pendingAnimSync[key] = nil
        pendingAnimSyncCount = pendingAnimSyncCount - 1
    end
end

--- Reset all throttle state (debug/testing)
function Throttle.reset()
    lastAnimSyncTime = {}
    lastAnimSyncState = {}
    pendingAnimSync = {}
    pendingAnimSyncCount = 0
end

--- Last state announced for a player key (nil = never announced).
--- Exposed for tests / pz-shell probes.
---@param key any Player key (online ID)
---@return boolean|nil
function Throttle.getLastState(key)
    return lastAnimSyncState[key]
end

--- Get pending count (for debugging)
---@return number
function Throttle.getPendingCount()
    return pendingAnimSyncCount
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

Events.OnTick.Add(processPendingAnimSyncs)

SaucedCarts.debug("AnimationSync/Throttle module loaded")

return Throttle
