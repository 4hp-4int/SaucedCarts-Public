-- ============================================================================
-- SaucedCarts/WorldSpawning.lua
-- ============================================================================
-- PURPOSE: Spawns carts on the ground in appropriate locations (stores, warehouses).
--          Uses LoadGridsquare event with queue system for performance.
--
-- CONTEXT: SERVER ONLY
--          World spawning must happen server-side for MP sync.
--
-- FORWARD COMPATIBILITY:
--          - Schema version tracks ModData format changes
--          - Graceful handling of missing/corrupted ModData
--          - Building-level tracking (simpler than per-square)
--
-- DESIGN NOTES:
--          - Cart spawn count per building is configurable via sandbox
--          - Queue system processes spawns over multiple ticks (no frame drops)
--          - ModData persists across saves (no respawning in same building)
-- ============================================================================

-- Block only pure MP clients (not self-hosted hosts)
-- In self-hosted MP, both isClient() and isServer() are true
if isClient() and not isServer() then return end

require "SaucedCarts/Core"
require "SaucedCarts/SpawnLocations"
require "SaucedCarts/CartVisuals"

-- Log load confirmation (helpful for MP debugging)
SaucedCarts.debug(string.format(
    "WorldSpawning: Loading (isClient=%s, isServer=%s)",
    tostring(isClient()), tostring(isServer())
))

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local MODDATA_KEY = "SaucedCarts_WorldSpawning"
local SCHEMA_VERSION = 2  -- v2: Changed from boolean to count tracking
local MAX_SPAWNS_PER_TICK = SaucedCarts.Config.MAX_SPAWNS_PER_TICK
local TICK_INTERVAL = SaucedCarts.Config.SPAWN_TICK_INTERVAL
local MAX_QUEUE_SIZE = SaucedCarts.Config.MAX_SPAWN_QUEUE_SIZE

-- ============================================================================
-- STATE
-- ============================================================================

local WorldSpawning = {}

-- Queue of pending spawn requests
-- Each entry: { square = IsoGridSquare, cartType = string, buildingKey = string }
local spawnQueue = {}

-- Tick counter for queue processing
local tickCounter = 0

