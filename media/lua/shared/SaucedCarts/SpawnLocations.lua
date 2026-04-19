-- ============================================================================
-- SaucedCarts/SpawnLocations.lua
-- ============================================================================
-- PURPOSE: Defines which rooms can spawn which cart types, with probabilities.
--          Used by WorldSpawning.lua (server) to spawn carts on the ground.
--
-- CONTEXT: SHARED (client + server)
--          Server needs this for spawning, client for UI/debugging.
--
-- FORWARD COMPATIBILITY:
--          - Schema version tracks data format changes
--          - Addons can register spawn rooms via SaucedCarts.registerCart()
--          - Room names are strings, tolerant of PZ map updates
-- ============================================================================

require "SaucedCarts/Core"

-- Schema version for spawn location data format
-- Increment if SpawnLocations structure changes in future versions
SaucedCarts.SPAWN_SCHEMA_VERSION = 1

---@class SpawnEntry
---@field type string Full cart type (e.g., "SaucedCarts.ShoppingCart")
---@field chance number Spawn probability 0-100
---@field allowResidential boolean|nil If true, allow spawn in buildings flagged residential by PZ (contains a "bedroom" room). Default false — framework skips residential to avoid apartment/house spawns.
---@field allowOutdoor boolean|nil If true, allow spawn on squares with no building (purely outdoor tiles). Default false — framework requires a building to avoid unexpected parking-lot spawns.
---@field skipFrameworkFilters boolean|nil If true, bypass ALL framework filters for this entry. Addon author takes full responsibility for spawn locations.

---@type table<string, SpawnEntry[]>
SaucedCarts.SpawnLocations = {}

-- ============================================================================
-- DEFAULT SPAWN LOCATIONS
-- ============================================================================
-- Built-in locations for the base ShoppingCart. Every room name below is a
-- real PZ room defined in `media/lua/server/Items/Distributions.lua` — no
-- phantom entries. Validated at load time against PZ's
-- ItemPickerJava.hasDistributionForRoom().
--
-- Weights reflect realism for a grocery-style shopping cart:
--   - Primary retail tier: places where carts are the default transport
--   - Retail + storage tier: bulk-goods stores and their back rooms
--   - Secondary tier: retail where carts exist but are less common
--   - Flavor tier: occasional / edge-case placements
--
-- Addons register their own rooms (and may target residential / outdoor
-- squares via opt-out flags) via SaucedCarts.registerCart(..., spawnRooms).

local SC = "SaucedCarts.ShoppingCart"

local DEFAULT_SPAWN_LOCATIONS = {
    -- Primary retail (15-25%)
    ["gigamart"]          = { { type = SC, chance = 25 } },
    ["grocery"]           = { { type = SC, chance = 20 } },
    ["departmentstore"]   = { { type = SC, chance = 18 } },
    ["grocerystorage"]    = { { type = SC, chance = 15 } },
    ["warehouse"]         = { { type = SC, chance = 15 } },

    -- Regular retail + major storage (10-12%)
    ["housewarestore"]    = { { type = SC, chance = 12 } },
    ["departmentstorage"] = { { type = SC, chance = 12 } },
    ["producestorage"]    = { { type = SC, chance = 12 } },
    ["toolstore"]         = { { type = SC, chance = 12 } },
    ["gardenstore"]       = { { type = SC, chance = 12 } },
    ["furniturestore"]    = { { type = SC, chance = 10 } },
    ["furniturestorage"]  = { { type = SC, chance = 10 } },
    ["outdoorsupply"]     = { { type = SC, chance = 10 } },
    ["carsupply"]         = { { type = SC, chance = 10 } },
    ["generalstore"]      = { { type = SC, chance = 10 } },
    ["giftstore"]         = { { type = SC, chance = 10 } },
    ["garagestorage"]     = { { type = SC, chance = 10 } },
    ["electronicstore"]   = { { type = SC, chance = 10 } },

    -- Secondary retail + storage (6-8%)
    ["storageunit"]          = { { type = SC, chance = 8 } },
    ["liquorstore"]          = { { type = SC, chance = 8 } },
    ["petstore"]             = { { type = SC, chance = 8 } },
    ["clothingstorage"]      = { { type = SC, chance = 8 } },
    ["generalstorestorage"]  = { { type = SC, chance = 8 } },
    ["camping"]              = { { type = SC, chance = 8 } },
    ["campingstorage"]       = { { type = SC, chance = 8 } },
    ["giftstorage"]          = { { type = SC, chance = 8 } },
    ["outdoorsupply_storage"] = { { type = SC, chance = 8 } },
    ["clothingstore"]        = { { type = SC, chance = 6 } },
    ["sportstore"]           = { { type = SC, chance = 6 } },

    -- Flavor (2-5%)
    ["bookstore"]         = { { type = SC, chance = 5 } },
    ["conveniencestore"]  = { { type = SC, chance = 5 } },
    ["cornerstore"]       = { { type = SC, chance = 5 } },
    ["storage"]           = { { type = SC, chance = 5 } },
    ["lobby"]             = { { type = SC, chance = 3 } },
    ["pawnshop"]          = { { type = SC, chance = 2 } },
}

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--- Initialize spawn locations from defaults
--- Called during mod load, before addons register their carts
local function initializeDefaults()
    for roomName, entries in pairs(DEFAULT_SPAWN_LOCATIONS) do
        SaucedCarts.SpawnLocations[roomName] = {}
        for _, entry in ipairs(entries) do
            table.insert(SaucedCarts.SpawnLocations[roomName], {
                type = entry.type,
                chance = entry.chance,
            })
        end
    end
    SaucedCarts.debug(function() return "SpawnLocations initialized with " .. SaucedCarts.getSpawnLocationCount() .. " room(s)" end)
