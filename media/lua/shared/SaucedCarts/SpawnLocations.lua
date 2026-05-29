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
---@field allowOutdoor boolean|nil If true, opt this entry into the outdoor-placement-pool extension: when a building rolls a cart AND the same chunk has a `VehicleZone` square (parking lot), some placements land outside instead of inside. Default false — interior-only.
---@field outdoorWeight number|nil 0-100. Percentage of successful rolls that place the cart OUTSIDE (in a vehicle-zone square) instead of inside, when allowOutdoor is true and the chunk has at least one outdoor candidate. Default 30. Ignored when allowOutdoor is false/nil.
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
-- These chances are per-building binary probabilities under the
-- one-roll-per-building model (WorldSpawning.lua, v2.1.9+): each candidate
-- building gets ONE roll at the value below × SandboxVars.SaucedCarts
-- .SpawnRate to decide whether it spawns any carts today. On a hit, the
-- building spawns `1 + ZombRand(MaxCartsPerBuilding)` carts (uniform on
-- [1, cap]), and each cart independently picks interior vs. outdoor
-- placement via outdoorWeight when parking zones exist for the building.
-- Rates here are calibrated against cap=1 (the sandbox default) — raising
-- cap multiplies the count per spawned building, NOT the per-building hit
-- rate.
--
-- Residential buildings (apartment lobbies, houses with garages, etc.) are
-- rejected by the building-signature filter (evaluateSpawnEligibility →
-- BuildingDef.isResidential), so the rates here are effectively "commercial
-- only." Storage/garage rates can stay sensible without flooding houses —
-- the filter handles that, not a artificially low chance.
--
-- Tiers calibrated for findability + realism:
--   - Canonical retail (gigamart/grocery/departmentstore): most have a cart.
--   - Canonical storage (back-of-house of the above + warehouse): good chance.
--   - Major retail with plausible carts: moderate.
--   - Secondary retail: occasional.
--   - Commercial storage / utility (residential filtered by build flag): modest.
--   - Flavor: rare.
--
-- Addons register their own rooms (and may target residential / outdoor
-- squares via opt-out flags) via SaucedCarts.registerCart(..., spawnRooms).

local SC = "SaucedCarts.ShoppingCart"