-- Building registry, populated once per session at OnLoadMapZones (after PZ
-- consolidates BuildingDefs from the meta-grid). Mirrors vanilla's vehicle-
-- spawning pattern: pre-index spawn candidates against their containing
-- chunks, so the LoadChunk handler does an O(1) lookup instead of walking the
-- chunk's 64 squares to discover rooms.
--
--   candidateBuildings: bkey -> { def, roomName, entries, anyOutdoor }
--     One record per cart-eligible BuildingDef. `entries` is ALL eligible spawn
--     entries for the building (deduped by cart type, across every cart-eligible
--     room it contains) so addon-registered cart types mix with the built-in
--     cart at decision time (see decideSpawnPlacements). `anyOutdoor` is true if
--     any of those entries opts into parking-lot placement. `roomName` is the
--     first matched room, kept for the interior debug tag only. (Rooms are
--     re-walked from the def at decision time — see pickInteriorSquare — so a
--     gigamart's many "gigamart"-named rects all contribute placement squares.)
--
--   chunkBuildingIndex: "chunkX,chunkY" -> { bkey, ... }
--     Reverse lookup. Most chunks have no entry (instant early-return);
--     chunks with at least one cart-eligible building yield a small list.
---@type table<string, {def: any, roomName: string, entries: SpawnEntry[], anyOutdoor: boolean}>
local candidateBuildings = {}
---@type table<string, string[]>
local chunkBuildingIndex = {}
local buildingIndexReady = false

-- One-time guard for the chunk-coordinate sanity check (see onLoadChunk). The
-- index keys chunks as floor(squareX/8); the lookup reads chunk.wx. Those match
-- in B42 (8-wide chunks, wx is a chunk index), but if a PZ update changes chunk
-- geometry or wx semantics, every lookup would silently miss and nothing would
-- spawn — with no error. We cross-check once per session and log loudly on
-- divergence. Reset on OnGameEnd so a save-switch re-validates.
local chunkCoordChecked = false

-- ============================================================================
-- MODDATA PERSISTENCE (Lazy initialization pattern from BurdJournals)
-- Must be defined BEFORE functions that use getSpawnedBuildings()
-- ============================================================================

--- Get or create the spawn tracking ModData table
--- Uses lazy initialization - creates on first access, no event handler needed
---@return table The ModData table with spawnedBuildings
local function getSpawnData()
    local data = ModData.getOrCreate(MODDATA_KEY)

    -- Ensure structure exists
    if not data.spawnedBuildings then
        data.spawnedBuildings = {}
        data.schemaVersion = SCHEMA_VERSION
        SaucedCarts.debug("WorldSpawning: Created new ModData")
    end

    -- Migrate if needed (v1 -> v2: boolean to count)
    local version = data.schemaVersion or 0
    if version < SCHEMA_VERSION and type(data.spawnedBuildings) == "table" then
        SaucedCarts.debug(function() return string.format(
            "WorldSpawning: Migrating ModData from v%d to v%d",
            version, SCHEMA_VERSION
        ) end)

        local migrated = 0
        local keysToRemove = {}

        for key, value in pairs(data.spawnedBuildings) do
            if value == true then
                data.spawnedBuildings[key] = 1  -- Convert true to count
                migrated = migrated + 1
            elseif value == false or value == 0 or type(value) ~= "number" then
                table.insert(keysToRemove, key)
            end
        end

        for _, key in ipairs(keysToRemove) do
            data.spawnedBuildings[key] = nil
        end

        data.schemaVersion = SCHEMA_VERSION

        if migrated > 0 then
            SaucedCarts.debug(function() return string.format("WorldSpawning: Migrated %d building(s)", migrated) end)
        end
    end

    return data
end

--- Get the spawnedBuildings table (lazy access)
---@return table<string, number> Building keys to spawn counts
local function getSpawnedBuildings()
    return getSpawnData().spawnedBuildings
end

--- Persistence chokepoint for spawnedBuildings.
---
--- Intentionally a no-op: the table lives in global ModData via
--- ModData.getOrCreate, which PZ serializes to the save automatically — disk
--- persistence does NOT require a transmit. We previously broadcast the whole
--- (ever-growing) spawnedBuildings table to clients on every committed chunk,
--- but spawnedBuildings is purely server-side dedup state with zero client
--- readers (clients never spawn), so the transmit was O(N)-growing network
--- waste. If a client-side consumer is ever built (e.g. a spawn-preview UI),
--- re-add `ModData.transmit(MODDATA_KEY)` here — this is the single seam.
local function saveModData()
    -- no-op (see above)
end

-- ============================================================================
-- BUILDING KEY HELPERS
-- ============================================================================

--- Get a unique key for a building based on its definition origin
--- Returns nil if square is not in a building (outdoor areas)
---@param square IsoGridSquare
---@return string|nil
local function getBuildingKey(square)
    if not square then return nil end

    local building = square:getBuilding()
    if not building then return nil end

    local def = building:getDef()
    if not def then return nil end

    -- Use building definition origin as unique key
    return def:getX() .. "," .. def:getY()
end

--- Get the maximum carts per building from sandbox settings
---@return number
local function getMaxCartsPerBuilding()
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.MaxCartsPerBuilding then
        return SandboxVars.SaucedCarts.MaxCartsPerBuilding
    end
    return 1  -- Default
end

--- Check if a building has reached its cart spawn limit
---@param buildingKey string
---@return boolean True if building has reached max carts
local function hasBuildingReachedLimit(buildingKey)
    if not buildingKey then return false end
    local buildings = getSpawnedBuildings()
    local count = buildings[buildingKey] or 0
    -- No log here: this is called per eligible square, so a capped building
    -- (common for multi-chunk buildings) would burst-log on a chunk's first
    -- eval. The actual spawn ("Building X spawn count: ...") and the on-demand
    -- debug commands (checkCurrentBuilding/listTrackedBuildings) cover this.
    return count >= getMaxCartsPerBuilding()
end

--- Increment the cart count for a building
---@param buildingKey string
local function incrementBuildingCount(buildingKey)
    if not buildingKey then return end
    local buildings = getSpawnedBuildings()
    local oldCount = buildings[buildingKey] or 0
    buildings[buildingKey] = oldCount + 1
    SaucedCarts.debug(function() return string.format(
        "Building %s spawn count: %d -> %d (max: %d)",
        buildingKey, oldCount, oldCount + 1, getMaxCartsPerBuilding()
    ) end)
end

-- ============================================================================
-- SPAWN VALIDATION
-- ============================================================================

--- Check if a square is valid for spawning a cart
--- Must be walkable with adequate navigation space
---@param square IsoGridSquare
---@return boolean
local function isValidSpawnSquare(square)
    if not square then return false end

    -- Must be walkable (not blocked by furniture, walls, etc.)
    if not square:isFree(false) then return false end

    -- Must have adequate navigation space (at least 2 adjacent walkable squares)
    -- This ensures the cart isn't spawned in a corner or blocked area
    -- Use IsoDirections enum (N, E, S, W)
    local adjacentFree = 0
    local directions = {IsoDirections.N, IsoDirections.E, IsoDirections.S, IsoDirections.W}
    for _, dir in ipairs(directions) do
        local adj = square:getAdjacentSquare(dir)
        if adj and adj:isFree(false) then
            adjacentFree = adjacentFree + 1
        end
    end

    if adjacentFree < 2 then return false end

    -- Check if square already has a world item (prevent stacking)
    local objects = square:getWorldObjects()
    if objects and objects:size() > 0 then
        return false
    end

    return true
end

-- ============================================================================
-- SPAWN QUEUE
-- ============================================================================

--- Add a spawn request to the queue
--- Respects MAX_QUEUE_SIZE to prevent unbounded memory growth
---@param square IsoGridSquare
---@param cartType string
---@param buildingKey string
---@param roomName string|nil Room name for logging
---@return boolean queued Whether the spawn was queued (false if queue full)
local function queueSpawn(square, cartType, buildingKey, roomName)
    -- Prevent unbounded queue growth (e.g., teleporting to Louisville)
    if #spawnQueue >= MAX_QUEUE_SIZE then
        SaucedCarts.debug("WorldSpawning: Queue full, dropping spawn request")
        return false
    end

    table.insert(spawnQueue, {
        square = square,
        cartType = cartType,
        buildingKey = buildingKey,
    })

    SaucedCarts.debug(function() return string.format(
        "Queued %s spawn at %d,%d (building: %s, room: %s, queue: %d)",
        cartType,
        square:getX(), square:getY(),
        buildingKey or "outdoor",
        roomName or "unknown",
        #spawnQueue
    ) end)
    return true
end

--- Process pending spawn requests
--- Called from OnTick, processes up to MAX_SPAWNS_PER_TICK per call
--- ModData is saved/transmitted once at the end (batched for network efficiency)
local function processSpawnQueue()
    if #spawnQueue == 0 then return end

    local processed = 0
    local i = #spawnQueue

    while i >= 1 and processed < MAX_SPAWNS_PER_TICK do
        local request = spawnQueue[i]

        -- Re-validate square (may have changed since queued). The building's
        -- spawn decision was already committed in onLoadChunk, so there's no
        -- cap re-check or count bump here — just place the decided cart.
        if request.square and isValidSpawnSquare(request.square) then
            -- Spawn the cart with slight random offset for natural placement
            local offsetX = 0.3 + ZombRand(40) / 100  -- 0.3-0.7
            local offsetY = 0.3 + ZombRand(40) / 100  -- 0.3-0.7

            -- AddWorldInventoryItem params: (itemType, x, y, z, autoAge, synchSpawn)
            -- 5th param = autoAge (not used here, pass false)
            -- 6th param = synchSpawn (true for MP sync to all clients)
            -- Returns InventoryItem (NOT IsoWorldInventoryObject!)
            -- NOTE: Do NOT call transmitCompleteItemToClients() after this!
            -- Double-transmit causes duplicates in self-hosted MP.
            local cart = request.square:AddWorldInventoryItem(
                request.cartType,
                offsetX,
                offsetY,
                0,     -- Ground level (z offset)
                false, -- autoAge
                true   -- synchSpawn (transmit to clients)
            )

            if cart then
                -- Apply sandbox multipliers (stores raw capacity in ModData)
                SaucedCarts.applyMultipliers(cart)

                SaucedCarts.debug(function() return string.format(
                    "Spawned %s at %d,%d,%d (building %s)",
                    request.cartType,
                    request.square:getX(),
                    request.square:getY(),
                    request.square:getZ(),
                    request.buildingKey or "outdoor"
                ) end)

                -- Set empty model directly (new carts are always empty)
                local cartData = SaucedCarts.getCartData(cart)
                if cartData and cartData.visualModels and cartData.visualModels.empty then
                    cart:setStaticModel(cartData.visualModels.empty)
                    cart:setWorldStaticModel(cartData.visualModels.empty)
                end
                cart:getModData().SaucedCarts_fillState = "empty"

                processed = processed + 1
            end
        end

        -- Remove from queue (processed or invalid/failed - prevents infinite retry)
        table.remove(spawnQueue, i)
        i = i - 1
    end

    if processed > 0 then
        SaucedCarts.debug(function() return string.format(
            "WorldSpawning: Processed %d spawn(s), %d remaining in queue",
            processed, #spawnQueue
        ) end)
    end
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

-- Outdoor-pool ring radius in tiles, scanned around a building's bounding box
-- when deciding it. 12 = 1.5 chunk-widths, catches typical adjacent-chunk
-- parking. The dominant constraint is "are adjacent chunks loaded yet?" (see
-- pendingBuildings deferral below), not the radius itself. Cheap O(N^2) but
-- bounded by building size + radius.
local OUTDOOR_RING_RADIUS = 12

-- How many LoadChunk events to wait before giving up on finding outdoor
-- candidates and committing the building as interior-only. The building's
-- interior chunk almost always fires LoadChunk BEFORE the adjacent parking-lot
-- chunks stream in (chunks load nearest-to-player first; entering a store
-- means the interior is loaded first, parking comes second as the player turns
-- around or reloads the cell). Deferring 6 LoadChunks gives surrounding
-- chunks enough time to stream before we settle for interior-only.
local MAX_OUTDOOR_DEFER = 6

-- Buildings whose decision is in flight: indexed (chunk overlap matched) but
-- not yet committed. Holds the per-building chosen entry/room + an attempts
-- counter to drive the outdoor defer. Session-scoped — entries don't survive
-- a game-end, and they don't need to: the building's persistent record in
-- spawnedBuildings is also absent, so a session restart simply re-rolls.
---@type table<string, {data: table, attempts: number}>
local pendingBuildings = {}
-- Lua 5.1 has `next` for emptiness checks but Kahlua under PZ does not expose
-- it as a global in our scope. Maintain an explicit counter at every
-- insert/remove site so onLoadChunk's phase-2 fast-path stays O(1).
local pendingCount = 0

-- VehicleZone types we REJECT as outdoor placements. Everything else is a
-- parking lot of some flavor (parkingstall is the default, medium/good/bad
-- are wealth-tier parking, spiffo/mccoy/postal/etc. are franchise lots —
-- gigamart parking is commonly typed medium/good per the map, NOT
-- parkingstall, which is why an allow-list was too tight). See
-- media/lua/shared/VehicleZoneDefinition.lua. trafficjam* zones are
-- streets-with-stuck-cars (not parking) and burnt zones are junk piles.
local OUTDOOR_ZONE_TYPE_DENY = {
    trafficjamw = true, trafficjame = true,
    trafficjamn = true, trafficjams = true,
    normalburnt = true, specialburnt = true,
}

--- Walk a building's perimeter ring ONCE and collect the distinct
--- `VehicleZone` objects (filtered to parking-lot types) overlapping it.
--- Cached on the candidate's `outdoorZones` field. Subsequent decisions
--- reuse the cache — no more 1000-lookup ring scans per attempt.
---
--- Pure geometry: uses only the global `getVehicleZoneAt(x,y,z)` (queries
--- the metagrid's pre-loaded zone AABBs — does NOT require chunks to be
--- streamed). Safe to call from a LoadChunk before adjacent chunks load.
---@param data table candidate-building entry from candidateBuildings
---@return table|nil list of VehicleZone refs (or nil if none)
local function buildOutdoorZones(data)
    if data.outdoorZonesCached then return data.outdoorZones end
    data.outdoorZonesCached = true
    if not data.anyOutdoor or not getVehicleZoneAt then return nil end

    local def = data.def
    local bx, by = def:getX(), def:getY()
    local bw, bh = def:getW(), def:getH()
    local r = OUTDOOR_RING_RADIUS
    local x0, x1 = bx - r, bx + bw + r - 1
    local y0, y1 = by - r, by + bh + r - 1
    local zones
    local typesSeen = {}
    local seen = {}  -- "zx,zy" dedup key — Kahlua-safe (userdata as table key
                     -- is unreliable; build a string key from zone origin).
    for ny = y0, y1 do
        for nx = x0, x1 do
            if nx < bx or nx >= bx + bw or ny < by or ny >= by + bh then
                local zone = getVehicleZoneAt(nx, ny, 0)
                if zone then
                    local key = zone:getX() .. "," .. zone:getY()
                    if not seen[key] then
                        seen[key] = true
                        -- getType returns the explicit type or "parkingstall"
                        -- as the documented default. PZ may return it with
                        -- mixed case (e.g., "ParkingStall", "TrafficJamN") —
                        -- normalize to lowercase before comparing the deny list.
                        local raw = (zone.getType and zone:getType()) or "parkingstall"
                        local ztype = string.lower(raw)
                        typesSeen[raw] = (typesSeen[raw] or 0) + 1
                        if not OUTDOOR_ZONE_TYPE_DENY[ztype] then
                            zones = zones or {}
                            zones[#zones + 1] = zone
                        end
                    end
                end
            end
        end
    end
    data.outdoorZones = zones
    SaucedCarts.debug(function()
        local typeSummary = {}
        for t, n in pairs(typesSeen) do typeSummary[#typeSummary + 1] = t .. ":" .. n end
        return string.format(
            "  outdoor zone cache bldg=%d,%d -> %d accepted zone(s) [types: %s]",
            bx, by, zones and #zones or 0,
            #typeSummary > 0 and table.concat(typeSummary, ",") or "none")
    end)
    return zones
end

--- Pick a free outdoor placement square from the building's cached zones.
--- Asks PZ's `Zone:getRandomFreeSquareInZone` for a candidate; falls back to
--- nil if no zone's chunks are streamed yet (caller defers).
---@param data table
---@return IsoGridSquare|nil
local function pickOutdoorSquare(data)
    local zones = buildOutdoorZones(data)
    if not zones or #zones == 0 then return nil end
    -- Try each zone (up to first-pass count). Most allowOutdoor buildings
    -- have 1-2 zones; the loop is tiny.
    for _ = 1, #zones do
        local z = zones[ZombRand(#zones) + 1]
        local sq = z.getRandomFreeSquareInZone and z:getRandomFreeSquareInZone()
        if sq and isValidSpawnSquare(sq) then return sq end
    end
    return nil
end

--- Pick a placement square from any of the building's cart-eligible rooms.
--- Walks RoomDefs in order; for each whose name matches a registered spawn
--- entry, asks vanilla `RoomDef:getFreeSquare` then validates with our
--- isValidSpawnSquare. A gigamart's footprint typically contains several
--- "gigamart"-named RoomDef rects — only the rects in currently-loaded
--- chunks yield a square, so iterating gives streaming flexibility.
---@param data table candidate-building data (carries .def)
---@return IsoGridSquare|nil
local function pickInteriorSquare(data)
    local def = data.def
    local rooms = def and def.getRooms and def:getRooms()
    if not rooms then return nil end
    for j = 0, rooms:size() - 1 do
        local room = rooms:get(j)
        local name = room and room.getName and room:getName()
        if name and SaucedCarts.getSpawnEntriesForRoom(name) then
            local sq = room.getFreeSquare and room:getFreeSquare()
            if sq and isValidSpawnSquare(sq) then return sq end
            sq = room.getFreeUnoccupiedSquare and room:getFreeUnoccupiedSquare()
            if sq and isValidSpawnSquare(sq) then return sq end
        end
    end
    return nil
end

--- Build the candidateBuildings + chunkBuildingIndex from the meta-grid.
--- Fires once per session at OnLoadMapZones — by that point IsoMetaGrid has
--- consolidated all BuildingDefs (IsoWorld.java:1976 CreateStep2 ->
--- IsoMetaGrid.java:2090 consolidateBuildings -> 2294 CalculateBounds; the
--- LuaEventManager trigger at IsoWorld.java:1984 is fired right after). The
--- BuildingDef list is read-only thereafter for our purposes.
---
--- Per building: find the FIRST cart-eligible (allowlisted room name × passing
--- building-signature filter) (room, entry) pair and record it. Then for
--- every chunk that BuildingDef overlaps (vanilla pre-computes that via
--- BuildingDef.overlappedChunks; we use overlapsChunk() to confirm and the
--- bounding rect to enumerate candidates), append the buildingKey to the
--- chunk's bucket. Most chunks end up with no entry.
local function initBuildingIndex()
    if buildingIndexReady then return end
    if not getWorld or not getWorld() then return end
    local mg = getWorld():getMetaGrid()
    if not mg then return end
    local defs = mg:getBuildings()
    if not defs then return end

    local totalDefs = 0
    local indexedDefs = 0
    local indexedChunkKeys = 0

    for i = 0, defs:size() - 1 do
        totalDefs = totalDefs + 1
        local def = defs:get(i)
        local rooms = def and def.getRooms and def:getRooms()
        if def and rooms and rooms:size() > 0 then
            -- evaluateSpawnEligibility expects an IsoBuilding (it calls
            -- :getDef()). We have the def directly — wrap it.
            local wrap = { getDef = function() return def end }
            -- Collect EVERY eligible entry across the building's rooms, deduped
            -- by cart type, so addon carts mix with the built-in cart. (A type
            -- can appear in two of the building's rooms — gigamart + gigamart-
            -- kitchen — so the seenTypes guard keeps it single-weighted.)
            local matchedEntries, matchedRoomName, anyOutdoor
            local seenTypes = {}
            for j = 0, rooms:size() - 1 do
                local room = rooms:get(j)
                local roomName = room and room.getName and room:getName()
                if roomName then
                    local roomEntries = SaucedCarts.getSpawnEntriesForRoom(roomName)
                    if roomEntries then
                        for _, entry in ipairs(roomEntries) do
                            if not seenTypes[entry.type]
                                and SaucedCarts.evaluateSpawnEligibility(wrap, entry).allowed then
                                seenTypes[entry.type] = true
                                matchedEntries = matchedEntries or {}
                                matchedEntries[#matchedEntries + 1] = entry
                                matchedRoomName = matchedRoomName or roomName
                                if entry.allowOutdoor then anyOutdoor = true end
                            end
                        end
                    end
                end
            end

            if matchedEntries then
                indexedDefs = indexedDefs + 1
                local bkey = def:getX() .. "," .. def:getY()
                candidateBuildings[bkey] = {
                    def = def,
                    roomName = matchedRoomName,
                    entries = matchedEntries,
                    anyOutdoor = anyOutdoor == true,
                }

                -- Enumerate chunks via the bounding rect, confirm with
                -- BuildingDef:overlapsChunk (cheap pre-computed lookup).
                local bx, by = def:getX(), def:getY()
                local bw, bh = def:getW(), def:getH()
                local cx0 = math.floor(bx / 8)
                local cy0 = math.floor(by / 8)
                local cx1 = math.floor((bx + bw - 1) / 8)
                local cy1 = math.floor((by + bh - 1) / 8)
                for cx = cx0, cx1 do
                    for cy = cy0, cy1 do
                        if not def.overlapsChunk or def:overlapsChunk(cx, cy) then
                            local k = cx .. "," .. cy
                            local list = chunkBuildingIndex[k]
                            if not list then
                                list = {}
                                chunkBuildingIndex[k] = list
                                indexedChunkKeys = indexedChunkKeys + 1
                            end
                            list[#list + 1] = bkey
                        end
                    end
                end
            end
        end
    end

    buildingIndexReady = true
    SaucedCarts.log(string.format(
        "WorldSpawning: indexed %d/%d buildings across %d chunks",
        indexedDefs, totalDefs, indexedChunkKeys))
end

--- Handle LoadChunk event - look up the chunk's candidate buildings (O(1))
--- and decide each. Replaces the former 64-square scan with a hash lookup
--- against the pre-built candidateBuildings + chunkBuildingIndex tables.
---
--- Mirrors vanilla's vehicle spawning architecture: VehicleZones are
--- registered per-metacell at map load (IsoMetaGrid.java:814-835) and chunk
--- init calls `AddVehicles_OnZone` only for chunks that overlap a zone
--- (IsoChunk.java:929). Most chunks have no candidate building and the
--- handler returns in a single hash miss.
---@param chunk IsoChunk
local function onLoadChunk(chunk)
    -- Cheap sandbox gates (hoisted out of any inner work).
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then return end
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.EnableWorldSpawning == false then return end
    if not chunk then return end

    -- Build the index on first chunk if OnLoadMapZones never fired or fired
    -- before this module finished loading. Idempotent.
    if not buildingIndexReady then initBuildingIndex() end

    -- Derive chunk coords. IsoChunk exposes wx/wy as public fields; derive
    -- from a sample square as a portable fallback if the field path errors.
    local cx, cy
    local ok, wx = pcall(function() return chunk.wx end)
    if ok and wx then
        cy = chunk.wy
        cx = wx
        -- One-time invariant: chunk.wx must equal floor(squareX/8), or the index
        -- (keyed floor(bx/8)) and the lookup (chunk.wx) disagree and NOTHING
        -- spawns, silently. A single compare catches both a chunk-width change
        -- (wrong divisor) and a wx-semantics change. Log loudly, don't crash.
        if not chunkCoordChecked then
            chunkCoordChecked = true
            local sq = chunk:getGridSquare(0, 0, 0)
            if sq then
                local sx, sy = math.floor(sq:getX() / 8), math.floor(sq:getY() / 8)
                if cx ~= sx or cy ~= sy then
                    SaucedCarts.error(string.format(
                        "WorldSpawning: chunk coord invariant FAILED — chunk.wx,wy=%s,%s but floor(sqX/8),floor(sqY/8)=%s,%s. "
                        .. "Chunk geometry or wx semantics changed in a PZ update; world spawns will silently fail until "
                        .. "the /8 divisor + chunk.wx assumptions are revalidated.",
                        tostring(cx), tostring(cy), tostring(sx), tostring(sy)))
                end
            end
        end
    else
        local sq = chunk:getGridSquare(0, 0, 0)
        if not sq then return end
        cx = math.floor(sq:getX() / 8)
        cy = math.floor(sq:getY() / 8)
    end

    local key = cx .. "," .. cy
    local candidateKeys = chunkBuildingIndex[key]

    -- Phase 1: stash any not-yet-decided candidates from this chunk as pending.
    if candidateKeys then
        local buildings = getSpawnedBuildings()
        for _, bkey in ipairs(candidateKeys) do
            if buildings[bkey] == nil and not pendingBuildings[bkey] then
                pendingBuildings[bkey] = {
                    data = candidateBuildings[bkey],
                    attempts = 0,
                }
                pendingCount = pendingCount + 1
            end
        end
    end

    -- Phase 2: walk ALL pending buildings (across earlier chunks too) and
    -- decide each as soon as outdoor scan succeeds, or after MAX_OUTDOOR_DEFER
    -- attempts. Entries without allowOutdoor decide on first pass.
    if pendingCount == 0 then return end

    local multiplier = 1.0
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.SpawnRate then
        multiplier = SandboxVars.SaucedCarts.SpawnRate / 100
    end
    local outdoorEnabledGlobally =
        (not SandboxVars.SaucedCarts or SandboxVars.SaucedCarts.EnableOutdoorSpawns ~= false)
        and (SaucedCarts.anyEntryAllowsOutdoor and SaucedCarts.anyEntryAllowsOutdoor())

    local buildings = getSpawnedBuildings()
    local committed = false
    local max = getMaxCartsPerBuilding()

    for bkey, pending in pairs(pendingBuildings) do
        pending.attempts = pending.attempts + 1
        local data = pending.data

        -- Build (or reuse) the building's parking-zone cache. Pure geometry
        -- lookup — no chunk streaming required. Returns zones overlapping
        -- the building's ring, filtered to parking-stall types.
        local outdoorZones
        if outdoorEnabledGlobally and data.anyOutdoor then
            outdoorZones = buildOutdoorZones(data)
        end
        local outdoorReady = outdoorZones and #outdoorZones > 0
        local giveUp = pending.attempts >= MAX_OUTDOOR_DEFER

        if outdoorReady or giveUp or not data.anyOutdoor then
            local carts = 0
            local outdoorPlaced = 0
            -- Pure dice: one binary roll for "spawns today?", then a uniform
            -- 1..max count; each cart picks a TYPE (weighted by chance across
            -- all eligible entries, so addon carts mix in) and an interior/
            -- outdoor intent. See SaucedCarts.decideSpawnPlacements (shared,
            -- unit-tested). An "outdoor" intent that can't find a lot square
            -- falls back to interior here (placement depends on availability).
            local placements = SaucedCarts.decideSpawnPlacements(data.entries, max, multiplier, outdoorReady, ZombRand)
            for _, p in ipairs(placements) do
                local sq, isOutdoor
                if p.kind == "outdoor" then
                    sq = pickOutdoorSquare(data)
                    if sq then isOutdoor = true end
                end
                if not sq then
                    sq = pickInteriorSquare(data)
                end
                if sq then
                    queueSpawn(sq, p.type, bkey, isOutdoor and "outdoor" or data.roomName)
                    carts = carts + 1
                    if isOutdoor then outdoorPlaced = outdoorPlaced + 1 end
                end
            end
            buildings[bkey] = carts
            committed = true
            pendingBuildings[bkey] = nil
            pendingCount = pendingCount - 1
            SaucedCarts.debug(function() return string.format(
                "Decided building %s: %d cart(s) (%d outdoor) (attempts=%d)%s%s",
                bkey, carts, outdoorPlaced, pending.attempts,
                (outdoorReady and string.format(" [zones=%d]", #outdoorZones) or ""),
                (giveUp and not outdoorReady and entry.allowOutdoor and " [no zones found]" or "")
            ) end)
        end
    end

    if committed then saveModData() end
end

--- Handle OnTick event - process spawn queue
local function onTick()
    tickCounter = tickCounter + 1

    -- Only process every TICK_INTERVAL ticks
    if tickCounter >= TICK_INTERVAL then
        tickCounter = 0
        processSpawnQueue()
    end
end

-- No event handlers needed - ModData uses lazy initialization via getOrCreate()

-- ============================================================================
-- DEBUG API
-- ============================================================================

--- Force spawn a cart in the player's current room (debug only)
---@param roomType string|nil Room type to simulate (uses current room if nil)
function WorldSpawning.debugSpawnInRoom(roomType)
    if not SaucedCarts.isDebugEnabled() then return end

    local player = getPlayer()
    if not player then
        SaucedCarts.debug("DEBUG: No player found")
        return
    end

    local square = player:getCurrentSquare()
    if not square then
        SaucedCarts.debug("DEBUG: No square found")
        return
    end

    local room = square:getRoom()
    local actualRoomName = room and room:getName() or "outdoor"

    local targetRoom = roomType or actualRoomName
    local entries = SaucedCarts.getSpawnEntriesForRoom(targetRoom)

    if not entries or #entries == 0 then
        SaucedCarts.debug("DEBUG: No spawn entries for room '" .. targetRoom .. "'")
        SaucedCarts.debug("  Available rooms: " .. table.concat(SaucedCarts.getSpawnRoomNames(), ", "))
        return
    end

    -- Spawn first cart type for this room
    local entry = entries[1]
    local worldItem = square:AddWorldInventoryItem(entry.type, 0.5, 0.5, 0)

    if worldItem then
        SaucedCarts.debug("DEBUG: Spawned " .. entry.type .. " at player position")
    else
        SaucedCarts.debug("DEBUG: Failed to spawn cart")
    end
end

--- Get count of spawned buildings
---@return number
function WorldSpawning.getSpawnedBuildingCount()
    local count = 0
    for _ in pairs(getSpawnedBuildings()) do count = count + 1 end
    return count
end

--- Get queue size
---@return number
function WorldSpawning.getQueueSize()
    return #spawnQueue
end

--- Clear all spawn tracking (respawns enabled)
function WorldSpawning.clearSpawnTracking()
    if not SaucedCarts.isDebugEnabled() then return end
    local data = getSpawnData()
    data.spawnedBuildings = {}
    saveModData()
    for k in pairs(pendingBuildings) do pendingBuildings[k] = nil end
    pendingCount = 0
    SaucedCarts.debug("DEBUG: Cleared building decisions + pending - carts re-roll as chunks reload")
end

--- Show spawn status
function WorldSpawning.showStatus()
    if not SaucedCarts.isDebugEnabled() then return end
    SaucedCarts.debug("=== World Spawning Status ===")
    SaucedCarts.debug("  Buildings with carts: " .. WorldSpawning.getSpawnedBuildingCount())
    SaucedCarts.debug("  Queue size: " .. WorldSpawning.getQueueSize())
    SaucedCarts.debug("  Spawn locations: " .. SaucedCarts.getSpawnLocationCount() .. " room types")
    SaucedCarts.debug("  Max carts per building: " .. getMaxCartsPerBuilding())
    SaucedCarts.debug("=============================")
end

--- List all tracked buildings and their spawn counts
function WorldSpawning.listTrackedBuildings()
    if not SaucedCarts.isDebugEnabled() then return end
    SaucedCarts.debug("=== Tracked Buildings ===")
    local count = 0
    local max = getMaxCartsPerBuilding()
    for key, spawnCount in pairs(getSpawnedBuildings()) do
        SaucedCarts.debug(string.format("  %s: %d/%d carts", key, spawnCount, max))
        count = count + 1
        if count >= 50 then
            SaucedCarts.debug("  ... (showing first 50)")
            break
        end
    end
    if count == 0 then
        SaucedCarts.debug("  (no buildings tracked yet)")
    end
    SaucedCarts.debug("=========================")
end

--- Check if a specific building (by player location) is tracked
function WorldSpawning.checkCurrentBuilding()
    if not SaucedCarts.isDebugEnabled() then return end

    local player = getPlayer()
    if not player then
        SaucedCarts.debug("No player found")
        return
    end

    local square = player:getCurrentSquare()
    if not square then
        SaucedCarts.debug("No square found")
        return
    end

    local buildingKey = getBuildingKey(square)
    if not buildingKey then
        SaucedCarts.debug("Not in a building (outdoor area)")
        return
    end

    local buildings = getSpawnedBuildings()
    local count = buildings[buildingKey] or 0
    local max = getMaxCartsPerBuilding()
    local atLimit = count >= max

    SaucedCarts.debug(string.format(
        "Building %s: %d/%d carts spawned, at limit: %s",
        buildingKey, count, max, tostring(atLimit)
    ))
end

--- Dump raw ModData for debugging
function WorldSpawning.dumpModData()
    if not SaucedCarts.isDebugEnabled() then return end

    SaucedCarts.debug("=== ModData Debug ===")
    SaucedCarts.debug("  MODDATA_KEY: " .. MODDATA_KEY)
    SaucedCarts.debug("  isServer(): " .. tostring(isServer()))
    SaucedCarts.debug("  isClient(): " .. tostring(isClient()))
    SaucedCarts.debug("  ModData.transmit available: " .. tostring(ModData.transmit ~= nil))

    local rawData = ModData.get(MODDATA_KEY)
    if rawData then
        SaucedCarts.debug("  ModData.get() returned data:")
        SaucedCarts.debug("    schemaVersion: " .. tostring(rawData.schemaVersion))
        if rawData.spawnedBuildings then
            local count = 0
            for k, v in pairs(rawData.spawnedBuildings) do
                count = count + 1
                if count <= 10 then
                    SaucedCarts.debug("    [" .. k .. "] = " .. tostring(v))
                end
            end
            SaucedCarts.debug("    Total buildings: " .. count)
        else
            SaucedCarts.debug("    spawnedBuildings: nil")
        end
    else
        SaucedCarts.debug("  ModData.get() returned nil")
    end

    local orCreateData = ModData.getOrCreate(MODDATA_KEY)
    if orCreateData then
        SaucedCarts.debug("  ModData.getOrCreate() returned data:")
        SaucedCarts.debug("    schemaVersion: " .. tostring(orCreateData.schemaVersion))
        if orCreateData.spawnedBuildings then
            local count = 0
            for _ in pairs(orCreateData.spawnedBuildings) do count = count + 1 end
            SaucedCarts.debug("    spawnedBuildings count: " .. count)
        else
            SaucedCarts.debug("    spawnedBuildings: nil")
        end
    else
        SaucedCarts.debug("  ModData.getOrCreate() returned nil (should never happen)")
    end
    SaucedCarts.debug("=====================")
end

-- ============================================================================
-- TEST API (exposed for unit testing)
-- ============================================================================

--- Get spawned buildings table for testing
---@return table<string, number>
function WorldSpawning._getSpawnedBuildings()
    return getSpawnedBuildings()
end

--- Get max carts per building for testing
---@return number
function WorldSpawning._getMaxCartsPerBuilding()
    return getMaxCartsPerBuilding()
end

--- Check building limit for testing
---@param buildingKey string
---@return boolean
function WorldSpawning._hasBuildingReachedLimit(buildingKey)
    return hasBuildingReachedLimit(buildingKey)
end

--- Increment building count for testing
---@param buildingKey string
function WorldSpawning._incrementBuildingCount(buildingKey)
    incrementBuildingCount(buildingKey)
end

--- Reset spawn tracking for test isolation (no debug check)
function WorldSpawning._resetSpawnTracking()
    local data = getSpawnData()
    data.spawnedBuildings = {}
    saveModData()
    for k in pairs(pendingBuildings) do pendingBuildings[k] = nil end
    pendingCount = 0
end

--- Live-probe / test hooks: run the spawn evaluation directly.
--- Server-only module, so these are reachable via pz-shell against a dedi, not
--- the offline harness.
WorldSpawning._onLoadChunk = onLoadChunk
WorldSpawning._initBuildingIndex = initBuildingIndex
WorldSpawning._buildOutdoorZones = buildOutdoorZones
WorldSpawning._pickInteriorSquare = pickInteriorSquare
WorldSpawning._pickOutdoorSquare = pickOutdoorSquare
WorldSpawning._candidateBuildings = candidateBuildings
WorldSpawning._chunkBuildingIndex = chunkBuildingIndex
WorldSpawning._OUTDOOR_RING_RADIUS = OUTDOOR_RING_RADIUS

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

-- OnLoadedMapZones (past tense) fires after every OnLoadMapZones handler
-- completes, including metazoneHandler.lua's VehicleZone registration. By
-- then both BuildingDefs (from CreateStep2 — IsoWorld.java:1976) AND
-- VehicleZones (from metazoneHandler) are consolidated, so buildOutdoorZones
-- can call getVehicleZoneAt safely. Vanilla uses this same event for
-- forageSystem.init + StoryClutter.Init for the same reason.
if Events.OnLoadedMapZones and Events.OnLoadedMapZones.Add then
    Events.OnLoadedMapZones.Add(initBuildingIndex)
end

-- Per-chunk spawn evaluation + queue draining. ModData uses lazy init.
Events.LoadChunk.Add(onLoadChunk)
Events.OnTick.Add(onTick)

-- Wipe pending decisions when leaving a game so SP save-switches start fresh.
-- spawnedBuildings (ModData) carries the durable cross-session dedup.
if Events.OnGameEnd and Events.OnGameEnd.Add then
    Events.OnGameEnd.Add(function()
        for k in pairs(pendingBuildings) do pendingBuildings[k] = nil end
        pendingCount = 0
        chunkCoordChecked = false
    end)
end

SaucedCarts.WorldSpawning = WorldSpawning
SaucedCarts.debug("WorldSpawning loaded (server)")

return WorldSpawning
