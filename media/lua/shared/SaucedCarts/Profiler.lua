-- ============================================================================
-- SaucedCarts/Profiler.lua
-- ============================================================================
-- PURPOSE: Debug profiling utilities for measuring function execution time.
--
-- CONTEXT: SHARED (client + server)
--
-- USAGE: Only active when getDebug() returns true. Zero overhead when off.
--
-- API:
--   Profiler.wrap(name, func)           - Wrap single function
--   Profiler.instrumentModule(mod, pfx) - Wrap all functions in module
--   Profiler.setThreshold(ms)           - Only log calls > N ms (default: 1)
--   Profiler.getStats()                 - Get stats table
--   Profiler.printSummary()             - Print formatted summary
--   Profiler.reset()                    - Clear all stats
-- ============================================================================

require "SaucedCarts/Core"

local Profiler = {}

-- Stats storage: { [name] = { calls, totalMs, maxMs } }
local stats = {}

-- Threshold in ms - only log calls exceeding this
local threshold = 1

-- ============================================================================
-- Core Functions
-- ============================================================================

--- Set threshold for logging individual calls
---@param ms number Minimum ms to log (default: 1)
function Profiler.setThreshold(ms)
    threshold = ms or 1
end

--- Wrap a function to track execution time
--- Returns original function unchanged if debug is off
---@param name string Display name for this function
---@param func function The function to wrap
---@return function Wrapped function (or original if debug off)
function Profiler.wrap(name, func)
    if not getDebug() then
        return func  -- No-op when debug off
    end

    stats[name] = stats[name] or { calls = 0, totalMs = 0, maxMs = 0 }

    return function(...)
        local start = getTimestampMs()
        local results = {func(...)}
        local elapsed = getTimestampMs() - start

        local s = stats[name]
        s.calls = s.calls + 1
        s.totalMs = s.totalMs + elapsed
        if elapsed > s.maxMs then s.maxMs = elapsed end

        if elapsed >= threshold then
            print(string.format("[Profile] %s: %dms", name, elapsed))
        end

        return unpack(results)
    end
end

--- Instrument all functions in a module
--- Does nothing if debug is off
---@param mod table The module table to instrument
---@param prefix string Prefix for function names (e.g., "SaucedCarts")
function Profiler.instrumentModule(mod, prefix)
    if not getDebug() then return end

    for k, v in pairs(mod) do
        if type(v) == "function" then
            mod[k] = Profiler.wrap(prefix .. "." .. k, v)
        end
    end
end

--- Get profiling statistics
---@return table[] Array of {name, calls, totalMs, avgMs, maxMs} sorted by totalMs
function Profiler.getStats()
    local result = {}
    for name, s in pairs(stats) do
        table.insert(result, {
            name = name,
            calls = s.calls,
            totalMs = s.totalMs,
            avgMs = s.calls > 0 and (s.totalMs / s.calls) or 0,
            maxMs = s.maxMs,
        })
    end
    table.sort(result, function(a, b) return a.totalMs > b.totalMs end)
    return result
end

--- Print formatted profiling summary to console
function Profiler.printSummary()
    local data = Profiler.getStats()
    if #data == 0 then
        print("[Profiler] No data collected. Is debug mode enabled?")
        return
    end
    print("=== SaucedCarts Profiler Summary ===")
    print(string.format("%-40s %8s %10s %8s %8s", "Function", "Calls", "Total(ms)", "Avg(ms)", "Max(ms)"))
    print(string.rep("-", 80))
    for _, s in ipairs(data) do
        print(string.format("%-40s %8d %10d %8.2f %8d",
            s.name, s.calls, s.totalMs, s.avgMs, s.maxMs))
    end
    print("====================================")
end

--- Reset all profiling statistics
function Profiler.reset()
    stats = {}
    print("[Profiler] Stats reset")
end

--- Check if profiling is active
---@return boolean
function Profiler.isActive()
    return getDebug() == true
end

SaucedCarts.Profiler = Profiler
return Profiler