local DEFAULT_SPAWN_LOCATIONS = {
    -- Canonical retail — carts ARE the default transport here.
    -- allowOutdoor + outdoorWeight: a fraction of successful rolls place the
    -- cart in the parking lot (chunk-coincident vehicle zone) instead of inside.
    ["gigamart"]          = { { type = SC, chance = 80, allowOutdoor = true, outdoorWeight = 50 } },
    ["grocery"]           = { { type = SC, chance = 60, allowOutdoor = true, outdoorWeight = 50 } },
    ["departmentstore"]   = { { type = SC, chance = 50, allowOutdoor = true, outdoorWeight = 40 } },

    -- Canonical back-of-house storage (loading-dock outdoor placement when a
    -- vehicle zone overlaps the ring — typically rarer than retail frontage).
    ["grocerystorage"]    = { { type = SC, chance = 50, allowOutdoor = true, outdoorWeight = 30 } },
    ["warehouse"]         = { { type = SC, chance = 40, allowOutdoor = true, outdoorWeight = 35 } },
    ["departmentstorage"] = { { type = SC, chance = 35 } },
    ["producestorage"]    = { { type = SC, chance = 35 } },

    -- Major retail with plausible carts
    ["housewarestore"]    = { { type = SC, chance = 30 } },
    ["toolstore"]         = { { type = SC, chance = 25 } },
    ["gardenstore"]       = { { type = SC, chance = 25 } },
    ["furniturestore"]    = { { type = SC, chance = 20 } },
    ["furniturestorage"]  = { { type = SC, chance = 20 } },
    ["outdoorsupply"]     = { { type = SC, chance = 18 } },
    ["carsupply"]         = { { type = SC, chance = 18 } },
    ["generalstore"]      = { { type = SC, chance = 18 } },
    ["electronicstore"]   = { { type = SC, chance = 18 } },
    ["giftstore"]         = { { type = SC, chance = 12 } },

    -- Secondary retail + minor storage
    ["liquorstore"]          = { { type = SC, chance = 10 } },
    ["petstore"]             = { { type = SC, chance = 10 } },
    ["clothingstorage"]      = { { type = SC, chance = 10 } },
    ["generalstorestorage"]  = { { type = SC, chance = 10 } },
    ["camping"]              = { { type = SC, chance = 10 } },
    ["campingstorage"]       = { { type = SC, chance = 10 } },
    ["giftstorage"]          = { { type = SC, chance = 10 } },
    ["outdoorsupply_storage"] = { { type = SC, chance = 10 } },
    ["clothingstore"]        = { { type = SC, chance = 6 } },
    ["sportstore"]           = { { type = SC, chance = 6 } },

    -- Commercial storage / utility. The building-signature filter rejects
    -- residential buildings, so these only fire for commercial garages
    -- (car dealers, mechanic shops), standalone storage facilities, and
    -- commercial sheds. Rates kept low because under MaxCartsPerBuilding > 1
    -- each independent roll compounds — a 12% rate with cap=5 produces
    -- ~47% of buildings getting at least one cart, which felt too dense in
    -- play. Tuned so even at cap=5 storage feels like a treat, not a flood.
    ["storageunit"]       = { { type = SC, chance = 8 } },
    ["garagestorage"]     = { { type = SC, chance = 5 } },
    ["storage"]           = { { type = SC, chance = 4 } },
    ["shed"]              = { { type = SC, chance = 1 } },

    -- Flavor — rare-to-never
    ["bookstore"]         = { { type = SC, chance = 5 } },
    ["conveniencestore"]  = { { type = SC, chance = 5 } },
    ["cornerstore"]       = { { type = SC, chance = 5 } },
    ["lobby"]             = { { type = SC, chance = 2 } },
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
                -- Forward optional fields so DEFAULT_SPAWN_LOCATIONS can use
                -- them without addons being the only callers.
                allowResidential     = entry.allowResidential or nil,
                allowOutdoor         = entry.allowOutdoor or nil,
                outdoorWeight        = entry.outdoorWeight,
                skipFrameworkFilters = entry.skipFrameworkFilters or nil,
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
                    -- 0-100, clamped. Only meaningful when allowOutdoor=true.
                    outdoorWeight        = entry.outdoorWeight and
                        math.max(0, math.min(100, entry.outdoorWeight)) or nil,
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

--- True if any registered spawn entry (default OR addon-added) opts into the
--- outdoor placement pool. Used by WorldSpawning as a cheap precheck: if no
--- entry allows outdoor, the chunk pass skips outdoor collection entirely.
---@return boolean
function SaucedCarts.anyEntryAllowsOutdoor()
    for _, entries in pairs(SaucedCarts.SpawnLocations) do
        for _, e in ipairs(entries) do
            if e.allowOutdoor then return true end
        end
    end
    return false
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
-- SPAWN DICE (pure)
-- ============================================================================
-- The per-building probability math, extracted from WorldSpawning's onLoadChunk
-- so it can be unit-tested offline without mocking the world. Lives here beside
-- evaluateSpawnEligibility because, like that filter, it's pure spawn policy with
-- no server/world dependencies. WorldSpawning passes ZombRand as the rng; tests
-- pass a scripted rng for deterministic dice.
--
-- v2.1.9 model: ONE binary roll per building decides whether it spawns any carts
-- (chance is a true per-building probability, not a per-roll knob). On a hit, the
-- count is uniform [1, MaxCartsPerBuilding], and each cart independently picks a
-- TYPE (weighted by chance, across all eligible entries) and then an interior-vs-
-- outdoor placement via that type's outdoorWeight (only when parking zones exist).
--
-- Addon mixing: takes a LIST of eligible entries so addon-registered cart types
-- mix with the built-in cart in shared rooms. The building's hit rate is the MAX
-- chance among its entries (so adding addons varies the type mix WITHOUT
-- inflating how often a building has a cart) — which makes the single-entry case
-- byte-identical to before, including the RNG stream (the weighted type pick is
-- skipped entirely when there's only one entry).
--
-- Returns placement *intent* only; actual interior/outdoor depends on square
-- availability at queue time (an "outdoor" intent that can't find a lot square
-- falls back to interior downstream).

--- Decide how many carts a building spawns, and per cart its type + placement.
---@param entries SpawnEntry[] eligible entries for the building (deduped by type)
---@param max number MaxCartsPerBuilding cap (count is uniform 1..max on a hit)
---@param multiplier number SandboxVars SpawnRate / 100
---@param outdoorReady boolean true if parking zones were found for the building
---@param rng fun(n:number):number returns an int in [0, n-1] like ZombRand
---@return table[] placements list of { type=string, kind="interior"|"outdoor" }; empty if no spawn
function SaucedCarts.decideSpawnPlacements(entries, max, multiplier, outdoorReady, rng)
    local placements = {}
    if not entries or #entries == 0 then return placements end

    -- Building hit rate = max chance; total chance = weighted-pick denominator.
    local buildingChance, totalWeight = 0, 0
    for _, e in ipairs(entries) do
        if e.chance > buildingChance then buildingChance = e.chance end
        totalWeight = totalWeight + e.chance
    end

    if rng(100) < buildingChance * multiplier then
        local count = 1 + rng(max)            -- uniform 1..max
        local single = #entries == 1
        for _ = 1, count do
            -- Weighted type pick by chance. Skipped for the single-entry case so
            -- a base-only setup consumes the exact same RNG sequence as before.
            local pick = entries[1]
            if not single and totalWeight > 0 then
                local r, cum = rng(totalWeight), 0
                for _, e in ipairs(entries) do
                    cum = cum + e.chance
                    if r < cum then pick = e; break end
                end
            end
            -- Interior vs. outdoor: only types that opt in can land outside, and
            -- the per-cart outdoor roll is consumed only when that's possible.
            local kind = "interior"
            if outdoorReady and pick.allowOutdoor and rng(100) < (pick.outdoorWeight or 30) then
                kind = "outdoor"
            end
            placements[#placements + 1] = { type = pick.type, kind = kind }
        end
    end
    return placements
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