end

-- ============================================================================
-- SPAWN LOCATION API
-- ============================================================================

--- Add spawn entries for a cart type from registration data
--- Called by CartData.lua when a cart with spawnRooms is registered
---@param fullType string Full cart type (e.g., "MyMod.MyCart")
---@param spawnRooms table Array of {room, chance} entries
function SaucedCarts.addSpawnRooms(fullType, spawnRooms)
    if not spawnRooms or type(spawnRooms) ~= "table" then return end

    local added = 0
    for _, entry in ipairs(spawnRooms) do
        local roomName = entry.room
        local chance = entry.chance or 25  -- Default 25% if not specified

        if roomName and type(roomName) == "string" and roomName ~= "" then
            -- Ensure room entry exists
            if not SaucedCarts.SpawnLocations[roomName] then
                SaucedCarts.SpawnLocations[roomName] = {}
            end

            -- Check for duplicate (same cart type in same room)
            local isDuplicate = false
            for _, existing in ipairs(SaucedCarts.SpawnLocations[roomName]) do
                if existing.type == fullType then
                    isDuplicate = true
                    -- Update chance if duplicate found
                    existing.chance = chance
                    break
                end
            end

            if not isDuplicate then
                table.insert(SaucedCarts.SpawnLocations[roomName], {
                    type = fullType,
                    chance = math.max(1, math.min(100, chance)),  -- Clamp 1-100
                    -- Forward addon opt-out flags so the server-side spawn
                    -- filter can honour per-cart-type intent.
                    allowResidential     = entry.allowResidential == true,
                    allowOutdoor         = entry.allowOutdoor == true,
                    skipFrameworkFilters = entry.skipFrameworkFilters == true,
                })
                added = added + 1
            end
        end
    end

    if added > 0 then
        SaucedCarts.debug(function() return string.format("Added %d spawn room(s) for %s", added, fullType) end)
    end
end

--- Get spawn entries for a room
---@param roomName string The room name (e.g., "gigamart")
---@return SpawnEntry[]|nil Array of spawn entries, or nil if no spawns for room
function SaucedCarts.getSpawnEntriesForRoom(roomName)
    return SaucedCarts.SpawnLocations[roomName]
end

--- Get total count of spawn locations
---@return number
function SaucedCarts.getSpawnLocationCount()
    local count = 0
    for _ in pairs(SaucedCarts.SpawnLocations) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- BUILDING-SIGNATURE SPAWN FILTER
-- ============================================================================
-- Pure function form so WorldSpawning (server) and DebugCommands (client) can
-- both call it, and offline pz-test-kit tests can exercise it without a real
-- IsoGridSquare. Reads from PZ's built-in BuildingDef methods
-- (isResidential / isShop) — no hand-rolled room-name tables.
--
-- Decision flow per (building, entry):
--   skipFrameworkFilters=true on entry  -> always allow (addon opt-out)
--   no building (outdoor square)        -> allow iff entry.allowOutdoor
--   StrictShopOnly sandbox + !isShop    -> deny
--   isResidential && !allowResidential  -> deny
--   otherwise                           -> allow
--
-- Nil-safe: if any link in the chain is missing (def nil, method absent on
-- the def mock, etc.) the filter degrades to allow — better to occasionally
-- over-spawn than to block the entire spawn pipeline when PZ surfaces a
-- surprise.

---@class SpawnEligibility
---@field allowed boolean Whether the spawn is permitted.
---@field reason string Short tag describing which layer made the call.

local function isStrictShopOnly()
    return SandboxVars.SaucedCarts
        and SandboxVars.SaucedCarts.StrictShopOnly == true
end

