-- ============================================================================
-- SaucedCarts/Distributions.lua
-- ============================================================================
-- PURPOSE: Adds carts to VehicleDistributions only.
--          Ground spawning is now handled by WorldSpawning.lua (room-based).
--
-- CONTEXT: SERVER ONLY
--          Distribution tables are server-side for world generation.
--
-- NOTE: Procedural container spawning was removed because:
--       1. Container restrictions block carts from player inventory
--       2. Carts should spawn ON THE GROUND, not inside containers
--       3. WorldSpawning.lua now handles ground-based room spawning
--
-- SPAWN RATES: Controlled by SandboxVars.SaucedCarts.SpawnRate (0-500%)
-- ============================================================================

if isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/CartData"

-- Vehicle spawn locations for carts (thematically appropriate trucks)
-- These still work because players can access vehicle containers
local VEHICLE_SPAWN_LOCATIONS = {
    "GroceriesTruckBed",   -- Grocery delivery trucks
}

--- Add cart items to VehicleDistributions tables
--- Called on OnPreDistributionMerge event before loot tables are finalized.
--- Iterates ALL registered cart types (including those from external mods).
--- Spawn rates scaled by SandboxVars.SaucedCarts.SpawnRate (0-500%).
---@return nil Early returns if mod disabled or spawn rate is 0
local function addDistributions()
    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        SaucedCarts.debug("Mod disabled - skipping distributions")
        return
    end

    local spawnRate = 100
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.SpawnRate then
        spawnRate = SandboxVars.SaucedCarts.SpawnRate
    end

    if spawnRate <= 0 then
        SaucedCarts.debug("Spawn rate is 0 - no carts will spawn in vehicles")
        return
    end

    local spawnMultiplier = spawnRate / 100
    local cartCount = 0
    local vehicleCount = 0

    -- Iterate ALL registered cart types (including external addon carts)
    for fullType, cartData in pairs(SaucedCarts.CartTypes) do
        local baseWeight = cartData.spawnWeight or 1
        local weight = math.max(1, math.floor(baseWeight * spawnMultiplier))

        cartCount = cartCount + 1

        -- Add to VehicleDistributions (delivery trucks)
        -- Carts spawn in truck beds where players can access them
        if VehicleDistributions then
            for _, location in ipairs(VEHICLE_SPAWN_LOCATIONS) do
                if VehicleDistributions[location] and VehicleDistributions[location].items then
                    table.insert(VehicleDistributions[location].items, fullType)
                    table.insert(VehicleDistributions[location].items, weight)
                    vehicleCount = vehicleCount + 1
                    SaucedCarts.debug(function() return string.format(
                        "Added %s to vehicle: %s (weight: %d)",
                        fullType, location, weight
                    ) end)
                end
            end
        end
    end

    SaucedCarts.debug(function() return string.format(
        "VehicleDistributions updated: %d cart type(s), %d vehicle location(s) (spawn rate: %d%%)",
        cartCount, vehicleCount, spawnRate
    ) end)
end

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

Events.OnPreDistributionMerge.Add(addDistributions)

SaucedCarts.debug("Distributions loaded (server) - vehicle spawns only, ground spawns via WorldSpawning")
