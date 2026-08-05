-- ============================================================================
-- SaucedCarts/SandboxFileComments.lua
-- ============================================================================
-- PURPOSE: Reload translations on a dedicated server after mods have
--          registered, so server-side getText resolves mod strings.
--
-- CONTEXT: SERVER ONLY (dedicated / hosted MP; no-op in SP)
--
-- WE NO LONGER REWRITE <server>_SandboxVars.lua. THAT IS DELIBERATE.
--
--   What this used to do, and why it was removed:
--
--   PZ writes <server>_SandboxVars.lua on every dedicated boot, resolving each
--   option's tooltip through the Translator. On a dedicated server the
--   Translator lazy-loads before mods register, so every MOD option landed in
--   that file bare — no tooltip comment, no "-- 1 = Off, 2 = Rare" enum map —
--   leaving admins editing blind. From v2.1.13 we healed that by reloading the
--   translator on OnServerStarted and calling saveServerLuaFile() to have PZ
--   regenerate the file with comments for every installed mod.
--
--   On 42.20.1 that turned destructive, and three servers reported it:
--     * writeLuaFile opens `new FileWriter(file)` — the existing file is
--       TRUNCATED before a byte is written.
--     * It resolves getTooltip() per option, unguarded.
--     * Since the 42.20 percent patch every translated string is run through
--       String.formatted, so a tooltip carrying a stray '%' (a mod writing the
--       C-style '%i' is the observed case) raises UnknownFormatConversion-
--       Exception — which Translator does not catch.
--   The write dies mid-file, try-with-resources flushes the partial content,
--   and PZ swallows the exception and returns false. The admin is left with a
--   half-written sandbox file that does not even PARSE on the next boot, for
--   EVERY mod on the server, not just ours.
--
--   Every mitigation was tried and none of them hold:
--     * Pre-flighting every getTooltip() from Lua does NOT work. Verified by
--       live repro on 42.20.1: the throwing option does not surface as a
--       catchable Lua error the way it does inside Java, so the pre-flight
--       passes and the write still truncates.
--     * Repair-after-the-fact is impossible: 42.20 restricts getFileWriter to
--       ini/cfg/txt/log, so a .lua cannot be written from Lua at all.
--     * Temp-file-and-rename is impossible for the same reason, and
--       saveServerLuaFile takes a server NAME, not a path, so its destination
--       cannot be redirected.
--     * "Only rewrite when comments are missing" does not help: on a stock
--       dedicated boot they are missing every time.
--
--   So the trade was: explanatory comments in a config file, against
--   destroying every mod's settings on the server on every boot, through a
--   vanilla writer we do not control and cannot guard. We take neither the
--   risk nor the feature.
--
--   The translator reload is kept. It is the same Lua-exposed call vanilla's
--   debug "Reload translations" menu item uses (DebugContextMenu.lua:1091),
--   it touches no files, and it makes server-side getText resolve mod strings
--   for the rest of the session — which several other mods benefit from.
--
--   If the comments are wanted back, the safe route is a companion reference
--   file: getFileWriter permits .txt, so we can emit the option list with
--   tooltips and enum maps alongside the save without ever touching the
--   admin's own file. That is a feature, not an emergency fix.
-- ============================================================================

require "SaucedCarts/Core"

---@class SaucedCartsSandboxFileComments
local SandboxFileComments = {}

--- Reload translations so mod strings resolve server-side.
---
--- Deliberately does NOT write any file. See the header — rewriting
--- <server>_SandboxVars.lua truncated it on 42.20.1 and the failure cannot be
--- prevented or repaired from Lua.
---@return boolean reloaded
function SandboxFileComments.heal()
    if not (Translator and Translator.loadFiles) then
        SaucedCarts.log("SandboxFileComments: Translator.loadFiles not available, skipping")
        return false
    end

    local ok, err = pcall(function() Translator.loadFiles() end)
    if not ok then
        SaucedCarts.error("SandboxFileComments: translation reload failed: " .. tostring(err))
        return false
    end

    return true
end

local function onServerStarted()
    if not isServer() then return end
    -- Never let this break other OnServerStarted listeners.
    local ok, reloaded = pcall(SandboxFileComments.heal)
    if not ok then
        SaucedCarts.error("SandboxFileComments: translation reload aborted: " .. tostring(reloaded))
        return
    end
    if reloaded then
        SaucedCarts.log("SandboxFileComments: reloaded translations for mod strings "
            .. "(the server sandbox file is no longer rewritten — see 2.1.17 notes)")
    end
end

Events.OnServerStarted.Add(onServerStarted)

SaucedCarts.SandboxFileComments = SandboxFileComments

SaucedCarts.debug("SandboxFileComments loaded")

return SandboxFileComments