--- Evaluate whether a given spawn entry may fire in a given IsoBuilding.
--- Nil building means outdoor square (no getBuilding()).
---@param building any|nil IsoBuilding (or nil for outdoor)
---@param entry SpawnEntry The spawn entry being evaluated
---@return SpawnEligibility
function SaucedCarts.evaluateSpawnEligibility(building, entry)
    if not entry then
        return { allowed = false, reason = "missing_entry" }
    end

    -- Addon escape hatch: skip all framework filters.
    if entry.skipFrameworkFilters then
        return { allowed = true, reason = "skipFrameworkFilters" }
    end

    -- Outdoor squares have no building. Default behaviour: deny to avoid
    -- parking-lot / road spawns unless the entry explicitly opts in.
    if not building then
        if entry.allowOutdoor then
            return { allowed = true, reason = "outdoor_allowed" }
        end
        return { allowed = false, reason = "outdoor_denied" }
    end

    local def = building.getDef and building:getDef()
    if not def then
        -- Can't inspect the building — degrade to allow. This matches the
        -- pre-filter behaviour so mods relying on buildings that don't
        -- expose a def don't suddenly break.
        return { allowed = true, reason = "no_def_degraded_allow" }
    end

    -- Optional Layer 4: strict positive filter. Sandbox off by default.
    if isStrictShopOnly() then
        local isShop = def.isShop and def:isShop()
        if not isShop then
            return { allowed = false, reason = "not_shop_strict" }
        end
    end

    -- Layer 1: residential rejection. PZ's isResidential() returns true if
    -- the building contains a "bedroom" room — catches houses + apartments.
    local isResidential = def.isResidential and def:isResidential()
    if isResidential and not entry.allowResidential then
        return { allowed = false, reason = "residential_denied" }
    end

    return { allowed = true, reason = "passed_all_filters" }
end

--- Convenience wrapper: boolean-only answer.
---@param building any|nil IsoBuilding or nil
---@param entry SpawnEntry
---@return boolean
function SaucedCarts.canSpawnInBuilding(building, entry)
    return SaucedCarts.evaluateSpawnEligibility(building, entry).allowed
end

-- ============================================================================
-- VANILLA ROOM DISCOVERY (for addon authors)
-- ============================================================================
-- Thin wrapper over PZ's ItemPickerJava.hasDistributionForRoom() — the
-- authoritative "is this a real PZ room?" check. Rooms must appear in
-- media/lua/server/Items/Distributions.lua to have a distribution table;
-- mappers and mods register their room tags there.
--
-- Use this before registering spawnRooms to avoid phantom entries that
-- silently never fire. Example:
--
--     local rooms = { "grocery", "supermarket", "garagestorage" }
--     for _, name in ipairs(rooms) do
--         if not SaucedCarts.isVanillaRoom(name) then
--             print("warning: '" .. name .. "' is not a vanilla PZ room")
--         end
--     end

--- Check whether a room name has a vanilla distribution entry.
--- Returns false if ItemPickerJava isn't available (offline/stubbed env).
---@param roomName string
---@return boolean
function SaucedCarts.isVanillaRoom(roomName)
    if type(roomName) ~= "string" or roomName == "" then return false end
    if type(ItemPickerJava) ~= "table" and type(ItemPickerJava) ~= "userdata" then
        return false  -- Not running under real PZ — can't check.
    end
    if type(ItemPickerJava.hasDistributionForRoom) ~= "function" then
        return false
    end
    local ok, has = pcall(ItemPickerJava.hasDistributionForRoom, roomName)
    return ok and has == true
end

--- Validate every default/registered room name and return the phantom
--- entries (names that have no vanilla distribution). Useful for addon
--- authors debugging "why doesn't my cart spawn?" — and for our own
--- tests asserting the default list stays clean.
---@return string[] phantom room names
function SaucedCarts.getPhantomSpawnRooms()
    local phantom = {}
    for roomName in pairs(SaucedCarts.SpawnLocations) do
        if not SaucedCarts.isVanillaRoom(roomName) then
            table.insert(phantom, roomName)
        end
    end
    table.sort(phantom)
    return phantom
end

--- Get all room names that can spawn carts
---@return string[]
function SaucedCarts.getSpawnRoomNames()
    local rooms = {}
    for roomName, _ in pairs(SaucedCarts.SpawnLocations) do
        table.insert(rooms, roomName)
    end
    table.sort(rooms)
    return rooms
end

-- ============================================================================
-- MODULE INITIALIZATION
-- ============================================================================

-- Initialize default spawn locations
initializeDefaults()

-- ============================================================================
-- LATE REGISTRATION PROCESSING
-- ============================================================================
-- If CartData.lua loaded before SpawnLocations.lua, cart types may have been
-- registered with spawnRooms that couldn't be added yet. Process them now.
--
-- NOTE: We don't need to check for duplicates here because addSpawnRooms()
-- already has per-room duplicate detection built in (updates chance if exists).
local function processExistingCartSpawnRooms()
    if not SaucedCarts.CartTypes then return end

    local processed = 0
    for fullType, cartData in pairs(SaucedCarts.CartTypes) do
        if cartData.spawnRooms and type(cartData.spawnRooms) == "table" and #cartData.spawnRooms > 0 then
            -- addSpawnRooms handles per-room duplicates internally
            -- (if cart already exists in a room, it updates the chance instead of adding)
            SaucedCarts.addSpawnRooms(fullType, cartData.spawnRooms)
            processed = processed + 1
        end
    end

    if processed > 0 then
        SaucedCarts.debug(function() return string.format("SpawnLocations: Processed %d late-registered cart type(s)", processed) end)
    end
end

processExistingCartSpawnRooms()

SaucedCarts.debug("SpawnLocations loaded")

return SaucedCarts.SpawnLocations
