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
--   just ours.
--
-- WHY THE HEAL IS GUARDED (Workshop report, PZ 42.20.1, ~245 mods):
--   The heal truncated <server>_SandboxVars.lua on every boot — 86007 bytes
--   down to 39873, ending mid-file after the last option it managed to write
--   with no closing brace. Three vanilla facts combine:
--     1. writeLuaFile opens `new FileWriter(file)` (SandboxOptions.java:878),
--        which TRUNCATES the existing file before a single byte is written.
--     2. It then calls getTooltip() per option (:907, :936) UNGUARDED — note
--        the enum value-translation loop right below each one has its own
--        try/catch, but the tooltip call does not.
--     3. Every getTooltip() overload (:1376/:1473/:1585/:1714/:1947) goes
--        through Translator.getTextOrNull -> reportMissingArgumentsFromPast-
--        Abuse -> text.formatted(). Since the 42.20 percent patch that makes
--        every translated string a format string, a tooltip carrying a bare
--        `%` in a non-specifier position raises UnknownFormatConversion-
--        Exception — which that method does NOT catch (it only catches
--        MissingFormatArgumentException).
--   So one badly-escaped tooltip in ANY installed mod aborts the write
--   mid-file. try-with-resources flushes the partial content, the outer
--   catch (:967) swallows the exception into ExceptionLogger and returns
--   FALSE — and we used to discard that return and log success anyway.
--
--   We cannot repair the damage afterwards: PZ 42.20 restricts getFileWriter
--   to ini/cfg/txt/log, and getFileReader rejects relative paths and roots at
--   Zomboid/Lua/ — so a .lua file in Zomboid/Server/ is neither readable nor
--   writable from Lua. Backup-and-restore and read-back verification are both
--   impossible. Prevention is the entire fix, hence the guards below.
-- ============================================================================

require "SaucedCarts/Core"

---@class SaucedCartsSandboxFileComments
local SandboxFileComments = {}

--- A tooltip key that ships in our own Sandbox translations. Used only as a
--- probe for "have mod translations been loaded server-side yet?". Must be a
--- key with no literal percent in its value so the probe itself can't be the
--- thing that throws.
local PROBE_KEY = "Sandbox_SaucedCarts_EnableMod_tooltip"

--- Have mod translations already resolved server-side?
---
--- This is the precondition of the original bug, tested directly. On a stock
--- dedicated boot it is false (the Translator lazy-loaded before mods
--- registered), so the heal is needed. If a future PZ build loads mod
--- translations before its own boot rewrite, this flips true and the heal
--- disables itself — no build sniffing required.
---@return boolean loaded
function SandboxFileComments.modTranslationsLoaded()
    if not (Translator and Translator.getTextOrNull) then return false end
    local ok, text = pcall(function() return Translator.getTextOrNull(PROBE_KEY) end)
    return ok and text ~= nil and text ~= ""
end

--- Walk every registered sandbox option and resolve its tooltip exactly the
--- way writeLuaFile will, so a tooltip that throws is discovered BEFORE the
--- destructive FileWriter opens rather than halfway through it.
---
--- Returns (offendingOptionName, checked):
---   * (nil, true)   every tooltip resolved — safe to write
---   * (name, true)  this option's tooltip throws — do NOT write
---   * (nil, false)  the bindings needed to check aren't available
---
--- A `checked == false` result FAILS CLOSED. The failure being guarded against
--- destroys an admin's sandbox config with no way back, so on any build where
--- we cannot verify safety we decline to write. Silently not healing is a far
--- better outcome than silently truncating.
---@param sandboxOptions any
---@return string|nil offendingOption
---@return boolean checked
function SandboxFileComments.findThrowingTooltip(sandboxOptions)
    if not sandboxOptions then return nil, false end
    if type(sandboxOptions.getNumOptions) ~= "function" then return nil, false end
    if type(sandboxOptions.getOptionByIndex) ~= "function" then return nil, false end

    local okCount, count = pcall(function() return sandboxOptions:getNumOptions() end)
    if not okCount or type(count) ~= "number" then return nil, false end

    local inspected = 0
    for i = 0, count - 1 do
        local okOpt, opt = pcall(function() return sandboxOptions:getOptionByIndex(i) end)
        -- Feature-detect getTooltip by LOOKUP: a Kahlua nil-method call on a
        -- Java object can escape pcall, so we must not rely on the call failing.
        if okOpt and opt and type(opt.getTooltip) == "function" then
            inspected = inspected + 1
            local okTip = pcall(function() return opt:getTooltip() end)
            if not okTip then
                local name
                pcall(function()
                    if opt.getShortName then name = tostring(opt:getShortName()) end
                end)
                return name or ("option index " .. tostring(i)), true
            end
        end
    end

    -- Options existed but none exposed getTooltip — we verified nothing.
    if inspected == 0 and count > 0 then return nil, false end
    return nil, true
