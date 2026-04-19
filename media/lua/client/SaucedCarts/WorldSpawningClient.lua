-- ============================================================================
-- SaucedCarts/WorldSpawningClient.lua
-- ============================================================================
-- PURPOSE: Client-side ModData sync for WorldSpawning.
--          Receives and stores global ModData transmitted from server.
--
-- CONTEXT: CLIENT ONLY
--          Server creates/modifies ModData, client receives and stores it.
--
-- WHY THIS IS NEEDED:
--          In dedicated MP, server and client are separate processes.
--          Server-side ModData is invisible to client-side code until
--          explicitly received via OnReceiveGlobalModData and stored
--          via ModData.add().
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"

local MODDATA_KEY = "SaucedCarts_WorldSpawning"

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

--- Request ModData from server when game initializes
--- This ensures client has the data even if it joins mid-game
local function onInitGlobalModData(isNewGame)
    if isClient() then
        SaucedCarts.debug("WorldSpawningClient: Requesting ModData from server")
        ModData.request(MODDATA_KEY)
    end
end

--- Receive ModData transmitted from server
--- CRITICAL: Must call ModData.add() to store the received table
---@param tag string The ModData key
---@param data table|boolean The received table, or false if not found
local function onReceiveGlobalModData(tag, data)
    if tag ~= MODDATA_KEY then return end

    if data and type(data) == "table" then
        ModData.add(tag, data)
        SaucedCarts.debug(function() return string.format(
            "WorldSpawningClient: Received and stored ModData '%s'",
            tag
        ) end)

        -- Log building count for debugging
        if data.spawnedBuildings then
            local count = 0
            for _ in pairs(data.spawnedBuildings) do count = count + 1 end
            SaucedCarts.debug(function() return string.format(
                "WorldSpawningClient: ModData contains %d building(s)",
                count
            ) end)
        end
    else
        SaucedCarts.debug(function() return string.format(
            "WorldSpawningClient: Received empty/nil ModData for '%s'",
            tag
        ) end)
    end
end

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

Events.OnInitGlobalModData.Add(onInitGlobalModData)
Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData)

SaucedCarts.debug("WorldSpawningClient loaded (client)")
