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

-- PRIMARY short-circuit: in-memory set of chunk origins ("originX,originY")
-- already walked this session. On LoadChunk we bail immediately if the chunk is
-- here — a perfect, zero-iteration skip for re-streams / revisits within a
-- session (the dominant case on a long-lived dedi). Cleared on game end, so
-- after a restart each chunk re-walks ONCE; that re-walk is cheap and silent
-- because the durable, cross-restart dedup is the per-building decision recorded
-- in spawnedBuildings (see classifyInterior + onLoadChunk decide stage) — nothing re-rolls.
local sessionEvaluatedChunks = {}

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

--- Save and transmit ModData to clients
local function saveModData()
    -- Data is already in ModData via getOrCreate, just need to transmit
    if ModData.transmit then
        ModData.transmit(MODDATA_KEY)
    end
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

--- Evaluate one loaded square under the ONE-SHOT-PER-BUILDING model: a building
--- Classify an interior square as a candidate placement for its building under
--- the one-shot-per-building model. If the square is in a spawn-eligible room,
--- the building isn't already decided, the square is placeable, AND at least
--- one spawn entry passes the building-signature filter (so the building is a
--- real commercial candidate), bucket it under its buildingKey for stage-2
--- decision. Otherwise no-op.
---@param square IsoGridSquare
---@param interiorByBuilding table buildingKey -> { {square, allowedEntries, roomName}, ... }
local function classifyInterior(square, interiorByBuilding)
    local room = square:getRoom()
    if not room then return end
    local roomName = room:getName()
    if not roomName then return end
    local spawnEntries = SaucedCarts.getSpawnEntriesForRoom(roomName)
    if not spawnEntries or #spawnEntries == 0 then return end

    local buildingKey = getBuildingKey(square)
    if not buildingKey then return end  -- no def => no stable persistence key
    if getSpawnedBuildings()[buildingKey] ~= nil then return end  -- already decided

    if not isValidSpawnSquare(square) then return end

    -- Building-signature filter — only buildings that pass for at least one
    -- entry become candidates. Residential / non-shop are rejected here and
    -- therefore never written to spawnedBuildings (keeps it bounded).
    local building = square:getBuilding()
    local allowedEntries
    for _, entry in ipairs(spawnEntries) do
        if SaucedCarts.evaluateSpawnEligibility(building, entry).allowed then
            allowedEntries = allowedEntries or {}
            allowedEntries[#allowedEntries + 1] = entry
        end
    end
    if not allowedEntries then return end

    local bucket = interiorByBuilding[buildingKey]
    if not bucket then
        bucket = {}
        interiorByBuilding[buildingKey] = bucket
    end
    bucket[#bucket + 1] = { square = square, allowedEntries = allowedEntries, roomName = roomName }
end

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

-- Buildings with allowOutdoor entries whose initial outdoor scan turned up
-- empty (because adjacent chunks weren't loaded yet). Retried on every
-- subsequent LoadChunk until either the scan finds candidates or attempts
-- exceeds MAX_OUTDOOR_DEFER. Session-scoped — pending entries don't survive a
-- game-end, but they don't need to: the building is also absent from
-- spawnedBuildings, so a session restart simply re-rolls it.
---@type table<string, {entry: SpawnEntry, roomName: string, interiorList: table, attempts: number}>
local pendingBuildings = {}

--- Scan around a building's footprint for outdoor parking-lot candidates.
--- Building-relative (NOT chunk-relative) — this is what fixes the chunk-
--- coincidence bias where the interior chunk's outdoor pool was empty because
--- the parking is in an adjacent chunk. As long as adjacent chunks are loaded
--- (true near the player), they contribute candidates.
---@param cell IsoCell from getCell()
---@param building IsoBuilding the candidate building
---@param radius number ring width in tiles around the building's bounding box
---@return table|nil list of valid outdoor (no-room, vehicle-zone) squares
local function scanOutdoorAroundBuilding(cell, building, radius)
    if not cell or not building then return nil end
    local def = building:getDef()
    if not def then return nil end
    local bx = def:getX()
    local by = def:getY()
    local bw = def:getW()
    local bh = def:getH()
    if not (bx and by and bw and bh) then return nil end
    -- Parking lots are ground-level. BuildingDef has no getZ(), and even for
    -- multi-story shops the cart belongs on the ground floor lot, not a roof.
    local z = 0

    local x0, x1 = bx - radius, bx + bw + radius - 1
    local y0, y1 = by - radius, by + bh + radius - 1
    local pool
    local nNull, nRoom, nNoVz, nInvalid, nPass = 0, 0, 0, 0, 0
    for ny = y0, y1 do
        for nx = x0, x1 do
            if nx < bx or nx >= bx + bw or ny < by or ny >= by + bh then
                local sq = cell:getGridSquare(nx, ny, z)
                if not sq then
                    nNull = nNull + 1
                elseif sq:getRoom() then
                    nRoom = nRoom + 1
                elseif not (getVehicleZoneAt and getVehicleZoneAt(nx, ny, z)) then
                    nNoVz = nNoVz + 1
                elseif not isValidSpawnSquare(sq) then
                    nInvalid = nInvalid + 1
                else
                    nPass = nPass + 1
                    pool = pool or {}
                    pool[#pool + 1] = sq
                end
            end
        end
    end
    SaucedCarts.debug(function() return string.format(
        "  scanOutdoor bldg=%d,%d size=%dx%d r=%d  null=%d room=%d noVz=%d invalid=%d pass=%d",
        bx, by, bw, bh, radius, nNull, nRoom, nNoVz, nInvalid, nPass) end)
    return pool
end

-- Chunk square dimension. IsoChunk.getGridSquare bounds-checks chunkSquareX/Y
-- to [0,8) and indexes `squares[zz][y*8+x]` (IsoChunk.java:3130). Pinned
-- anchor — re-verify against that method if a PZ update changes chunk geometry.
local CHUNK_SIZE = 8

--- Handle LoadChunk event - evaluate every loaded square in the chunk once.
---
--- Replaces the former per-square LoadGridsquare hook. Vanilla fires
--- LoadGridsquare once per square (IsoChunk.java:3797 — up to 64 per z-level
--- per chunk, and again on every chunk reload); LoadChunk fires ONCE per chunk
--- (IsoChunk.java:3924, after all squares + rooms are loaded). Iterating the
--- chunk's squares here collapses ~64-192 Lua event dispatches per chunk into
--- one and hoists the sandbox gate + multiplier out of the per-square path.
--- On a dedicated server (where this runs for every chunk every player streams)
--- that's the meaningful win.
---@param chunk IsoChunk
local function onLoadChunk(chunk)
    -- Skip if mod / world spawning disabled (hoisted: evaluated once per chunk)
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then return end
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.EnableWorldSpawning == false then return end

    if not chunk then return end

    -- Spawn multiplier from sandbox (SpawnRate 0-500% -> 0-5 multiplier), once.
    local multiplier = 1.0
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.SpawnRate then
        multiplier = SandboxVars.SaucedCarts.SpawnRate / 100
    end

    -- Outdoor is a sandbox-gated feature; cheap global precheck.
    local outdoorEnabledGlobally =
        (not SandboxVars.SaucedCarts or SandboxVars.SaucedCarts.EnableOutdoorSpawns ~= false)
        and (SaucedCarts.anyEntryAllowsOutdoor and SaucedCarts.anyEntryAllowsOutdoor())

    local minZ = chunk:getMinLevel()
    local maxZ = chunk:getMaxLevel()
    local sessionChecked = false

    -- Stage 1: interior candidates only. Outdoor candidates are NOT collected
    -- here — they're scanned per-building at decide time (see Stage 2). That
    -- fixes the chunk-coincidence bias where a gigamart's interior chunk had
    -- no outdoor candidates because its parking lot lives in an adjacent chunk.
    local interiorByBuilding = {}

    for z = minZ, maxZ do
        for x = 0, CHUNK_SIZE - 1 do
            for y = 0, CHUNK_SIZE - 1 do
                local square = chunk:getGridSquare(x, y, z)
                if square then
                    -- PRIMARY short-circuit: derive the chunk key from the first
                    -- real square (origin = sqX-localX, sqY-localY) and bail if
                    -- we've already walked this chunk this session. Cross-restart
                    -- dedup is the per-building decision in spawnedBuildings, so
                    -- a post-restart re-walk is cheap and silent.
                    if not sessionChecked then
                        sessionChecked = true
                        local key = (square:getX() - x) .. "," .. (square:getY() - y)
                        if sessionEvaluatedChunks[key] then return end
                        sessionEvaluatedChunks[key] = true
                    end
                    if square:getRoom() then
                        classifyInterior(square, interiorByBuilding)
                    end
                end
            end
        end
    end

    -- Stage 2: decide per candidate building. Each building gets up to
    -- MaxCartsPerBuilding roll attempts (default 1); on success, the placement
    -- is picked from a pool (interior squares ± outdoor squares from a building-
    -- relative ring scan). Spawn rate is unchanged — outdoor only affects WHERE.
    --
    -- Two-phase: (1) merge this chunk's interior buckets into pendingBuildings
    -- (handles multi-chunk buildings + carries unresolved outdoor-defer state
    -- across LoadChunks). (2) walk pendingBuildings and decide each as soon as
    -- outdoor candidates appear, or after MAX_OUTDOOR_DEFER tries.
    local cell = getCell()
    local buildings = getSpawnedBuildings()
    local committed = false
    local max = getMaxCartsPerBuilding()

    -- Phase 1: merge this chunk's interior squares into pendingBuildings.
    for buildingKey, list in pairs(interiorByBuilding) do
        if not buildings[buildingKey] then  -- might have been decided this session
            local p = pendingBuildings[buildingKey]
            if p then
                for _, item in ipairs(list) do
                    p.interiorList[#p.interiorList + 1] = item
                end
            else
                pendingBuildings[buildingKey] = {
                    entry = list[1].allowedEntries[1],
                    roomName = list[1].roomName,
                    interiorList = list,
                    attempts = 0,
                }
            end
        end
    end

    -- Phase 2: walk every pending building (not just this chunk's). Decide as
    -- soon as outdoor scan succeeds OR after MAX_OUTDOOR_DEFER attempts.
    -- Entries without allowOutdoor decide immediately on first pass.
    for buildingKey, p in pairs(pendingBuildings) do
        p.attempts = p.attempts + 1
        local entry = p.entry
        local outdoorWeight = entry.outdoorWeight or 30

        local outdoorPool
        if outdoorEnabledGlobally and entry.allowOutdoor then
            local building = p.interiorList[1].square:getBuilding()
            outdoorPool = scanOutdoorAroundBuilding(cell, building, OUTDOOR_RING_RADIUS)
        end
        local outdoorReady = outdoorPool and #outdoorPool > 0
        local giveUp = p.attempts >= MAX_OUTDOOR_DEFER

        -- Decide iff outdoor isn't gating us anymore.
        if outdoorReady or giveUp or not entry.allowOutdoor then
            local carts = 0
            for _ = 1, max do
                if ZombRand(100) < entry.chance * multiplier then
                    local placeOutdoor = outdoorReady and (ZombRand(100) < outdoorWeight)
                    local sq
                    if placeOutdoor then
                        sq = outdoorPool[ZombRand(#outdoorPool) + 1]
                        queueSpawn(sq, entry.type, buildingKey, "outdoor")
                    else
                        sq = p.interiorList[ZombRand(#p.interiorList) + 1].square
                        queueSpawn(sq, entry.type, buildingKey, p.roomName)
                    end
                    carts = carts + 1
                end
            end
            buildings[buildingKey] = carts
            committed = true
            pendingBuildings[buildingKey] = nil
            SaucedCarts.debug(function() return string.format(
                "Decided building %s: %d cart(s) (attempts=%d)%s%s",
                buildingKey, carts, p.attempts,
                (outdoorReady and string.format(" [+outdoor pool %d]", #outdoorPool) or ""),
                (giveUp and not outdoorReady and entry.allowOutdoor and " [outdoor defer give-up]" or "")
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
    -- Wipe the in-memory chunk cache too, so chunks re-walk and their (now
    -- un-decided) buildings re-roll as you reload areas.
    for k in pairs(sessionEvaluatedChunks) do sessionEvaluatedChunks[k] = nil end
    for k in pairs(pendingBuildings) do pendingBuildings[k] = nil end
    SaucedCarts.debug("DEBUG: Cleared building decisions + chunk cache + pending - carts re-roll as chunks reload")
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
    for k in pairs(sessionEvaluatedChunks) do sessionEvaluatedChunks[k] = nil end
    for k in pairs(pendingBuildings) do pendingBuildings[k] = nil end
end

--- Live-probe / test hooks: run the per-chunk spawn evaluation directly.
--- Server-only module, so these are reachable via pz-shell against a dedi, not
--- the offline harness.
WorldSpawning._onLoadChunk = onLoadChunk
WorldSpawning._classifyInterior = classifyInterior
WorldSpawning._scanOutdoorAroundBuilding = scanOutdoorAroundBuilding
WorldSpawning._OUTDOOR_RING_RADIUS = OUTDOOR_RING_RADIUS

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

-- Per-chunk spawn evaluation + queue draining. ModData uses lazy init.
-- LoadChunk (once per chunk) replaces the former per-square LoadGridsquare
-- hook — see onLoadChunk. OnTick drains the spawn queue.
Events.LoadChunk.Add(onLoadChunk)
Events.OnTick.Add(onTick)

-- Drop the in-memory chunk cache when leaving a game so a SP save-switch starts
-- fresh. The durable per-building decisions live in spawnedBuildings (ModData)
-- and need no reset.
if Events.OnGameEnd and Events.OnGameEnd.Add then
    Events.OnGameEnd.Add(function()
        for k in pairs(sessionEvaluatedChunks) do sessionEvaluatedChunks[k] = nil end
        for k in pairs(pendingBuildings) do pendingBuildings[k] = nil end
    end)
end

SaucedCarts.WorldSpawning = WorldSpawning
SaucedCarts.debug("WorldSpawning loaded (server)")

return WorldSpawning
