-- ============================================================================
-- SaucedCarts/CartState/HolderRegistry.lua
-- ============================================================================
-- PURPOSE: Event-fed registry of LOCAL players currently holding a cart.
--
--          AUTHORITATIVE (phase 2). CartStateHandler's per-frame early exit is
--          driven by this registry — non-holders cost two table lookups, no
--          hand poll. Three mechanisms keep it honest:
--            1. Events maintain it (below) — proven complete for gameplay
--              transitions by the phase-1 shadow run (only divergence in a
--              full session was the join path, root-caused to deserialization).
--            2. CartStateHandler seeds from hands on a player's FIRST frame
--              (covers join/load, which is event-less) and re-checks holders'
--              hands every frame (a cartless player must never keep
--              restrictions; holders are few so this is cheap).
--            3. The slow reconciler below audits every local player's hands
--              every RECONCILE_TICKS, catching the one structural residual: a
--              cart appearing in hands with no event AFTER seeding. Nothing
--              known does this; the divergence counter is the proof either way
--              and stays on as a permanent health metric.
--          Worst case for a missed equip: pose/restrictions lag the cart by
--          one reconcile interval, then self-heal and get counted.
--
-- EVENT SOURCES:
--   * Events.OnEquipPrimary — fired by IsoGameCharacter.setPrimaryHandItem
--     (IsoGameCharacter.java:3720) on EVERY primary-hand change, including
--     nil (unequip) and swaps, regardless of caller. Covers vanilla and
--     other-mod paths we don't wrap.
--   * SaucedCarts.Events.onCartEquip/onCartDrop/onCartBroke — our own
--     controlled paths (defensive double-coverage; registration is
--     idempotent so overlap is harmless).
--   * Save/load deserialization writes the hand field DIRECTLY
--     (IsoPlayer.java:1264) and fires no event — OnCreatePlayer's hand scan
--     covers that boot path.
--
-- TIMING CONSTRAINT (load-bearing): setPrimaryHandItem fires OnEquipPrimary
--   and THEN clobbers the Weapon animation variable (IsoGameCharacter.java:
--   3722, WeaponType lookup → UNARMED for non-HandWeapons). The handler must
--   therefore only RECORD state — never apply the cart pose synchronously.
--   CartStateHandler's next-frame maintenance applies the pose.
--
-- CONTEXT: CLIENT ONLY. Remote players are RemotePlayer.lua's job;
--          OnPlayerUpdate (the shadow comparator's caller) only fires for
--          local players (IsoPlayer.java:2283 branch).
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"

---@class SaucedCartsHolderRegistry
local HolderRegistry = {}

-- =============================================================================
-- STATE
-- =============================================================================

-- playerKey -> true for local players believed to hold a cart.
local holders = {}
-- Maintained count (Kahlua exposes no `next`, so emptiness checks need this).
local holderCount = 0

-- Shadow-mode stats. divergences counts missed TRANSITIONS, not frames:
-- reportObserved resyncs the registry on each disagreement, so one missed
-- event costs exactly one tick of the counter.
local divergences = 0
local lastDivergence = nil

-- =============================================================================
-- KEYING
-- =============================================================================
-- Mirrors CartStateHandler.getPlayerKey exactly — the shadow comparison is
-- only meaningful if both sides key players identically.

---@param player IsoPlayer
---@return number|nil
local function getPlayerKey(player)
    if not player then return nil end
    local onlineId = player.getOnlineID and player:getOnlineID()
    if onlineId then return onlineId end
    return player.getPlayerNum and player:getPlayerNum()
end

-- =============================================================================
-- CORE TRANSITIONS (key-level, offline-testable)
-- =============================================================================

---@param playerKey number|nil
---@return boolean changed
function HolderRegistry.registerKey(playerKey)
    if playerKey == nil then return false end
    if holders[playerKey] then return false end
    holders[playerKey] = true
    holderCount = holderCount + 1
    return true
end

---@param playerKey number|nil
---@return boolean changed
function HolderRegistry.unregisterKey(playerKey)
    if playerKey == nil then return false end
    if not holders[playerKey] then return false end
    holders[playerKey] = nil
    holderCount = holderCount - 1
    return true
end

---@param playerKey number|nil
---@return boolean
function HolderRegistry.isHolderKey(playerKey)
    return playerKey ~= nil and holders[playerKey] == true
end

---@return number
function HolderRegistry.count()
    return holderCount
end

--- Full reset (game end / save switch).
function HolderRegistry.reset()
    holders = {}
    holderCount = 0
    divergences = 0
    lastDivergence = nil
end

-- =============================================================================
-- PLAYER-LEVEL WRAPPERS
-- =============================================================================

---@param player IsoPlayer|nil
function HolderRegistry.registerPlayer(player)
    HolderRegistry.registerKey(getPlayerKey(player))
end

---@param player IsoPlayer|nil
function HolderRegistry.unregisterPlayer(player)
    HolderRegistry.unregisterKey(getPlayerKey(player))
end

---@param player IsoPlayer|nil
---@return boolean
function HolderRegistry.isHolder(player)
    return HolderRegistry.isHolderKey(getPlayerKey(player))
end

-- =============================================================================
-- EVENT HANDLER (OnEquipPrimary)
-- =============================================================================

--- Record a primary-hand change. RECORD ONLY — see the timing constraint in
--- the header: setPrimaryHandItem clobbers the Weapon variable right after
--- firing this event, so applying the pose here would be undone immediately.
--- isCartFn is injectable for offline tests (defaults to safeIsCart, which
--- requires real userdata).
---@param character IsoGameCharacter|nil
---@param item InventoryItem|nil the new primary-hand item (nil on unequip)
---@param isCartFn nil|fun(item:any):boolean
function HolderRegistry.handleEquipPrimary(character, item, isCartFn)
    if not character then return end
    -- NPC/zombie/dummy guard (monorepo doctrine: gate every handler on
    -- subject type — OnEquipPrimary fires for any IsoGameCharacter subclass).
    if instanceof and not instanceof(character, "IsoPlayer") then return end
    -- Remote players are RemotePlayer.lua's job.
    if character.isLocalPlayer and not character:isLocalPlayer() then return end

    local isCart = (isCartFn or SaucedCarts.safeIsCart)(item)
    if isCart then
        HolderRegistry.registerPlayer(character)
    else
        HolderRegistry.unregisterPlayer(character)
    end
end

-- =============================================================================
-- SHADOW COMPARATOR
-- =============================================================================

--- Compare hand-truth (CartStateHandler's holder check or the reconciler
--- sweep) against the registry. On disagreement: count it, remember why,
--- resync to the hands (hands always win — they're the physical truth), and
--- log at .log level (visible on dedi — .debug is suppressed there).
---@param playerKey number|nil
---@param observedHasCart boolean what the hand poll saw this frame
---@return boolean diverged
function HolderRegistry.reportObserved(playerKey, observedHasCart)
    if playerKey == nil then return false end
    local believed = holders[playerKey] == true
    if believed == observedHasCart then return false end

    divergences = divergences + 1
    lastDivergence = string.format(
        "key=%s registry=%s observed=%s",
        tostring(playerKey), tostring(believed), tostring(observedHasCart))

    -- Resync so one missed event = one divergence, not one per frame.
    if observedHasCart then
        HolderRegistry.registerKey(playerKey)
    else
        HolderRegistry.unregisterKey(playerKey)
    end

    SaucedCarts.log("HolderRegistry SHADOW divergence #" .. divergences .. ": " .. lastDivergence)
    return true
end

--- Shadow-mode stats (for pz-shell probes / debug commands).
---@return table { holders=number, divergences=number, lastDivergence=string|nil }
function HolderRegistry.getStats()
    return {
        holders = holderCount,
        divergences = divergences,
        lastDivergence = lastDivergence,
    }
end

-- =============================================================================
-- EVENT WIRING
-- =============================================================================

-- Vanilla: every primary-hand change, all callers.
if Events and Events.OnEquipPrimary then
    Events.OnEquipPrimary.Add(function(character, item)
        HolderRegistry.handleEquipPrimary(character, item)
    end)
end

-- Our controlled paths (idempotent overlap with OnEquipPrimary is fine).
if SaucedCarts.Events and SaucedCarts.Events.onCartEquip then
    SaucedCarts.Events.onCartEquip:Add(function(player)
        HolderRegistry.registerPlayer(player)
    end)
end
if SaucedCarts.Events and SaucedCarts.Events.onCartDrop then
    SaucedCarts.Events.onCartDrop:Add(function(player)
        HolderRegistry.unregisterPlayer(player)
    end)
end
if SaucedCarts.Events and SaucedCarts.Events.onCartBroke then
    SaucedCarts.Events.onCartBroke:Add(function(player)
        HolderRegistry.unregisterPlayer(player)
    end)
end

-- Best-effort boot scan. Save/load writes the hand field directly
-- (IsoPlayer.java:1264), no OnEquipPrimary. In SP the hands are populated by
-- now; in MP they arrive from the server LATER, so this misses (proven by
-- shadow-phase divergence #1) — CartStateHandler's first-frame seed is the
-- one that actually covers MP joins. Kept because it's free and narrows the
-- SP window to zero frames.
if Events and Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(function(playerIndex, player)
        if not player then return end
        local primary = player.getPrimaryHandItem and player:getPrimaryHandItem()
        if primary and SaucedCarts.safeIsCart(primary) then
            HolderRegistry.registerPlayer(player)
        end
    end)
end

if Events and Events.OnGameEnd then
    Events.OnGameEnd.Add(function()
        HolderRegistry.reset()
    end)
end

-- =============================================================================
-- SLOW RECONCILER
-- =============================================================================
-- Audits every LOCAL player's hands against the registry. The only structural
-- hole it exists for: a cart appearing in hands with no OnEquipPrimary after
-- the first-frame seed (no known path does this — the counter proves it).
-- Missed UNEQUIPS are already caught per-frame by CartStateHandler's holder
-- hand-check; this sweep mostly sees that direction already resolved.

local RECONCILE_TICKS = 300  -- ~5s at 60fps

local reconcileCounter = 0
local function onTickReconcile()
    reconcileCounter = reconcileCounter + 1
    if reconcileCounter < RECONCILE_TICKS then return end
    reconcileCounter = 0
    if not getSpecificPlayer then return end
    for i = 0, 3 do
        local p = getSpecificPlayer(i)
        if p and not p:isDead() then
            local primary = p:getPrimaryHandItem()
            local hasCart = (primary and SaucedCarts.safeIsCart(primary)) or false
            HolderRegistry.reportObserved(getPlayerKey(p), hasCart)
        end
    end
end

if Events and Events.OnTick then
    Events.OnTick.Add(onTickReconcile)
end

SaucedCarts.debug("HolderRegistry loaded (shadow mode)")

return HolderRegistry
