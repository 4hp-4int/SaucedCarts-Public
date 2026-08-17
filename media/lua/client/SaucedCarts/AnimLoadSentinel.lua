-- ============================================================================
-- SaucedCarts/AnimLoadSentinel.lua
-- ============================================================================
-- PURPOSE: Detect the "mod animations failed to load this session" engine
--          race and tell the player the one-step cure.
--
-- CONTEXT: CLIENT ONLY
--
-- THE BUG (engine-side, field-reported): at app boot Steam Workshop can
-- return the subscribed mod IDs but fail the item detail request, leaving
-- the mounted mod list empty for a window. PZ parses and caches its
-- AnimationSets (AnimationSet.setMap) the first time a character animates;
-- if that happens inside the window, ZomboidFileSystem.resolveAllDirectories
-- misses every mod's media/AnimSets dir and the cart anim nodes are absent
-- for the whole session — while the mod's Lua (mounted slightly later)
-- works fine. The character pushes a cart with the vanilla walk animation
-- or T-poses.
--
-- WHY WE CAN'T FIX IT DIRECTLY: the refresh pipeline exists —
-- LuaManager.GlobalObject.refreshAnimSets(true) resets the cache, reloads
-- every anim node asset and rebinds live animators — but it has no
-- @LuaMethod annotation and neither AnimationSet nor AdvancedAnimator is an
-- exposed class, so Kahlua cannot reach it. The DEDICATED SERVER self-heals
-- (GameServer.java:842 calls it right before the main loop); the client
-- never does. (Upstream report material: the client should mirror that call
-- after mod mounting.)
--
-- THE CURE (verified empirically 2026-08-17 by hiding/restoring anim files
-- around a live session): a FULL GAME RESTART, nothing less.
-- AnimationSet.Reset() in the exit-to-menu teardown (IngameState.java:976)
-- re-parses only the NODE cache; the animation CLIP cache (the FBX data —
-- where the common "stuck crouching, can't move" variant lives, since a
-- matched node with a dead clip yields zero root motion and B42 movement is
-- animation-driven) survives until app shutdown. Exit-and-reload does NOT
-- fix it. This module's job is to notice the failure and say exactly that,
-- instead of leaving players to think the mod or their save is broken.
--
-- DETECTION: IsoGameCharacter.dbgGetAnimTrackName(layerIdx, trackIdx) is
-- Lua-exposed and returns "" out of bounds (IsoGameCharacter.java:1427-1430,
-- never throws). While the Weapon anim variable is "cart" and the player is
-- moving, at least one playing track must be a Bob_Cart_* clip (body node or
-- hand mask — both use them). If SAMPLES_NEEDED consecutive moving samples
-- see none, the animset load failed. One warning per session; a healthy
-- sample permanently disarms the sentinel.
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Notifications"

---@class SaucedCartsAnimLoadSentinel
local AnimLoadSentinel = {}

local SAMPLE_INTERVAL_MS = 400
-- ~1.6s of CUMULATIVE movement attempts with zero cart clips. The hand-mask
-- layer plays a Bob_Cart_* clip in essentially every equipped state (idle
-- hold included), so a healthy session hits on the first sample; the only
-- transient miss window is the equip blend (~0.3s), which the 4-sample
-- floor absorbs. Cumulative (never resets on idle) because stuck players
-- mash keys in short bursts — live validation 2026-08-17 accrued misses
-- across separate attempts exactly that way.
local SAMPLES_NEEDED = 4
local MAX_LAYER = 5             -- body + hand masks + action layers
local MAX_TRACK = 5

local missSamples = 0
local lastSampleMs = 0
local verdict = nil             -- nil = undecided, "ok" | "failed"

--- Pure scan: does any track name carry the cart clip prefix?
--- reader(layerIdx, trackIdx) -> string ("" when out of bounds)
---@return boolean found
function AnimLoadSentinel._scanForCartClip(reader)
    for layer = 0, MAX_LAYER do
        for track = 0, MAX_TRACK do
            local ok, name = pcall(reader, layer, track)
            if ok and type(name) == "string" and name ~= "" then
                if name:find("Bob_Cart", 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

--- Pure decision step. Returns the new verdict (nil while undecided).
---@param found boolean A cart clip was playing this sample
---@return string|nil verdict
function AnimLoadSentinel._recordSample(found)
    if verdict then return verdict end
    if found then
        verdict = "ok"
    else
        missSamples = missSamples + 1
        if missSamples >= SAMPLES_NEEDED then
            verdict = "failed"
        end
    end
    return verdict
end

--- Test hook: reset internal state.
function AnimLoadSentinel._reset()
    missSamples = 0
    lastSampleMs = 0
    verdict = nil
end

function AnimLoadSentinel._getState()
    return verdict, missSamples
end

local function announceFailure(player)
    SaucedCarts.log(
        "ANIM LOAD FAILURE detected: no Bob_Cart_* track played after "
        .. SAMPLES_NEEDED .. " moving samples with a cart equipped. "
        .. "PZ cached its animation data while this mod's files were not yet "
        .. "mounted (Steam Workshop boot race - engine bug, not save damage). "
        .. "Fix: QUIT the game completely and relaunch. Exit-to-menu is NOT "
        .. "enough - the clip cache survives to app shutdown (verified; only "
        .. "the anim-node cache resets at IngameState teardown).")
    -- Modal first: this is a two-sentence instruction the player must be
    -- able to read at their own pace — halo text fades in seconds. Centered
    -- OK dialog (width/height auto-fit via ISModalDialog.CalcSize); the halo
    -- stays as a secondary cue in case another UI swallows the modal.
    local shownModal = pcall(function()
        local modal = ISModalDialog:new(0, 0, 350, 150,
            getText("UI_SaucedCarts_AnimLoadFailed"), false, nil, nil,
            player:getPlayerNum())
        modal:initialise()
        modal:addToUIManager()
    end)
    pcall(function()
        SaucedCarts.Notifications.warn(player,
            getText("UI_SaucedCarts_AnimLoadFailed"), "animLoadFailed")
    end)
    if not shownModal then
        SaucedCarts.log("AnimLoadSentinel: modal unavailable, halo notification only")
    end
end

local function onPlayerUpdate(player)
    if verdict then return end
    if not player or player:getPlayerNum() ~= 0 then return end

    local ok = pcall(function()
        -- Feature-detect the debug accessor once; without it, disarm.
        if type(player.dbgGetAnimTrackName) ~= "function" then
            verdict = "ok"
            return
        end
        if player:getVariableString("Weapon") ~= "cart" then return end
        if not player:getVariableBoolean("isMoving") then return end

        local now = getTimestampMs()
        if (now - lastSampleMs) < SAMPLE_INTERVAL_MS then return end
        lastSampleMs = now

        local found = AnimLoadSentinel._scanForCartClip(function(l, t)
            return player:dbgGetAnimTrackName(l, t)
        end)
        if AnimLoadSentinel._recordSample(found) == "failed" then
            announceFailure(player)
        end
    end)
    if not ok then
        -- Never let diagnostics touch gameplay: one strike and we disarm.
        verdict = "ok"
    end
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- Fresh session, fresh sentinel (the failure is per-app-boot, but a
-- menu-reload heals it, so re-arm on every game start).
Events.OnGameStart.Add(AnimLoadSentinel._reset)

SaucedCarts.AnimLoadSentinel = AnimLoadSentinel

SaucedCarts.debug("AnimLoadSentinel module loaded")

return AnimLoadSentinel
