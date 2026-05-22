-- ============================================================================
-- SaucedCarts/Core.lua
-- ============================================================================
-- PURPOSE: Core initialization and shared utilities for SaucedCarts.
--          Loads all modules and sets up the mod namespace.
--          Defines schema versioning for forward compatibility.
--
-- CONTEXT: SHARED (client + server)
--          This is the main entry point for the mod.
--
-- LOAD ORDER:
--   1. Core.lua (this file) - sets up namespace, schema version
--   2. CartData.lua - cart type definitions
--   3. Migration.lua - schema versioning, orphan detection
--   4. TimedActions/*.lua - pickup/drop actions
--   5. ContextMenu.lua (client) OR Distributions.lua (server)
--   6. OrphanRecovery.lua (client) - orphan cart UI
-- ============================================================================

-- Initialize namespace (preserve any existing table from external mods that loaded first)
---@class SaucedCartsModule
---@field VERSION string Mod version
---@field MOD_ID string Mod identifier
---@field API_VERSION number Registration API version (increment on breaking changes)
---@field SCHEMA_VERSION number ModData schema version for migration
---@field TYPE_ALIASES table<string, string> Old type -> New type mappings for renamed carts
---@field CartTypes table<string, CartTypeData> Cart type definitions (from CartData.lua)
---@field Migration SaucedCartsMigration Migration utilities (from Migration.lua)
---@field OrphanRecovery SaucedCartsOrphanRecovery Orphan recovery UI (from OrphanRecovery.lua)
---@field _pendingRegistrations table Queue for registrations from mods that load before SaucedCarts
---@field _registryFrozen boolean Whether the cart registry is frozen (after OnGameStart)
---@field _orphanedCarts table<number, boolean> Cache of orphan cart IDs for current session
SaucedCarts = SaucedCarts or {}

-- Version info
SaucedCarts.VERSION = "2.1.7"
SaucedCarts.MOD_ID = "SaucedCarts"
SaucedCarts.API_VERSION = 1  -- Increment on breaking API changes (field renames, removed fields, signature changes)

-- Schema version for ModData migration (increment when ModData structure changes)
-- Version 1: Initial schema with schemaVersion tracking
-- Version 2: Added attachment system fields (flashlight upgrade)
-- Version 3: Added rawCapacity field for CapacityOverride (SaucedCarts_rawCapacity)
SaucedCarts.SCHEMA_VERSION = 3

-- Type aliases for cart migrations (old type -> new type)
-- Used when cart types are renamed or moved between modules
-- Example: ["OldMod.OldCart"] = "NewMod.NewCart"
SaucedCarts.TYPE_ALIASES = {
    -- Populate this when renaming cart types in future versions
}

-- =============================================================================
-- TUNING CONFIGURATION
-- =============================================================================
-- Central configuration for tunable constants.
-- Changing these values affects mod behavior globally.

SaucedCarts.Config = {
    -- Durability (shared)
    TILES_PER_DAMAGE = 110,  -- tiles of movement before 1 condition damage
    MAX_DISTANCE_PER_FRAME = 5.0,  -- tiles; rejects teleport/chunk-load spikes

    -- Visual fill states (shared)
    FILL_PARTIAL_THRESHOLD = 0.33,  -- below this = empty model
    FILL_FULL_THRESHOLD = 0.66,     -- above this = full model

    -- Battery (shared) - SINGLE SOURCE OF TRUTH
    BATTERY_DRAIN_PER_SECOND = 0.00014,  -- ~2 hours of use
    BATTERY_CHECK_INTERVAL = 60,          -- ticks (~1 second)

    -- Client tick intervals (frames at 60fps)
    SELF_CORRECTION_INTERVAL = 180,    -- ~3 seconds (safety net, event-driven handles most cases)
    UPGRADE_RECOVERY_INTERVAL = 30,    -- ~0.5 second
    DISPLAY_UPDATE_INTERVAL = 30,      -- ~0.5 second

    -- World spawning (server)
    SPAWN_TICK_INTERVAL = 30,          -- ticks (~0.5 second)
    MAX_SPAWNS_PER_TICK = 3,           -- spawns per processing tick
    MAX_SPAWN_QUEUE_SIZE = 500,        -- maximum queued rooms

    -- Distance sync (MP client -> server)
    DISTANCE_SYNC_THRESHOLD = 10,     -- tiles before syncing to server
    DISTANCE_SYNC_MAX = 10000,        -- max accepted value (anti-cheat clamp)
}

-- Pending registration queue (external mods can push here if they load before SaucedCarts)
-- Preserve any existing queue from mods that already added to it
SaucedCarts._pendingRegistrations = SaucedCarts._pendingRegistrations or {}
SaucedCarts._registryFrozen = false

-- ============================================================================
-- LOGGING
-- ============================================================================

-- Cache builtins (may be cleared on dedicated servers)
local type = type
local tostring = tostring

--- Check if debug logging is enabled
--- Requires BOTH PZ debug mode AND sandbox EnableDebugLogs setting
--- No caching - allows mid-game setting changes (only runs in debug mode anyway)
---@return boolean True if debug logging should occur
local function isDebugEnabled()
    -- Fast path: not in debug mode at all
    if not getDebug() then return false end

    -- Check sandbox setting (no cache - allows mid-game changes)
    local sandbox = SandboxVars.SaucedCarts
    -- Default to true for backwards compatibility (if sandbox not loaded yet)
    if not sandbox then return true end

    return sandbox.EnableDebugLogs ~= false
end

-- Export for external fast-path checks (e.g., WorldSpawning bulk operations)
SaucedCarts.isDebugEnabled = isDebugEnabled

--- Log a message with mod prefix. Accepts a string OR a zero-arg function
--- (for lazy evaluation of expensive string builds) — matches .debug().
---@param messageOrFn string|function|any The message, or function returning message
function SaucedCarts.log(messageOrFn)
    local message
    if type(messageOrFn) == "function" then
        message = messageOrFn()
    else
        message = messageOrFn
    end
    print("[SaucedCarts] " .. tostring(message))
end

--- Log an error with mod prefix
---@param message string|any The error message to log
function SaucedCarts.error(message)
    print("[SaucedCarts:ERROR] " .. tostring(message))
end

--- Log a debug message with lazy evaluation support
--- For hot paths, pass a function to defer string concatenation:
---   SaucedCarts.debug(function() return "Value: " .. expensive end)
--- For simple messages, string is still supported (legacy):
---   SaucedCarts.debug("Simple message")
---@param messageOrFn string|function|any The message, or function returning message
function SaucedCarts.debug(messageOrFn)
    if not isDebugEnabled() then return end

    local message
    if type(messageOrFn) == "function" then
        -- Lazy evaluation: only call function when debug is enabled
        message = messageOrFn()
    else
        message = messageOrFn
    end

    print("[SaucedCarts:DEBUG] " .. tostring(message))
end

-- ============================================================================
-- EVENT SYSTEM
-- ============================================================================
-- Provides lifecycle events for addon extensibility.
-- Addons can subscribe to events to react to cart state changes.
--
-- Usage:
--   SaucedCarts.Events.onCartEquip:Add(function(player, cart, source) ... end)
--   SaucedCarts.Events.onCartEquip:Remove(handler)

---@class SaucedCartsEvent
---@field name string Event name for debugging
---@field listeners function[] Registered listeners
---@field Add function(self, listener) Subscribe to event
---@field Remove function(self, listener) Unsubscribe from event

--- Create a new event object
---@param name string Event name for debugging
---@return SaucedCartsEvent
local function createEvent(name)
    local event = {
        name = name,
        listeners = {},
    }

    -- PZ-style :Add() method
    event.Add = function(self, listener)
        if type(listener) ~= "function" then
            SaucedCarts.error("Event.Add: listener must be a function")
            return
        end
        table.insert(self.listeners, listener)
        SaucedCarts.debug(function() return "Events: added listener to " .. self.name end)
    end

    -- PZ-style :Remove() method
    event.Remove = function(self, listener)
        for i, l in ipairs(self.listeners) do
            if l == listener then
                table.remove(self.listeners, i)
                SaucedCarts.debug(function() return "Events: removed listener from " .. self.name end)
                return true
            end
        end
        return false
    end

    return event
end

--- Fire an event (internal use only)
--- All listeners are called with pcall for error isolation
---@param event SaucedCartsEvent The event to fire
---@vararg any Arguments to pass to listeners
local function fireEvent(event, ...)
    if #event.listeners == 0 then return end  -- Fast path: no listeners

    for _, listener in ipairs(event.listeners) do
        local success, err = pcall(listener, ...)
        if not success then
            SaucedCarts.error("Event " .. event.name .. " listener error: " .. tostring(err))
        end
    end
end

-- Public event table for addon subscription
SaucedCarts.Events = {
    -- Lifecycle events (fire on both client and server where applicable)
    onCartEquip = createEvent("onCartEquip"),           -- (player, cart, source: "ground"|"inventory"|"vehicle")
    onCartDrop = createEvent("onCartDrop"),             -- (player, cart, square)
    onCartBroke = createEvent("onCartBroke"),           -- (player, cart, square)
    onCartRepair = createEvent("onCartRepair"),         -- (player, cart, repairAmount, newCondition)

    -- Container events (client-side)
    onCartContentsChanged = createEvent("onCartContentsChanged"),  -- (cart, player)
    onCartVisualUpdate = createEvent("onCartVisualUpdate"),        -- (cart, fillState, modelName)

    -- Movement events (client-side, throttled to ~1 tile)
    onCartMove = createEvent("onCartMove"),             -- (player, cart, distance)

    -- Upgrade events (fire on both client and server)
    onFlashlightInstalled = createEvent("onFlashlightInstalled"), -- (player, cart, flashlightType)
    onFlashlightToggled = createEvent("onFlashlightToggled"),     -- (player, cart, isActive)
    onBatteryInserted = createEvent("onBatteryInserted"),         -- (player, cart, chargeAmount)
    onBatteryRemoved = createEvent("onBatteryRemoved"),           -- (player, cart, chargeAmount)

    -- Registration events (fire during mod loading)
    onCartRegistered = createEvent("onCartRegistered"), -- (fullType, cartData)
    onRegistryFrozen = createEvent("onRegistryFrozen"), -- (cartCount)

    -- UI/Menu events (client-side, for addon menu extensions)
    onBuildCartSubmenu = createEvent("onBuildCartSubmenu"), -- (submenu, playerObj, cart, isWorldCart)
}

-- Internal fire function (not exposed to addons - they only subscribe)
SaucedCarts._fireEvent = fireEvent

-- ============================================================================
-- CONTAINER TYPE CONSTANTS
-- ============================================================================
-- Container types from vehicle scripts. Used for vehicle container detection.
-- Source: Java source (ItemContainer.java) + vehicle script files

SaucedCarts.ContainerTypes = {
    FLOOR = "floor",           -- Ground containers (ItemContainer.java:191)
    TRUNK = "trunk",           -- Vehicle trunk
    GLOVEBOX = "glovebox",     -- Glove compartment
    SEATREAR = "seatrear",     -- Rear seat storage
    TRUCKBED = "truckbed",     -- Pickup truck bed
    TRAILERTRUNK = "trailertrunk", -- Trailer storage
}

--- Check if container type matches any vehicle container pattern
--- Matches substrings to handle modded container types (e.g., "truckbedlarge")
---@param containerType string|nil The container type to check
---@return boolean True if this is a vehicle container type
function SaucedCarts.isVehicleContainerType(containerType)
    if not containerType then return false end
    local typeLower = string.lower(containerType)
    for _, pattern in pairs(SaucedCarts.ContainerTypes) do
        -- Skip FLOOR - ground is not a vehicle container
        if pattern ~= "floor" and string.find(typeLower, pattern) then
            return true
        end
    end
    return false
end

-- ============================================================================
-- CART VALIDATION
-- ============================================================================

--- Check if an item is a SaucedCarts cart
---@param item InventoryItem|nil The item to check
---@return boolean True if item is a SaucedCarts cart
function SaucedCarts.isCart(item)
    if not item then return false end
    -- Must be a Java object (userdata) - reject strings, tables, etc.
    -- This catches category headers, malformed item stacks, and mod-added UI elements
    if type(item) ~= "userdata" then return false end
    -- Ensure it's specifically an InventoryItem (not other Java objects)
    if not instanceof(item, "InventoryItem") then return false end
    -- Check if item belongs to SaucedCarts module
    local fullType = item:getFullType()
    return fullType and SaucedCarts.CartTypes[fullType] ~= nil
end

--- Check if an item is a valid cart that can be equipped/used
---@param item InventoryItem|nil The item to check
---@return boolean True if item is a valid usable cart
function SaucedCarts.isValidCart(item)
    if not SaucedCarts.isCart(item) then return false end
    return instanceof(item, "InventoryContainer")
end

--- Safely check if an item is a cart (wrapped in pcall)
--- Returns false on any error - fail-safe for hooks that should allow transfer on error.
--- Use this in hooks where breaking vanilla functionality is unacceptable.
---@param item any The item to check (can be nil or any type)
---@return boolean True if item is definitely a SaucedCarts cart, false otherwise (including on error)
function SaucedCarts.safeIsCart(item)
    if not item then return false end

    local success, result = pcall(function()
        return SaucedCarts.isCart(item)
    end)

    if not success then
        -- On error, return false (fail-safe)
        SaucedCarts.debug(function() return "safeIsCart error (returning false): " .. tostring(result) end)
        return false
    end

    return result == true
end

--- Check if a cart type is registered
---@param fullType string Full item type (e.g., "MyMod.MyCart")
---@return boolean True if the cart type is registered
function SaucedCarts.isRegistered(fullType)
    return SaucedCarts.CartTypes and SaucedCarts.CartTypes[fullType] ~= nil
end

--- Get the count of registered cart types
---@return number The number of registered cart types
function SaucedCarts.getCartTypeCount()
    if not SaucedCarts.CartTypes then return 0 end
    local count = 0
    for _ in pairs(SaucedCarts.CartTypes) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- CART INFO UTILITIES
-- ============================================================================

--- Get the cart's user-facing display name.
--- Returns the CUSTOM name if the player has renamed the item via vanilla's
--- rename UI (stored on item:getName()); falls back to the registered
--- CartType name; falls back to "Cart". Prefer this over reading
--- cartData.name directly so the context menu and notifications show
--- "Cartman" after a rename instead of the generic "Shopping Cart".
---@param cart InventoryItem|nil
---@return string
function SaucedCarts.getCartDisplayName(cart)
    -- Vanilla `setName` + `setCustomName(true)` (via the standard
    -- ISInventoryPaneContextMenu "Rename Bag" flow our InventoryContainer
    -- carts pick up automatically) sets the item's display name. vanilla
    -- syncItemFields handles MP propagation when the cart is grounded.
    if cart and cart.getName then
        local ok, n = pcall(function() return cart:getName() end)
        if ok and n and n ~= "" then return n end
    end
    local cartData = cart and SaucedCarts.getCartData and SaucedCarts.getCartData(cart)
    if cartData and cartData.name then return cartData.name end
    return "Cart"
end

--- Get the cart's current fill percentage (0-100)
--- When player is provided, accounts for Organized/Disorganized trait bonuses
---@param cart InventoryItem The cart item
---@param player IsoPlayer|nil Optional player for trait-aware capacity
---@return number Fill percentage (0-100)
function SaucedCarts.getFillPercent(cart, player)
    if not SaucedCarts.isValidCart(cart) then return 0 end

    ---@type ItemContainer
    local container = cart:getItemContainer()
    if not container then return 0 end

    local used = container:getCapacityWeight()
    local max
    if player then
        max = container:getEffectiveCapacity(player)
    else
        max = container:getCapacity()
    end
    if max <= 0 then return 0 end

    return math.floor((used / max) * 100)
end

--- Get the number of items in the cart
---@param cart InventoryItem The cart item
---@return number Number of items
function SaucedCarts.getItemCount(cart)
    if not SaucedCarts.isValidCart(cart) then return 0 end

    ---@type ItemContainer
    local container = cart:getItemContainer()
    if not container then return 0 end

    return container:getItems():size()
end

--- Get the cart's condition as a percentage (0-100)
---@param cart InventoryItem The cart item
---@return number Condition percentage (0-100)
function SaucedCarts.getConditionPercent(cart)
    if not cart then return 0 end

    local condition = cart:getCondition()
    local maxCondition = cart:getConditionMax()
    if maxCondition <= 0 then return 100 end

    return math.floor((condition / maxCondition) * 100)
end

-- ============================================================================
-- PLAYER UTILITIES
-- ============================================================================

--- Check if a player is currently holding a cart
---@param player IsoPlayer The player to check
---@return boolean True if player is holding a cart
function SaucedCarts.isHoldingCart(player)
    if not player then return false end
    local primary = player:getPrimaryHandItem()
    return SaucedCarts.isCart(primary)
end

--- Get the cart a player is holding, or nil
---@param player IsoPlayer The player to check
---@return InventoryItem|nil The held cart, or nil if not holding one
function SaucedCarts.getHeldCart(player)
    if not player then return nil end
    local primary = player:getPrimaryHandItem()
    if SaucedCarts.isCart(primary) then
        return primary
    end
    return nil
end

-- ============================================================================
-- SANDBOX MULTIPLIERS
-- ============================================================================

--- Apply sandbox multipliers to a cart when first encountered
--- Modifies capacity and durability based on sandbox settings
--- Also initializes schema version if not set
---@param cart InventoryItem The cart item to apply multipliers to
---@return boolean True if multipliers were applied, false if already applied or invalid
function SaucedCarts.applyMultipliers(cart)
    if not cart then
        SaucedCarts.error("applyMultipliers: cart is nil")
        return false
    end

    local modData = cart:getModData()

    -- Initialize schema version if not set (first touch of this cart)
    if not modData.SaucedCarts_schemaVersion then
        modData.SaucedCarts_schemaVersion = SaucedCarts.SCHEMA_VERSION
    end

    -- Skip multipliers if already applied
    if modData.SaucedCarts_multipliersApplied then
        -- Ensure raw capacity is in ModData (migration for saves before CapacityOverride)
        local rawCapKey = SaucedCarts.CapacityOverride and SaucedCarts.CapacityOverride.getRawCapacityKey()
        if rawCapKey and not modData[rawCapKey] then
            local cartData = SaucedCarts.getCartData(cart)
            if cartData then
                local capMult = SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.CapacityMultiplier or 100
                modData[rawCapKey] = math.floor(cartData.capacity * capMult / 100)
            end
        end
        return false
    end

    local cartData = SaucedCarts.getCartData(cart)
    if not cartData then
        SaucedCarts.error("applyMultipliers: no cartData for " .. tostring(cart:getFullType()))
        return false
    end

    -- Get sandbox multipliers (default to 100%)
    local capMult = 100
    local durMult = 100
    local weightRedMult = 100
    local speedPenMult = 100
    if SandboxVars.SaucedCarts then
        capMult = SandboxVars.SaucedCarts.CapacityMultiplier or 100
        durMult = SandboxVars.SaucedCarts.DurabilityMultiplier or 100
        weightRedMult = SandboxVars.SaucedCarts.WeightReduction or SandboxVars.SaucedCarts.WeightReductionMultiplier or 95
        speedPenMult = SandboxVars.SaucedCarts.SpeedPenaltyMultiplier or 100
    else
        SaucedCarts.error("applyMultipliers: SandboxVars.SaucedCarts is nil!")
    end

    SaucedCarts.debug(function() return "applyMultipliers: capMult=" .. capMult .. "%, durMult=" .. durMult ..
        "%, weightRedMult=" .. weightRedMult .. "%, speedPenMult=" .. speedPenMult .. "%" end)

    -- Apply capacity multiplier
    -- Java's setCapacity always stores the value (ItemContainer.java:171), but
    -- getCapacity() caps at Math.min(capacity, 50). We store the raw value in
    -- ModData so CapacityOverride.lua can read it back without hitting the cap.
    local container = cart:getItemContainer()
    if container then
        local baseCapacity = cartData.capacity
        local newCapacity = math.floor(baseCapacity * capMult / 100)
        container:setCapacity(newCapacity)

        -- Store raw capacity in ModData for CapacityOverride to read
        -- (Kahlua can't access Java fields directly; getCapacity() caps at 50)
        local rawCapKey = SaucedCarts.CapacityOverride and SaucedCarts.CapacityOverride.getRawCapacityKey()
        if rawCapKey then
            modData[rawCapKey] = newCapacity
        end

        SaucedCarts.debug(function() return "Capacity: base=" .. baseCapacity .. ", applied=" .. newCapacity end)

        -- Apply weight reduction (absolute value from sandbox, not a multiplier)
        -- 100 = items weigh nothing, 95 = items weigh 5% of normal, 0 = no reduction
        -- Clamped to 0-100 by Java's setWeightReduction
        local newWeightRed = weightRedMult
        container:setWeightReduction(newWeightRed)
        SaucedCarts.debug(function() return "WeightReduction: sandbox=" .. weightRedMult .. ", applied=" .. newWeightRed end)
    else
        SaucedCarts.error("applyMultipliers: container is nil for " .. tostring(cart:getFullType()))
    end

    -- Apply durability multiplier
    local baseConditionMax = cartData.conditionMax
    local newConditionMax = math.floor(baseConditionMax * durMult / 100)
    cart:setConditionMax(newConditionMax)
    SaucedCarts.debug(function() return "ConditionMax: base=" .. baseConditionMax .. ", applied=" .. newConditionMax end)

    -- Scale current condition proportionally if it's at max
    local currentCondition = cart:getCondition()
    if currentCondition == baseConditionMax or currentCondition > newConditionMax then
        cart:setCondition(newConditionMax)
    end

    -- Apply speed penalty multiplier
    -- Base runSpeedModifier is like 0.70 (30% penalty)
    -- 100% = normal penalty, 0% = no penalty, 200% = double penalty
    local baseSpeedMod = cartData.runSpeedModifier
    local basePenalty = 1 - baseSpeedMod  -- e.g., 0.30 for 30% penalty
    local scaledPenalty = basePenalty * speedPenMult / 100
    local newSpeedMod = math.max(0.1, 1 - scaledPenalty)  -- Clamp to min 0.1 (90% penalty max)
    -- Store in ModData - CartStateHandler uses this for movement speed
    modData.SaucedCarts_runSpeedModifier = newSpeedMod
    SaucedCarts.debug(function() return "RunSpeedModifier: base=" .. baseSpeedMod .. ", applied=" .. newSpeedMod end)

    -- Mark as applied
    modData.SaucedCarts_multipliersApplied = true

    return true
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--- Apply multipliers to all carts in a player's inventory
--- Called on game start to handle carts from saved games
---@param player IsoPlayer The player to check
---@return number Number of carts that had multipliers applied
local function applyMultipliersToPlayerCarts(player)
    if not player then return 0 end

    local inventory = player:getInventory()
    if not inventory then return 0 end

    local count = 0
    local items = inventory:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if SaucedCarts.isCart(item) then
            if SaucedCarts.applyMultipliers(item) then
                count = count + 1
            end
        end
    end

    return count
end

local function onGameStart()
    SaucedCarts.debug("Initializing SaucedCarts v" .. SaucedCarts.VERSION)

    -- Freeze the cart registry - no more registrations allowed after game start
    SaucedCarts._registryFrozen = true
    SaucedCarts.debug(function() return "Cart registry frozen - " .. SaucedCarts.getCartTypeCount() .. " cart type(s) registered" end)

    -- Fire registry frozen event
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onRegistryFrozen, SaucedCarts.getCartTypeCount())
    end

    -- Log sandbox settings (debug only)
    if SandboxVars.SaucedCarts then
        SaucedCarts.debug(function() return "Sandbox: Enabled=" .. tostring(SandboxVars.SaucedCarts.EnableMod) ..
            ", SpawnRate=" .. tostring(SandboxVars.SaucedCarts.SpawnRate) .. "%" ..
            ", Capacity=" .. tostring(SandboxVars.SaucedCarts.CapacityMultiplier) .. "%" ..
            ", Durability=" .. tostring(SandboxVars.SaucedCarts.DurabilityMultiplier) .. "%" end)
    end

    -- Apply multipliers to any carts already in player inventory (from saved games)
    local player = getPlayer()
    if player then
        local applied = applyMultipliersToPlayerCarts(player)
        if applied > 0 then
            SaucedCarts.debug(function() return "Applied multipliers to " .. applied .. " existing cart(s)" end)
        end

        -- Run cart migrations (schema versioning, orphan detection, condition validation)
        require("SaucedCarts/Migration")
        if SaucedCarts.Migration and SaucedCarts.Migration.migratePlayerInventory then
            local migrated, orphans = SaucedCarts.Migration.migratePlayerInventory(player)
            if migrated > 0 then
                SaucedCarts.debug(function() return "Migrated " .. migrated .. " cart(s), found " .. #orphans .. " orphan(s)" end)
            end
        end
    end
end

-- Register initialization event
Events.OnGameStart.Add(onGameStart)

-- Load container restrictions module (registers its own OnGameStart handler)
require "SaucedCarts/ContainerRestrictions"

-- Load capacity override for InventoryContainer trait support
require "SaucedCarts/CapacityOverride"

-- Load upgrade system
require "SaucedCarts/Upgrades"

-- Load guard against vanilla forceDropHeavyItems stale-hand-ref dupe
require "SaucedCarts/ForceDropGuard"

-- Load diagnostics (runs on both client and server, exposes SaucedCarts.capacityReport)
require "SaucedCarts/Diagnostics"

-- Load transfer interceptor for ground-cart deposits. Narrowly replaces
-- ISInventoryTransferAction ONLY for transfers whose destination is a
-- SaucedCarts cart NOT parented to an IsoGameCharacter. Every other
-- transfer path (including in-hand cart deposit) still uses vanilla.
require "SaucedCarts/CartTransferInterceptor"

-- Generic per-attribute sync framework — collapses the per-feature
-- ad-hoc network handlers / server registry / late-joiner replay we kept
-- rewriting (cart visual, ghost cleanup, etc.). MUST load before any
-- module that calls Sync.register. Currently no consumers; kept as
-- scaffolding for future per-attribute MP sync needs.
require "SaucedCarts/Sync"

-- Load corpse storage pipeline — custom action + server handler for
-- loading a dragged corpse (via getGrapplingTarget) into a cart container.
-- Bypasses vanilla canHumanCorpseFit's 19-string allowlist.
require "SaucedCarts/CorpseStorage"

-- Hook ISGrabCorpseItem so right-click "Grab" on cart-stored corpses
-- runs our rot short-circuit (silent drop past removalAt). Must load
-- AFTER CorpseStorage — references CorpseStorage helpers at call time.
require "SaucedCarts/GrabCorpseInterceptor"

SaucedCarts.debug("Core module loaded (v" .. SaucedCarts.VERSION .. ")")

return SaucedCarts
