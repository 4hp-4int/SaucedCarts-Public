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
require "SaucedCarts/CartLoot"

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
--   candidateBuildings: bkey -> { def, roomName, entries }
--     One record per cart-eligible BuildingDef, for INTERIOR spawns only
--     (outdoor placement is zone-anchored — see the vehicle-zone pass in
--     onLoadChunk). `entries` is ALL eligible spawn entries for the building
--     (merged per cart type across every cart-eligible room, keeping the max
--     chance) so addon cart types mix with the built-in cart at decision time
--     (see decideSpawnPlacements). `roomName` is the first matched room, kept
--     for the debug tag only. (Rooms are re-walked from the def at decision
--     time — see pickInteriorSquare — so a gigamart's many "gigamart"-named
--     rects all contribute placement squares.)
--
--   chunkBuildingIndex: "chunkX,chunkY" -> { bkey, ... }
--     Reverse lookup. Most chunks have no entry (instant early-return);
--     chunks with at least one cart-eligible building yield a small list.
---@type table<string, {def: any, roomName: string, entries: SpawnEntry[]}>
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

    -- Per-zone outdoor dedup (v2.1.11+). Additive namespace alongside
    -- spawnedBuildings (interior) — no schema bump, no migration: a save that
    -- predates zone spawning simply starts with an empty table and accumulates
    -- zone decisions as chunks load.
    if not data.decidedZones then data.decidedZones = {} end

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

