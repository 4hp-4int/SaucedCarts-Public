--[[
    SaucedCarts — server translation reload (no sandbox file rewrite)
    =================================================================

    We used to reload the translator on a dedicated server and then call
    getSandboxOptions():saveServerLuaFile() so PZ would regenerate
    <server>_SandboxVars.lua with tooltip comments for every mod's options.

    On 42.20.1 that became destructive and three servers reported it: PZ's
    writeLuaFile truncates the file on open, resolves getTooltip() per option
    unguarded, and since the 42.20 percent patch a tooltip with a stray '%'
    raises UnknownFormatConversionException. The write dies mid-file, leaving a
    sandbox file that doesn't parse on the next boot — for every mod on the
    server. It can be neither prevented (a Lua pre-flight does not see the
    throw; verified by live repro on 42.20.1) nor repaired (42.20 forbids
    writing .lua from Lua at all).

    So the rewrite is gone. The translator reload stays: it writes nothing and
    makes server-side getText resolve mod strings for the session.

    The load-bearing test here is the one asserting we NEVER call
    saveServerLuaFile. If someone reintroduces the rewrite, that fails.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"

local SandboxFileComments = require "SaucedCarts/SandboxFileComments"

-- ============================================================================
-- MOCK HARNESS
-- ============================================================================
-- heal() reads Translator / getSandboxOptions as globals at call time, so each
-- test installs what it needs and restores after.

local realTranslator = Translator
local realGetServerName = getServerName
local realGetSandboxOptions = getSandboxOptions

local calls

local function installMocks(opts)
    opts = opts or {}
    calls = { reload = 0, save = 0, tooltips = 0 }

    if opts.noTranslator then
        Translator = nil
    else
        Translator = {
            loadFiles = function()
                calls.reload = calls.reload + 1
                if opts.reloadErrors then error("simulated malformed translation file") end
            end,
            getTextOrNull = function() return nil end,
        }
    end

    getServerName = function() return "cartsmoke42" end

    -- Fully-functional sandbox options. If any rewrite path ever comes back,
    -- these counters catch it rather than silently no-op'ing.
    getSandboxOptions = function()
        return {
            saveServerLuaFile = function(self, name)
                calls.save = calls.save + 1
                return true
            end,
            getNumOptions = function(self) return 3 end,
            getOptionByIndex = function(self, i)
                return {
                    getShortName = function(_) return "MockOption" .. tostring(i) end,
                    getTooltip = function(_)
                        calls.tooltips = calls.tooltips + 1
                        return "a tooltip"
                    end,
                }
            end,
        }
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

tests["heal_reloads_translations"] = function()
    return withMocks({}, function()
        local reloaded = SandboxFileComments.heal()
        if not Assert.isTrue(reloaded, "heal reports success") then return false end
        return Assert.equal(calls.reload, 1, "translations reloaded exactly once")
    end)
end

tests["heal_never_writes_the_sandbox_file"] = function()
    -- THE regression. PZ's writeLuaFile truncates on open and cannot be
    -- guarded from Lua, so the only safe number of calls is zero. Three
    -- Workshop reports (42.20.1) came from this call existing at all.
    return withMocks({}, function()
        SandboxFileComments.heal()
        return Assert.equal(calls.save, 0,
            "saveServerLuaFile must NEVER be called — it truncates the admin's config")
    end)
end

tests["heal_does_not_even_resolve_tooltips"] = function()
    -- Resolving tooltips was only ever needed to decide whether to write.
    -- With no write there is nothing to pre-flight, and touching getTooltip at
    -- all risks tripping the same throw for no benefit.
    return withMocks({}, function()
        SandboxFileComments.heal()
        return Assert.equal(calls.tooltips, 0, "no tooltip resolution at all")
    end)
end

tests["reload_failure_is_reported"] = function()
    -- A mod shipping malformed translation JSON makes loadFiles throw.
    return withMocks({ reloadErrors = true }, function()
        return Assert.isFalse(SandboxFileComments.heal(),
            "a throwing reload is caught and reported as failure")
    end)
end

tests["reload_failure_still_writes_nothing"] = function()
    return withMocks({ reloadErrors = true }, function()
        SandboxFileComments.heal()
        return Assert.equal(calls.save, 0, "no write attempted after a failed reload")
    end)
end

tests["missing_translator_binding_bails_before_any_call"] = function()
    -- Kahlua nil-method-on-Java-object errors can escape pcall, so a missing
    -- binding must be caught by lookup, not by the call failing.
    return withMocks({ noTranslator = true }, function()
        return Assert.isFalse(SandboxFileComments.heal(),
            "must bail cleanly when the Translator global is absent")
    end)
end

tests["missing_translator_writes_nothing"] = function()
    return withMocks({ noTranslator = true }, function()
        SandboxFileComments.heal()
        return Assert.equal(calls.save, 0, "no write on the bail path either")
    end)
end

return tests
