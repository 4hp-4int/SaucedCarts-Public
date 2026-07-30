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
    calls = { reload = 0, save = 0, savedName = nil, order = {} }

    if opts.noTranslator then
        Translator = nil
    else
        Translator = {
            loadFiles = function()
                calls.reload = calls.reload + 1
                table.insert(calls.order, "reload")
                if opts.reloadErrors then error("simulated malformed translation file") end
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
        if calls.order[1] ~= "reload" or calls.order[2] ~= "save" then
            return false, "save must come AFTER the translation reload"
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

return tests
