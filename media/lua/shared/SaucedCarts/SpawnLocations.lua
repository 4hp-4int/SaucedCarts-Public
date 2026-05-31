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
---@field allowOutdoor boolean|nil Eligibility-filter hint only: lets `evaluateSpawnEligibility` pass an entry on an outdoor (no-building) square. Outdoor cart placement itself is NOT driven per-room anymore — it is zone-anchored (vehicle zones: lots/driveways) and per-cart-type via `registerCart{ outdoorWeight }`. See `decideZoneSpawns` / `getOutdoorCartPool`.
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
    -- chance = per-building INTERIOR spawn probability. Outdoor (parking-lot)
    -- carts are handled separately by the vehicle-zone spawner, not per room.
    ["gigamart"]          = { { type = SC, chance = 80 } },
    ["grocery"]           = { { type = SC, chance = 70 } },
    ["departmentstore"]   = { { type = SC, chance = 60 } },

    -- Canonical back-of-house storage.
    ["grocerystorage"]    = { { type = SC, chance = 55 } },
    ["warehouse"]         = { { type = SC, chance = 50 } },
    ["departmentstorage"] = { { type = SC, chance = 45 } },
    ["producestorage"]    = { { type = SC, chance = 45 } },

    -- Major retail with plausible carts
    ["housewarestore"]    = { { type = SC, chance = 45 } },
    ["toolstore"]         = { { type = SC, chance = 40 } },
    ["gardenstore"]       = { { type = SC, chance = 40 } },
    ["furniturestore"]    = { { type = SC, chance = 32 } },
    ["furniturestorage"]  = { { type = SC, chance = 32 } },
    ["outdoorsupply"]     = { { type = SC, chance = 30 } },
    ["carsupply"]         = { { type = SC, chance = 30 } },
    ["generalstore"]      = { { type = SC, chance = 30 } },
    ["electronicstore"]   = { { type = SC, chance = 28 } },
    ["giftstore"]         = { { type = SC, chance = 22 } },

    -- Secondary retail + minor storage
    ["liquorstore"]          = { { type = SC, chance = 20 } },
    ["petstore"]             = { { type = SC, chance = 20 } },
    ["clothingstorage"]      = { { type = SC, chance = 20 } },
    ["generalstorestorage"]  = { { type = SC, chance = 20 } },
    ["camping"]              = { { type = SC, chance = 20 } },
    ["campingstorage"]       = { { type = SC, chance = 20 } },
    ["giftstorage"]          = { { type = SC, chance = 20 } },
    ["outdoorsupply_storage"] = { { type = SC, chance = 20 } },
    ["clothingstore"]        = { { type = SC, chance = 15 } },
    ["sportstore"]           = { { type = SC, chance = 15 } },

    -- Commercial storage / utility. The building-signature filter rejects
    -- residential buildings, so these only fire for commercial garages
    -- (car dealers, mechanic shops), standalone storage facilities, and
    -- commercial sheds. These building types are VERY common in the world but
    -- were rolling too rarely to feel findable, so the floor was raised (v2.1.11
    -- hotfix). Under the one-binary-roll-per-building model, chance is a true
    -- per-building hit rate independent of MaxCartsPerBuilding (cap controls
    -- COUNT on a hit, not frequency), so raising these no longer risks the
    -- cap-multiplied flooding that forced the old low values.
    ["storageunit"]       = { { type = SC, chance = 25 } },
    ["garagestorage"]     = { { type = SC, chance = 20 } },
    ["storage"]           = { { type = SC, chance = 15 } },
    ["shed"]              = { { type = SC, chance = 8 } },

    -- Flavor — uncommon but findable
    ["bookstore"]         = { { type = SC, chance = 12 } },
    ["conveniencestore"]  = { { type = SC, chance = 15 } },
    ["cornerstore"]       = { { type = SC, chance = 15 } },
    ["lobby"]             = { { type = SC, chance = 6 } },
    ["pawnshop"]          = { { type = SC, chance = 8 } },

    -- ── v2.1.11 coverage expansion ──────────────────────────────────────────
    -- Additional storefronts with plausible shopping/flatbed carts. Drugstores
    -- and big toy stores stock real shopping carts; BBQ/paint/auto-parts are
    -- flatbed-cart retail. The larger ones front parking lots → opt outdoor.
    ["toystore"]            = { { type = SC, chance = 32 } },
    ["pharmacy"]            = { { type = SC, chance = 30 } },
    ["carsupplysport"]      = { { type = SC, chance = 30 } },
    ["ww_toolstore"]        = { { type = SC, chance = 40 } },  -- map variant of toolstore
    ["ww_generalstore"]     = { { type = SC, chance = 30 } },  -- map variant of generalstore
    ["barbecuestore"]       = { { type = SC, chance = 25 } },
    ["paintershop"]         = { { type = SC, chance = 25 } },
    ["gunstore"]            = { { type = SC, chance = 18 } },
    ["plazastore1"]         = { { type = SC, chance = 18 } },
    ["leatherclothesstore"] = { { type = SC, chance = 15 } },
    ["baseballstore"]       = { { type = SC, chance = 15 } },
    ["golfstore"]           = { { type = SC, chance = 12 } },

    -- Gas-station convenience marts (mirror conveniencestore).
    ["gasstore"]            = { { type = SC, chance = 15 } },
    ["gas2go"]              = { { type = SC, chance = 15 } },
    ["zippeestore"]         = { { type = SC, chance = 15 } },

    -- Flavor specialty — small footprint, uncommon.
    ["artstore"]            = { { type = SC, chance = 12 } },
    ["shoestore"]           = { { type = SC, chance = 12 } },
    ["camerastore"]         = { { type = SC, chance = 12 } },
    ["candystore"]          = { { type = SC, chance = 10 } },
    ["comicstore"]          = { { type = SC, chance = 10 } },
    ["musicstore"]          = { { type = SC, chance = 10 } },
    ["knifestore"]          = { { type = SC, chance = 10 } },
    ["tobaccostore"]        = { { type = SC, chance = 10 } },

    -- Back-of-house storage for cart-using retail (staff keep carts here).
    -- Residential filter still applies; these only fire for commercial bldgs.
    ["toolstorestorage"]    = { { type = SC, chance = 32 } },
    ["toystorestorage"]     = { { type = SC, chance = 25 } },
    ["pharmacystorage"]     = { { type = SC, chance = 22 } },
    ["electronicsstorage"]  = { { type = SC, chance = 20 } },
    ["medicalstorage"]      = { { type = SC, chance = 20 } },
    ["hospitalstorage"]     = { { type = SC, chance = 20 } },  -- hospitals run on utility carts
    ["gunstorestorage"]     = { { type = SC, chance = 18 } },
    ["potatostorage"]       = { { type = SC, chance = 18 } },
    ["sportstorage"]        = { { type = SC, chance = 15 } },
    ["candystorage"]        = { { type = SC, chance = 12 } },
    ["gasstorage"]          = { { type = SC, chance = 12 } },

    -- Agricultural — wheelbarrows/carts.
    ["farmstorage"]         = { { type = SC, chance = 20 } },

    -- Industrial loading docks + yards. Curated to bulk-goods rooms — tiny
    -- specialty factories (bat/wire/map/mannequin) are skipped since a shopping
    -- cart there is implausible.
    ["loggingwarehouse"]    = { { type = SC, chance = 30 } },
    ["factory"]             = { { type = SC, chance = 28 } },
    ["factorystorage"]      = { { type = SC, chance = 28 } },
    ["loggingfactory"]      = { { type = SC, chance = 22 } },
    ["cabinetshipping"]     = { { type = SC, chance = 22 } },
    ["dogfoodshipping"]     = { { type = SC, chance = 20 } },
    ["golfshipping"]        = { { type = SC, chance = 20 } },
    ["jerkyshipping"]       = { { type = SC, chance = 20 } },
    ["knifeshipping"]       = { { type = SC, chance = 20 } },
    ["radioshipping"]       = { { type = SC, chance = 20 } },

    -- Commercial garages — apparatus/vehicle bays, utility carts.
    ["firegarage"]          = { { type = SC, chance = 15 } },
    ["policegarage"]        = { { type = SC, chance = 15 } },
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
-- Per-building INTERIOR spawn math, extracted from WorldSpawning so it can be
-- unit-tested offline without mocking the world. Pure spawn policy, no
-- server/world deps. WorldSpawning passes ZombRand as the rng; tests pass a
-- scripted rng for deterministic dice.
--
-- Outdoor (parking-lot / driveway) placement is NO LONGER decided here. It is
-- zone-anchored — carts spawn directly in vehicle zones the way vanilla spawns
-- cars (see decideZoneSpawns + the vehicle-zone pass in WorldSpawning),
-- independent of buildings.
--
-- Model: ONE binary roll per building decides whether it spawns any carts
-- (chance is a true per-building probability). On a hit, count is uniform
-- [1, MaxCartsPerBuilding], and each cart picks a TYPE weighted by chance across
-- all eligible entries (so addon carts mix with the built-in cart). The
-- single-entry case skips the weighted pick to keep its RNG stream stable.

