-- ============================================================================
-- SaucedCarts/Debug/CapacityCommands.lua
-- ============================================================================
-- PURPOSE: Client-side debug namespace wrapper for cart capacity diagnostics.
--          Delegates to SaucedCarts.capacityReport() in
--          shared/SaucedCarts/Diagnostics.lua, which is also callable
--          from the dedicated-server admin console.
--
-- CONTEXT: CLIENT ONLY (the Debug namespace itself is client-gated).
--
-- USAGE (in Lua console, admin / debug mode):
--   SaucedCartsDebug.capacityReport()          -- auto (held, else ground)
--   SaucedCartsDebug.capacityReport("held")    -- force held cart
--   SaucedCartsDebug.capacityReport("ground")  -- force nearest ground cart
--
-- From the dedicated-server admin console instead:
--   SaucedCarts.capacityReport(getPlayerByOnlineID(N))         -- one player
--   SaucedCarts.capacityReportAllPlayers()                     -- every player
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"

local CapacityCommands = {}

function CapacityCommands.capacityReport(mode)
    local player = getSpecificPlayer(0)
    if not player then SaucedCarts.error("No local player"); return end
    SaucedCarts.capacityReport(player, mode)
end

function CapacityCommands.capacityReportAllPlayers()
    SaucedCarts.capacityReportAllPlayers()
end

--- Ask the dedicated server to run capacityReport on its own state for
--- this player. Output lands in the server's DebugLog-server.txt.
function CapacityCommands.capacityReportServer(mode)
    SaucedCarts.requestServerCapacityReport(mode)
end

return CapacityCommands
