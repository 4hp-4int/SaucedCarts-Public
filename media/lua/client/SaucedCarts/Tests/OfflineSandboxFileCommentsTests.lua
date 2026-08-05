--[[
    SaucedCarts — Server sandbox-file comment heal tests
    ====================================================

    On dedicated servers PZ rewrites <server>_SandboxVars.lua at every boot,
    but the Translator lazy-loaded before mods registered, so mod options are
    written without tooltip comments or enum value maps (Workshop report:
    "can't edit the new loot spawn option from the server console").

    SandboxFileComments.heal() reloads the translator post-boot and rewrites
    the file through PZ's own writer. These tests lock the call order, the
    feature-detect guards (a missing Java binding must be caught by lookup —
    Kahlua nil-method-on-Java-object errors can escape pcall), and the
    fail-closed behavior: no rewrite unless the reload succeeded.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"

local SandboxFileComments = require "SaucedCarts/SandboxFileComments"

-- ============================================================================
-- MOCK HARNESS
-- ============================================================================
-- heal() reads Translator / getServerName / getSandboxOptions as globals at
-- call time, so each test installs what it needs and restores after.

local realTranslator = Translator
local realGetServerName = getServerName
local realGetSandboxOptions = getSandboxOptions

local calls

local function installMocks(opts)
    opts = opts or {}
    calls = { reload = 0, save = 0, savedName = nil, order = {}, tooltips = 0 }

    if opts.noTranslator then
        Translator = nil
    else
        Translator = {
            loadFiles = function()
                calls.reload = calls.reload + 1
                table.insert(calls.order, "reload")
                if opts.reloadErrors then error("simulated malformed translation file") end
            end,
            -- Necessity probe. Default nil = the stock dedicated-boot state
            -- (Translator lazy-loaded before mods registered), so the heal is
            -- needed. opts.modTranslationsLoaded flips it.
            getTextOrNull = function(key)
                if opts.probeThrows then error("simulated UnknownFormatConversionException") end
                if opts.modTranslationsLoaded then return "already resolvable tooltip text" end
                return nil
            end,
        }
    end

    if opts.noServerName then
        getServerName = nil
    else
        getServerName = function() return opts.serverName ~= nil and opts.serverName or "cartsmoke42" end
    end

    if opts.noSandboxOptions then
        getSandboxOptions = function() return nil end
    else
        local so = {}
        if not opts.noSaveMethod then
            so.saveServerLuaFile = function(self, name)
                calls.save = calls.save + 1
                calls.savedName = name
                table.insert(calls.order, "save")
                if opts.saveErrors then error("simulated write failure") end
                -- Real PZ returns a boolean; writeLuaFile swallows its own
                -- exceptions and reports failure here rather than throwing.
                if opts.saveReturnsFalse then return false end
                if opts.saveReturnsNil then return nil end
                return true
            end
        end

        -- Option introspection used by the pre-flight. Mirrors the real shape:
        -- getNumOptions() + getOptionByIndex(i) -> object with getTooltip().
        if not opts.noOptionIntrospection then
            local count = opts.optionCount or 3
            so.getNumOptions = function(self) return count end
            so.getOptionByIndex = function(self, i)
                local name = "MockOption" .. tostring(i)
                local opt = { getShortName = function(_) return name end }
                -- NOT `opts.noTooltipMethod and nil or fn` — nil is falsy in
                -- Lua, so that idiom always yields fn. Assign conditionally.
                if not opts.noTooltipMethod then
                    opt.getTooltip = function(_)
                        calls.tooltips = calls.tooltips + 1
                        table.insert(calls.order, "tooltip")
                        if opts.throwingTooltipIndex == i then
                            error("simulated UnknownFormatConversionException: %)")
                        end
                        return "a tooltip"
                    end
                end
                return opt
            end
        end

        getSandboxOptions = function() return so end
    end
end

local function restoreMocks()
    Translator = realTranslator
    getServerName = realGetServerName
    getSandboxOptions = realGetSandboxOptions
end

local function withMocks(opts, fn)
    installMocks(opts)
    local ok, resultOrErr, msg = pcall(fn)
    restoreMocks()
    if not ok then error(resultOrErr) end
    return resultOrErr, msg
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

tests["heal_reloads_then_saves_with_server_name"] = function()
    return withMocks({}, function()
        local healed = SandboxFileComments.heal()
        if not healed then return false, "heal should report success" end
        if calls.reload ~= 1 or calls.save ~= 1 then
            return false, "expected 1 reload + 1 save, got " .. calls.reload .. "/" .. calls.save
        end
        -- Order is now reload -> tooltip pre-flight -> save. The invariant that
        -- matters is unchanged: the reload comes first (so tooltips resolve
        -- against mod translations) and the write comes last.
        if calls.order[1] ~= "reload" then
            return false, "the translation reload must come first"
        end
        if calls.order[#calls.order] ~= "save" then
            return false, "save must come AFTER the reload and the pre-flight"
        end
        return Assert.equal(calls.savedName, "cartsmoke42",
            "saveServerLuaFile must receive the server name")
    end)
end

tests["reload_failure_skips_the_rewrite"] = function()
    -- If the reload throws (e.g. some installed mod ships malformed JSON),
    -- do NOT rewrite — the file would gain nothing, and heal must report
    -- failure so the caller doesn't log success.
    return withMocks({ reloadErrors = true }, function()
        local healed = SandboxFileComments.heal()
        if healed then return false, "heal must fail when reload errors" end
        return Assert.equal(calls.save, 0, "no rewrite after failed reload")
    end)
end

tests["missing_translator_binding_bails_before_any_call"] = function()
    return withMocks({ noTranslator = true }, function()
        return Assert.isFalse(SandboxFileComments.heal(),
            "must bail cleanly when Translator global is absent")
    end)
end

tests["missing_getServerName_bails_without_reload_side_effects"] = function()
    -- Guard order: bindings are checked BEFORE the reload runs, so a
    -- half-available environment doesn't get a translator reload with no
    -- rewrite to show for it.
    return withMocks({ noServerName = true }, function()
        local healed = SandboxFileComments.heal()
        if healed then return false, "heal must fail without getServerName" end
        return Assert.equal(calls.reload, 0, "no reload when the rewrite can't happen")
    end)
end

tests["unexposed_saveServerLuaFile_detected_by_lookup"] = function()
    -- The Kahlua gotcha: calling a nil method on a Java object can escape
    -- pcall. The guard must be a lookup, so the call never happens.
    return withMocks({ noSaveMethod = true }, function()
        local healed = SandboxFileComments.heal()
        if healed then return false, "heal must fail when method not exposed" end
        return Assert.equal(calls.save, 0, "save must never be attempted")
    end)
end

tests["nil_sandbox_options_bails"] = function()
    return withMocks({ noSandboxOptions = true }, function()
        return Assert.isFalse(SandboxFileComments.heal(),
            "must bail when getSandboxOptions returns nil")
    end)
end

tests["save_failure_reports_false"] = function()
    return withMocks({ saveErrors = true }, function()
        return Assert.isFalse(SandboxFileComments.heal(),
            "a throwing save must be caught and reported as failure")
    end)
end

tests["empty_server_name_refuses_to_save"] = function()
    return withMocks({ serverName = "" }, function()
        local healed = SandboxFileComments.heal()
        if healed then return false, "empty server name must fail" end
        return Assert.equal(calls.savedName, nil, "save must not run with empty name")
    end)
end

-- ============================================================================
-- 42.20.1 TRUNCATION REPORT — the guards that stop us destroying the file
-- ============================================================================
-- Report: SandboxVars.lua shrank 86007 -> 39873 bytes on every boot, ending
-- mid-file with no closing brace. PZ's writeLuaFile truncates on open, calls
-- getTooltip() per option UNGUARDED, and every getTooltip() resolves through
-- Translator.getTextOrNull -> .formatted() — which since the 42.20 percent
-- patch throws UnknownFormatConversionException on a bare '%'. One bad tooltip
-- in any of the reporter's ~245 mods aborted the write mid-file. We cannot
-- repair it afterwards (getFileWriter is ini/cfg/txt/log only on 42.20, and
-- getFileReader can't reach Zomboid/Server at all), so these lock PREVENTION.

tests["throwing_tooltip_blocks_the_rewrite_entirely"] = function()
    -- The headline regression. Pre-fix this called saveServerLuaFile and
    -- truncated the admin's sandbox file.
    return withMocks({ throwingTooltipIndex = 1 }, function()
        local healed = SandboxFileComments.heal()
        if healed then return false, "heal must refuse when a tooltip throws" end
        return Assert.equal(calls.save, 0,
            "the destructive write must never be attempted (PZ truncates on open)")
    end)
end

tests["throwing_tooltip_is_named_for_the_admin"] = function()
    -- The admin has ~245 mods and no way to know which one is at fault; the
    -- offending option name is the whole diagnostic value of the guard.
    return withMocks({ throwingTooltipIndex = 2 }, function()
        local offender, checked = SandboxFileComments.findThrowingTooltip(getSandboxOptions())
        if not Assert.isTrue(checked, "introspection was available") then return false end
        return Assert.equal(offender, "MockOption2", "names the option that throws")
    end)
end

tests["clean_tooltips_allow_the_rewrite"] = function()
    -- Sensitivity companion: the guard must not block the healthy path.
    return withMocks({}, function()
        local healed = SandboxFileComments.heal()
        if not Assert.isTrue(healed, "healthy path still rewrites") then return false end
        if not Assert.equal(calls.save, 1, "exactly one rewrite") then return false end
        return Assert.equal(calls.tooltips, 3, "every option's tooltip was pre-flighted")
    end)
end

tests["preflight_runs_before_the_write"] = function()
    -- Ordering is the entire point: a tooltip resolved after the FileWriter
    -- opens is a tooltip resolved too late.
    return withMocks({}, function()
        local firstSave, lastTooltip
        for i, ev in ipairs(calls.order) do
            if ev == "tooltip" then lastTooltip = i end
            if ev == "save" and not firstSave then firstSave = i end
        end
        SandboxFileComments.heal()
        firstSave, lastTooltip = nil, nil
        for i, ev in ipairs(calls.order) do
            if ev == "tooltip" then lastTooltip = i end
            if ev == "save" and not firstSave then firstSave = i end
        end
        if not Assert.notNil(firstSave, "a save happened") then return false end
        return Assert.less(lastTooltip, firstSave,
            "all tooltips resolve BEFORE saveServerLuaFile opens the file")
    end)
end

tests["unverifiable_introspection_fails_closed"] = function()
    -- If we can't check, we don't write. The guarded failure destroys an
    -- admin's config unrecoverably, so silently not healing is the better loss.
    return withMocks({ noOptionIntrospection = true }, function()
        local healed = SandboxFileComments.heal()
        if healed then return false, "must not write when safety can't be verified" end
        return Assert.equal(calls.save, 0, "no write without a successful pre-flight")
    end)
end

tests["options_without_getTooltip_binding_fail_closed"] = function()
    -- Lookup-based detection, not call-based: a Kahlua nil-method call on a
    -- Java object can escape pcall. Verifying nothing is not verifying.
    return withMocks({ noTooltipMethod = true }, function()
        local _, checked = SandboxFileComments.findThrowingTooltip(getSandboxOptions())
        if not Assert.isFalse(checked, "inspecting zero of N options is unverified") then
            return false
        end
        return Assert.isFalse(SandboxFileComments.heal(), "and therefore no rewrite")
    end)
end

tests["save_returning_false_is_reported_as_failure"] = function()
    -- writeLuaFile swallows its exception into ExceptionLogger and returns
    -- false. We used to discard the return and log success over a truncated
    -- file — that is why the report shows a success line with a broken file.
    return withMocks({ saveReturnsFalse = true }, function()
        return Assert.isFalse(SandboxFileComments.heal(),
            "an explicit false return must be treated as failure")
    end)
end

tests["save_returning_nil_stays_successful"] = function()
    -- Older/unexposed bindings return nothing. Only an explicit false is a
    -- failure signal; nil must not regress the healthy path.
    return withMocks({ saveReturnsNil = true }, function()
        return Assert.isTrue(SandboxFileComments.heal(),
            "nil return is inconclusive, not a failure")
    end)
end

tests["already_loaded_translations_skip_the_rewrite"] = function()
    -- Necessity guard. If PZ's own boot write already had mod translations,
    -- there is nothing to heal and no reason to take the write risk. This also
    -- self-disables the heal if TIS ever fixes the load ordering.
    return withMocks({ modTranslationsLoaded = true }, function()
        local healed = SandboxFileComments.heal()
        if healed then return false, "nothing to heal when translations already resolve" end
        if not Assert.equal(calls.save, 0, "no rewrite when unnecessary") then return false end
        return Assert.equal(calls.reload, 0, "and no pointless translator reload")
    end)
end

tests["probe_failure_does_not_block_the_heal"] = function()
    -- The probe is an optimisation, not a gate. If it throws we must fall
    -- through to the normal (guarded) heal rather than refuse to work.
    return withMocks({ probeThrows = true }, function()
        return Assert.isTrue(SandboxFileComments.heal(),
            "a throwing probe is treated as 'not loaded' and the heal proceeds")
    end)
end

return tests