--- Decide which cart types a building spawns indoors.
---@param entries SpawnEntry[] eligible entries for the building (deduped by type)
---@param max number MaxCartsPerBuilding cap (count is uniform 1..max on a hit)
---@param multiplier number SandboxVars SpawnRate / 100
---@param rng fun(n:number):number returns an int in [0, n-1] like ZombRand
---@return string[] cart type strings, length = carts to spawn (empty if none)
function SaucedCarts.decideSpawnPlacements(entries, max, multiplier, rng)
    local picks = {}
    if not entries or #entries == 0 then return picks end

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
            picks[#picks + 1] = pick.type
        end
    end
    return picks
end

-- ============================================================================
-- ZONE-ANCHORED OUTDOOR SPAWN DICE (pure)
-- ============================================================================
-- Outdoor carts spawn directly in vehicle zones (parking lots, driveways,
-- trailer-park parking) — the same map zones vanilla spawns cars in — with NO
-- building involvement. These pure helpers back the vehicle-zone pass in
-- WorldSpawning so the geometry + dice stay offline-testable. We mirror
-- IsoChunk.AddVehicles (decompiled): walk the cell's vehicle zones overlapping
-- a chunk and roll per zone.

--- True if a zone (tile rect zx,zy size zw×zh) overlaps a chunk (chunk coords
--- chunkX,chunkY; chunks are 8 tiles). Direct port of the overlap test in
--- IsoChunk.AddVehicles (IsoChunk.java:1735).
---@return boolean
function SaucedCarts.zoneOverlapsChunk(zx, zy, zw, zh, chunkX, chunkY)
    local cox, coy = chunkX * 8, chunkY * 8
    return zx + zw >= cox and zy + zh >= coy and zx < cox + 8 and zy < coy + 8
end

--- Decide how many carts a vehicle zone spawns. Area-scaled: a big lot gets more
--- attempts than a single driveway. rolls = clamp(1, floor(area/areaPerRoll),
--- maxPerZone); each roll is an independent hit at chance*multiplier.
---@param area number zone tile area (zw*zh)
---@param chance number base per-roll percent
---@param multiplier number SpawnRate / 100
---@param maxPerZone number cap on carts per zone
---@param areaPerRoll number tiles of zone area per spawn roll
---@param rng fun(n:number):number
---@return number count of carts to place
function SaucedCarts.decideZoneSpawns(area, chance, multiplier, maxPerZone, areaPerRoll, rng)
    local rolls = math.floor((area or 0) / (areaPerRoll or 1))
    if rolls < 1 then rolls = 1 end
    if maxPerZone and rolls > maxPerZone then rolls = maxPerZone end
    local count = 0
    for _ = 1, rolls do
        if rng(100) < chance * multiplier then count = count + 1 end
    end
    return count
end

--- Weighted-random cart type from an outdoor pool ({ {type=, weight=}, ... }).
---@param pool table[] list of { type=string, weight=number }
---@param rng fun(n:number):number
---@return string|nil
function SaucedCarts.pickOutdoorCartType(pool, rng)
    if not pool or #pool == 0 then return nil end
    if #pool == 1 then return pool[1].type end
    local total = 0
    for _, e in ipairs(pool) do total = total + (e.weight or 0) end
    if total <= 0 then return pool[1].type end
    local r, cum = rng(total), 0
    for _, e in ipairs(pool) do
        cum = cum + (e.weight or 0)
        if r < cum then return e.type end
    end
    return pool[#pool].type
end

--- Build (cached) the outdoor cart pool from registered cart types. A cart type
--- joins the pool if its registration set `outdoorWeight > 0`. Built lazily and
--- cached only once the registry has at least one eligible type, so a call
--- before registration completes doesn't pin an empty pool.
---@return table[] list of { type=string, weight=number }
local outdoorPoolCache
function SaucedCarts.getOutdoorCartPool()
    if outdoorPoolCache then return outdoorPoolCache end
    local pool = {}
    local types = SaucedCarts.CartTypes
    if types then
        for fullType, data in pairs(types) do
            local w = data and data.outdoorWeight
            if type(w) == "number" and w > 0 then
                pool[#pool + 1] = { type = fullType, weight = w }
            end
        end
    end
    if #pool > 0 then outdoorPoolCache = pool end
    return pool
end

--- Drop the cached outdoor pool (test isolation / re-registration).
function SaucedCarts.resetOutdoorCartPool()
    outdoorPoolCache = nil
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
