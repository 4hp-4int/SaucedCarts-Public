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
    local max = getMaxCartsPerBuilding()
    local atLimit = count >= max
    if atLimit then
        SaucedCarts.debug(function() return string.format(
            "Building %s at spawn limit (%d/%d)",
            buildingKey, count, max
        ) end)
    end
    return atLimit
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

        -- Re-validate square (may have changed since queued)
        if request.square and isValidSpawnSquare(request.square) then
            -- Re-check building hasn't reached limit (another square might have processed first)
            if not hasBuildingReachedLimit(request.buildingKey) then
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

                    -- Increment building spawn count (ModData saved after loop)
                    incrementBuildingCount(request.buildingKey)

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
        end

        -- Remove from queue (processed or invalid/failed - prevents infinite retry)
        table.remove(spawnQueue, i)
        i = i - 1
    end

    -- Batch save/transmit ModData once per tick (not per spawn)
    -- This reduces network overhead from N transmissions to 1
    if processed > 0 then
        saveModData()
        SaucedCarts.debug(function() return string.format(
            "WorldSpawning: Processed %d spawn(s), %d remaining in queue",
            processed, #spawnQueue
        ) end)
    end
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

--- Handle LoadGridsquare event - check for potential cart spawn locations
---@param square IsoGridSquare
local function onLoadGridsquare(square)
    -- Skip if mod disabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then return end
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.EnableWorldSpawning == false then return end

    if not square then return end

    -- Get room info
    local room = square:getRoom()
    if not room then return end  -- Outdoor or no room definition

    local roomName = room:getName()
    if not roomName then return end

    -- Check if this room type can spawn carts
    local spawnEntries = SaucedCarts.getSpawnEntriesForRoom(roomName)
    if not spawnEntries or #spawnEntries == 0 then return end

    -- LOG: We found a spawn-eligible room (this is critical for debugging)
    SaucedCarts.debug(function() return string.format("LoadGridsquare: Found spawn room '%s' at %d,%d", roomName, square:getX(), square:getY()) end)

    -- Get building key for deduplication
    local buildingKey = getBuildingKey(square)

    -- Skip if building has reached cart limit
    if buildingKey and hasBuildingReachedLimit(buildingKey) then return end

    -- Resolve building once for the filter. Nil = outdoor.
    local building = square:getBuilding()

    -- Get spawn multiplier from sandbox settings (SpawnRate is 0-500%, convert to multiplier)
    local multiplier = 1.0
    if SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.SpawnRate then
        multiplier = SandboxVars.SaucedCarts.SpawnRate / 100
    end

    -- Roll for each cart type that can spawn in this room
    for _, entry in ipairs(spawnEntries) do
        -- Building-signature filter: rejects residential buildings and
        -- outdoor squares unless the entry opts in. Cheap: just calls
        -- PZ's built-in BuildingDef.isResidential() (and isShop() when
        -- StrictShopOnly sandbox is on).
        local eligibility = SaucedCarts.evaluateSpawnEligibility(building, entry)
        if not eligibility.allowed then
            SaucedCarts.debug(function() return string.format(
                "Filter denied %s at %d,%d (%s)",
                entry.type, square:getX(), square:getY(), eligibility.reason
            ) end)
        else
            local adjustedChance = entry.chance * multiplier

            if ZombRand(100) < adjustedChance then
                -- Only queue if square is valid (basic check, re-validated when processing)
                if isValidSpawnSquare(square) then
                    queueSpawn(square, entry.type, buildingKey, roomName)

                    -- One cart per square - stop checking other entries for this square
                    -- (other squares in the building can still queue carts up to the limit)
                    if buildingKey then
                        break
                    end
                end
            end
        end
    end
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
    SaucedCarts.debug("DEBUG: Cleared spawn tracking - carts will respawn in all buildings")
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
end

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

-- Only need LoadGridsquare and OnTick - ModData uses lazy initialization
Events.LoadGridsquare.Add(onLoadGridsquare)
Events.OnTick.Add(onTick)

SaucedCarts.WorldSpawning = WorldSpawning
SaucedCarts.debug("WorldSpawning loaded (server)")

return WorldSpawning