end

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

    -- Necessity guard. Probe BEFORE reloading — the question is whether PZ's
    -- own boot rewrite already had mod translations available to it.
    if SandboxFileComments.modTranslationsLoaded() then
        SaucedCarts.log("SandboxFileComments: mod translations already loaded at boot; "
            .. "the server's own SandboxVars.lua write already has comments, skipping rewrite")
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

    -- Pre-flight. PZ's writer truncates on open and resolves tooltips as it
    -- goes, so a single throwing tooltip in ANY installed mod would leave the
    -- admin's sandbox file half-written and unrecoverable.
    local offender, checked = SandboxFileComments.findThrowingTooltip(sandboxOptions)
    if not checked then
        SaucedCarts.log("SandboxFileComments: could not verify sandbox tooltips resolve safely "
            .. "(option introspection unavailable on this build); skipping rewrite rather than "
            .. "risk truncating the server sandbox file")
        return false
    end
    if offender then
        SaucedCarts.error("SandboxFileComments: sandbox option '" .. tostring(offender)
            .. "' has a tooltip that throws when resolved, so rewriting the server sandbox file "
            .. "would truncate it — skipping. This is almost always an unescaped '%' in some "
            .. "mod's translation: since PZ 42.20 a literal percent must be written '%%'. "
            .. "The server sandbox file is untouched.")
        return false
    end

    local okSave, saveResult = pcall(function()
        local name = getServerName()
        if not name or name == "" then error("empty server name") end
        return sandboxOptions:saveServerLuaFile(name)
    end)
    if not okSave then
        SaucedCarts.error("SandboxFileComments: sandbox file rewrite failed: " .. tostring(saveResult))
        return false
    end
    -- writeLuaFile swallows its own exceptions and reports failure through the
    -- return value, so a Lua-level success proves nothing on its own. Only an
    -- explicit false is a failure signal; nil means the binding returned
    -- nothing (older/unexposed) and is treated as inconclusive-but-ok.
    if saveResult == false then
        SaucedCarts.error("SandboxFileComments: PZ reported the sandbox file write FAILED. "
            .. "The file may be truncated — check the server log for the underlying exception, "
            .. "and restore <server>_SandboxVars.lua from a backup if so.")
        return false
    end

    return true
end

local function onServerStarted()
    if not isServer() then return end
    -- Never let this break other OnServerStarted listeners.
    local ok, healed = pcall(SandboxFileComments.heal)
    if not ok then
        SaucedCarts.error("SandboxFileComments: heal aborted: " .. tostring(healed))
        return
    end
    if healed then
        SaucedCarts.log("SandboxFileComments: rewrote server SandboxVars.lua with option descriptions")
    end
end

Events.OnServerStarted.Add(onServerStarted)

SaucedCarts.SandboxFileComments = SandboxFileComments

SaucedCarts.debug("SandboxFileComments loaded")

return SandboxFileComments
