-- ============================================================================
-- SaucedCarts/SandboxFileComments.lua
-- ============================================================================
-- PURPOSE: Restore tooltip comments + enum value maps for mod sandbox options
--          in the server-generated <server>_SandboxVars.lua.
--
-- CONTEXT: SERVER ONLY (dedicated / hosted MP; no-op in SP)
--
-- THE BUG (verified against decompiled B42.19):
--   GameServer.main rewrites <server>_SandboxVars.lua on EVERY boot via
--   SandboxOptions.writeLuaFile, which resolves each option's tooltip and
--   enum value labels live through Translator.getTextOrNull. But the
--   Translator lazy-loads on the FIRST getText call — which on a dedicated
--   server happens early in boot, BEFORE mods are registered — and nothing
--   ever reloads it (clients reload on the mods screen; servers don't).
--   Result: every MOD option is written bare — no tooltip comment, and for
--   enums no "-- 1 = Off, 2 = Rare, ..." value map — leaving server admins
--   editing blind. Vanilla options are unaffected (base-game translations
--   are on disk at first load). Reported by a Workshop user who couldn't
--   edit LoadedCartSpawns from the server console.
--
-- THE HEAL:
--   OnServerStarted fires after PZ's bare boot rewrite, with mods fully
--   registered. Reload the translator — Translator.loadFiles() is the same
--   Lua-exposed call vanilla's debug "Reload translations" menu item uses
--   (DebugContextMenu.lua:1091) — then ask PZ's own writer to regenerate
--   the file. Comments now resolve for EVERY installed mod's options, not
--   just ours. As a bonus, server-side getText works for mod strings from
--   then on.
-- ============================================================================

require "SaucedCarts/Core"

---@class SaucedCartsSandboxFileComments
local SandboxFileComments = {}

--- Reload translations and rewrite the server sandbox file through PZ's
--- own writer. Feature-detects every Java entry point first: Kahlua errors
--- from calling a NIL method on a Java object can escape pcall, so a
--- missing binding must be caught by lookup, not by the call failing.
---@return boolean healed True if the file was rewritten
function SandboxFileComments.heal()
    if not (Translator and Translator.loadFiles) then
        SaucedCarts.log("SandboxFileComments: Translator.loadFiles not available, skipping")
        return false
    end
    if type(getServerName) ~= "function" then
        SaucedCarts.log("SandboxFileComments: getServerName not available, skipping")
        return false
    end

    local okReload, reloadErr = pcall(function() Translator.loadFiles() end)
    if not okReload then
        SaucedCarts.error("SandboxFileComments: translation reload failed: " .. tostring(reloadErr))
        return false
    end

    local sandboxOptions = getSandboxOptions and getSandboxOptions()
    if not (sandboxOptions and sandboxOptions.saveServerLuaFile) then
        SaucedCarts.log("SandboxFileComments: saveServerLuaFile not exposed, skipping")
        return false
    end

    local okSave, saveErr = pcall(function()
        local name = getServerName()
        if not name or name == "" then error("empty server name") end
        sandboxOptions:saveServerLuaFile(name)
    end)
    if not okSave then
        SaucedCarts.error("SandboxFileComments: sandbox file rewrite failed: " .. tostring(saveErr))
        return false
    end

    return true
end

local function onServerStarted()
    if not isServer() then return end
    if SandboxFileComments.heal() then
        SaucedCarts.log("SandboxFileComments: rewrote server SandboxVars.lua with option descriptions")
    end
end

Events.OnServerStarted.Add(onServerStarted)

SaucedCarts.SandboxFileComments = SandboxFileComments

SaucedCarts.debug("SandboxFileComments loaded")

return SandboxFileComments