--- Get the decidedZones table (lazy access). Keyed by parking-chunk
--- ("cx,cy") — one decision per chunk that contains parking — value = carts
--- placed (0 = decided, none placed).
---@return table<string, number>
local function getDecidedZones()
    return getSpawnData().decidedZones
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

    -- Don't spawn inside a parked vehicle. Outdoor carts spawn in vehicle zones
    -- (the same map zones that spawn cars), so without this a cart lands inside a
    -- van/car model and the player has to move the vehicle to reach it. Vehicles
    -- aren't tile objects, so isFree() alone doesn't catch them.
    if square.isVehicleIntersecting and square:isVehicleIntersecting() then
        return false
    end

    -- Must be walkable (not blocked by furniture, walls, etc.) and not embedded
    -- in solid map geometry (e.g. a support column).
    if not square:isFree(false) then return false end
    if square.isSolid and square:isSolid() then return false end

    -- Must have adequate navigation space: at least 2 adjacent squares that are
    -- BOTH free AND reachable from this square (no wall between them). The
    -- reachability check (isBlockedTo) is what rejects a square boxed in by walls
    -- or columns — e.g. between the 4 pillars of a gas-station canopy — where the
    -- neighbours are open but you can't actually path to the cart.
    local accessible = 0
    local directions = {IsoDirections.N, IsoDirections.E, IsoDirections.S, IsoDirections.W}
    for _, dir in ipairs(directions) do
        local adj = square:getAdjacentSquare(dir)
        if adj and adj:isFree(false) and not square:isBlockedTo(adj) then
            accessible = accessible + 1
        end
    end

    if accessible < 2 then return false end

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

    -- Resolve the loot context once, here, from the room tag the callers
    -- already pass: outdoor carts ("outdoor:<ztype>") use the groceries/bags
    -- theme; interior carts map their room via CartLoot. (See CartLoot.lua.)
    local context
    if roomName and string.find(roomName, "^outdoor") then
        context = "grocery"
    else
        context = SaucedCarts.CartLoot.contextForRoom(roomName)
    end

    table.insert(spawnQueue, {
        square = square,
        cartType = cartType,
        buildingKey = buildingKey,
        context = context,
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

--- Set a spawned cart's visual model + fillState ModData for a fill state.
---@param cart InventoryItem
---@param state string "empty"|"partial"|"full"
local function setCartFillVisual(cart, state)
    local cartData = SaucedCarts.getCartData(cart)
    if cartData and cartData.visualModels then
        local model = cartData.visualModels[state] or cartData.visualModels.empty
        if model then
            cart:setStaticModel(model)
            cart:setWorldStaticModel(model)
        end
    end
    cart:getModData().SaucedCarts_fillState = state
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

            -- Decide whether this cart spawns loaded (mostly empty; see CartLoot).
            local density = SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.LoadedCartSpawns
            local load = SaucedCarts.CartLoot.decideCartLoad(density, ZombRand)

            local cart
            if load.tier == "empty" then
                -- EMPTY PATH (unchanged): synchSpawn=true transmits the empty cart.
                -- AddWorldInventoryItem(itemType, x, y, z, autoAge, synchSpawn).
                -- Do NOT also call transmitCompleteItemToClients() — double-transmit
                -- dupes the cart in self-hosted MP.
                cart = request.square:AddWorldInventoryItem(
                    request.cartType, offsetX, offsetY, 0, false, true)
                if cart then
                    SaucedCarts.applyMultipliers(cart)
                    setCartFillVisual(cart, "empty")
                    SaucedCarts.debug(function() return string.format(
                        "Spawned %s at %d,%d,%d (building %s)",
                        request.cartType, request.square:getX(), request.square:getY(),
                        request.square:getZ(), request.buildingKey or "outdoor") end)
                end
            else
                -- LOADED PATH: build the item, fill it, then place WITHOUT transmit
                -- and broadcast the COMPLETE (loaded) item once — the V2 dupe-safe
                -- place-then-transmit pattern. synchSpawn would broadcast the cart
                -- empty before we fill it, desyncing contents to clients.
                local item = instanceItem(request.cartType)
                if item then
                    SaucedCarts.applyMultipliers(item)
                    local placed, weightUsed = SaucedCarts.CartLoot.fillCart(
                        item, request.context, load.tier, load.count, ZombRand)

                    -- Pad with cheap junk so the cart actually LOOKS loaded: the
                    -- visual model is capacity-% based and the (deliberately
                    -- small) loot budget rarely crosses the partial threshold on
                    -- its own, especially with a big CapacityMultiplier. Capped
                    -- so a huge cart isn't stuffed. See CartLoot.padToFillState.
                    local targetRatio = SaucedCarts.CartLoot.fillTargetFor(load.tier)
                    local junkCount, junkWeight = SaucedCarts.CartLoot.padToFillState(
                        item, targetRatio, ZombRand)

                    -- Canonical capacity-based visual (same path as in-game fills)
                    -- now reflects loot + junk. updateCartVisual sets the model +
                    -- fillState ModData; the contents replicate via the single
                    -- transmitCompleteItemToClients() below.
                    SaucedCarts.updateCartVisual(item)

                    -- Item-overload: AddWorldInventoryItem(item, x, y, z, transmit=false)
                    request.square:AddWorldInventoryItem(item, offsetX, offsetY, 0, false)
                    if item.transmitCompleteItemToClients then
                        item:transmitCompleteItemToClients()
                    end
                    cart = item

                    SaucedCarts.debug(function() return string.format(
                        "Loaded %s at %d,%d ctx=%s tier=%s loot=%d(%.1fkg) junk=%d(%.1fkg) -> %s",
                        request.cartType, request.square:getX(), request.square:getY(),
                        tostring(request.context), load.tier, placed, weightUsed,
                        junkCount, junkWeight,
                        item:getModData().SaucedCarts_fillState or "empty") end)
                end
            end

            if cart then
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

-- Outdoor (vehicle-zone) spawning. We decide ONE roll per CHUNK that contains
-- parking, NOT per zone — a real lot is subdivided into dozens of tiny
-- ParkingStall zones (5x3 each), so rolling per zone floods it. Density then
-- scales with lot AREA (number of parking chunks) instead of stall COUNT.
-- Area-scaled within a chunk: ~one roll per AREA_PER_ROLL parking sample tiles
-- (stride-2 samples, so a full chunk yields up to ~16/AREA_PER_ROLL rolls),
-- capped by MAX_CARTS_PER_CHUNK.
local OUTDOOR_AREA_PER_ROLL = 8
-- Per-parking-chunk spawn chance by the OutdoorSpawnDensity sandbox enum
-- (1=Off, 2=Low, 3=Medium, 4=High). Medium (3%) is the default — tuned from
-- live logs (≈1 in 10 lots has a cart across a fully-explored district). All
-- still scale with SpawnRate (the player's global lever).
local OUTDOOR_DENSITY_CHANCE = { [1] = 0, [2] = 1, [3] = 3, [4] = 8 }
local OUTDOOR_DENSITY_DEFAULT = 3  -- Medium
local MAX_CARTS_PER_CHUNK = 2

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
            -- Merge eligible entries PER cart type across every room in the
            -- building, keeping the BEST one — not whichever room PZ happens to
            -- enumerate first. A single BuildingDef often contains many rooms
            -- with different names (e.g. gigamart + grocerystorage + lobby); for
            -- a given cart type we want the building to roll at its MAX chance
            -- and to inherit the outdoor opt-in (max outdoorWeight) if ANY of its
            -- rooms allows it. Without the merge, a gigamart that also has a
            -- low-chance lobby could roll at 2% with no outdoor just because the
            -- lobby room sorted first. Dedup-by-type (vs. one entry per room)
            -- still keeps decideSpawnPlacements' weighted type pick from
            -- double-counting a type present in several of the building's rooms.
            local byType, typeOrder = {}, {}
            local matchedRoomName
            for j = 0, rooms:size() - 1 do
                local room = rooms:get(j)
                local roomName = room and room.getName and room:getName()
                if roomName then
                    local roomEntries = SaucedCarts.getSpawnEntriesForRoom(roomName)
                    if roomEntries then
                        for _, entry in ipairs(roomEntries) do
                            if SaucedCarts.evaluateSpawnEligibility(wrap, entry).allowed then
                                local agg = byType[entry.type]
                                if not agg then
                                    agg = {
                                        type                 = entry.type,
                                        chance               = entry.chance,
                                        allowResidential     = entry.allowResidential or nil,
                                        skipFrameworkFilters = entry.skipFrameworkFilters or nil,
                                    }
                                    byType[entry.type] = agg
                                    typeOrder[#typeOrder + 1] = entry.type
                                    matchedRoomName = matchedRoomName or roomName
                                else
                                    if entry.chance > agg.chance then agg.chance = entry.chance end
                                    if entry.allowResidential then agg.allowResidential = true end
                                    if entry.skipFrameworkFilters then agg.skipFrameworkFilters = true end
                                end
                            end
                        end
                    end
                end
            end

            local matchedEntries
            for _, t in ipairs(typeOrder) do
                matchedEntries = matchedEntries or {}
                matchedEntries[#matchedEntries + 1] = byType[t]
            end

            if matchedEntries then
                indexedDefs = indexedDefs + 1
                local bkey = def:getX() .. "," .. def:getY()
                candidateBuildings[bkey] = {
                    def = def,
                    roomName = matchedRoomName,
                    entries = matchedEntries,
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

    local multiplier = 1.0
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.SpawnRate then
        multiplier = SandboxVars.SaucedCarts.SpawnRate / 100
    end

    -- ── Interior pass ───────────────────────────────────────────────────────
    -- Decide each cart-eligible building overlapping this chunk, immediately on
    -- first overlap (no deferral — outdoor is handled separately by the zone
    -- pass below). pickInteriorSquare draws from whatever of the building's
    -- rooms are currently streamed; a building whose eligible room hasn't loaded
    -- yet commits 0 (unchanged from the prior model).
    local candidateKeys = chunkBuildingIndex[key]
    if candidateKeys then
        local buildings = getSpawnedBuildings()
        local max = getMaxCartsPerBuilding()
        local committed = false
        for _, bkey in ipairs(candidateKeys) do
            if buildings[bkey] == nil then
                local data = candidateBuildings[bkey]
                local picks = SaucedCarts.decideSpawnPlacements(data.entries, max, multiplier, ZombRand)
                local carts = 0
                for _, ctype in ipairs(picks) do
                    local sq = pickInteriorSquare(data)
                    if sq then
                        queueSpawn(sq, ctype, bkey, data.roomName)
                        carts = carts + 1
                    end
                end
                buildings[bkey] = carts
                committed = true
                SaucedCarts.debug(function() return string.format(
                    "Decided building %s: %d cart(s) interior", bkey, carts) end)
            end
        end
        if committed then saveModData() end
    end

    -- ── Outdoor pass (zone-anchored) ────────────────────────────────────────
    -- Mirrors IsoChunk.AddVehicles: walk the cell's vehicle zones overlapping
    -- this chunk and roll carts directly into them — no buildings. Covers store
    -- parking lots, residential driveways, and trailer-park parking uniformly,
    -- the same map zones vanilla spawns cars in. Cars are already placed by the
    -- time LoadChunk fires (IsoChunk.java:3676 before :3924), so isValidSpawnSquare
    -- leaves them be and carts slot into empty stalls.
    local densityLevel = (SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.OutdoorSpawnDensity)
        or OUTDOOR_DENSITY_DEFAULT
    local outdoorChance = OUTDOOR_DENSITY_CHANCE[densityLevel] or OUTDOOR_DENSITY_CHANCE[OUTDOOR_DENSITY_DEFAULT]
    if outdoorChance <= 0 then return end  -- Off
    local pool = SaucedCarts.getOutdoorCartPool()
    if not pool or #pool == 0 then return end

    if not getVehicleZoneAt then return end

    -- ONE decision per chunk (not per parking zone). Dedup by chunk key.
    local decided = getDecidedZones()
    local ckey = cx .. "," .. cy
    if decided[ckey] ~= nil then return end

    -- Stride-2 sample of the chunk's 16 representative tiles. Parking stalls /
    -- driveways are >=2 tiles wide, so striding still finds them at ~1/4 the
    -- getVehicleZoneAt cost. (IsoMetaCell.vehicleZones is NOT readable from
    -- Kahlua — verified live — so getVehicleZoneAt is the only accessor; it
    -- queries pre-loaded zone AABBs, no chunk streaming.) Collect accepted
    -- parking tiles as placement candidates; skip denied types (trafficjam*/burnt).
    local cox, coy = cx * 8, cy * 8
    local candidates = {}
    local sampleType
    for ly = 0, 7, 2 do
        for lx = 0, 7, 2 do
            local zone = getVehicleZoneAt(cox + lx, coy + ly, 0)
            if zone then
                local ztype = string.lower((zone.getType and zone:getType()) or "parkingstall")
                if not OUTDOOR_ZONE_TYPE_DENY[ztype] then
                    candidates[#candidates + 1] = { lx, ly }
                    sampleType = sampleType or ztype
                end
            end
        end
    end

    -- No parking in this chunk: don't record (keeps the dedup table small; the
    -- cheap stride-2 scan just re-runs if the chunk reloads).
    if #candidates == 0 then return end

    -- Area-scaled by how much of the chunk is parking (sample count): a fully
    -- paved chunk can roll up to MAX_CARTS_PER_CHUNK; a small sliver gets one.
    -- outdoorChance comes from the OutdoorSpawnDensity preset, scaled by SpawnRate.
    local count = SaucedCarts.decideZoneSpawns(
        #candidates, outdoorChance, multiplier, MAX_CARTS_PER_CHUNK, OUTDOOR_AREA_PER_ROLL, ZombRand)

    -- Shuffle candidates so the placed carts are spread across the chunk's
    -- parking, then take the first `count` that validate (no two on one tile).
    for i = #candidates, 2, -1 do
        local j = ZombRand(i) + 1
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end

    local placed = 0
    for _, t in ipairs(candidates) do
        if placed >= count then break end
        local sq = chunk:getGridSquare(t[1], t[2], 0)
        if sq and isValidSpawnSquare(sq) then
            local ctype = SaucedCarts.pickOutdoorCartType(pool, ZombRand)
            if ctype then
                queueSpawn(sq, ctype, nil, "outdoor:" .. (sampleType or "parking"))
                placed = placed + 1
            end
        end
    end

    decided[ckey] = placed
    saveModData()
    SaucedCarts.debug(function() return string.format(
        "Decided parking chunk %s (%s, %d parking tiles): %d cart(s)",
        ckey, sampleType or "parking", #candidates, placed) end)
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
    data.decidedZones = {}
    saveModData()
    SaucedCarts.debug("DEBUG: Cleared building + zone decisions - carts re-roll as chunks reload")
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
        if orCreateData.decidedZones then
            local zcount = 0
            for _ in pairs(orCreateData.decidedZones) do zcount = zcount + 1 end
            SaucedCarts.debug("    decidedZones count: " .. zcount)
        else
            SaucedCarts.debug("    decidedZones: nil")
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
    data.decidedZones = {}
    saveModData()
end

--- Live-probe / test hooks: run the spawn evaluation directly.
--- Server-only module, so these are reachable via pz-shell against a dedi, not
--- the offline harness.
WorldSpawning._onLoadChunk = onLoadChunk
WorldSpawning._initBuildingIndex = initBuildingIndex
WorldSpawning._pickInteriorSquare = pickInteriorSquare
WorldSpawning._candidateBuildings = candidateBuildings
WorldSpawning._chunkBuildingIndex = chunkBuildingIndex
WorldSpawning._getDecidedZones = getDecidedZones

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

-- OnLoadedMapZones (past tense) fires after every OnLoadMapZones handler
-- completes, including metazoneHandler.lua's VehicleZone registration. By
-- then both BuildingDefs (from CreateStep2 — IsoWorld.java:1976) AND
-- VehicleZones (from metazoneHandler) are consolidated, so the index build and
-- the per-chunk vehicle-zone pass see a complete world. Vanilla uses this same
-- event for forageSystem.init + StoryClutter.Init for the same reason.
if Events.OnLoadedMapZones and Events.OnLoadedMapZones.Add then
    Events.OnLoadedMapZones.Add(initBuildingIndex)
end

-- Per-chunk spawn evaluation + queue draining. ModData uses lazy init.
Events.LoadChunk.Add(onLoadChunk)
Events.OnTick.Add(onTick)

-- Reset the one-time chunk-coord invariant flag on game-end so a SP
-- save-switch re-validates. Durable dedup (spawnedBuildings + decidedZones)
-- lives in ModData and carries across sessions.
if Events.OnGameEnd and Events.OnGameEnd.Add then
    Events.OnGameEnd.Add(function()
        chunkCoordChecked = false
    end)
end

SaucedCarts.WorldSpawning = WorldSpawning
SaucedCarts.debug("WorldSpawning loaded (server)")

return WorldSpawning
