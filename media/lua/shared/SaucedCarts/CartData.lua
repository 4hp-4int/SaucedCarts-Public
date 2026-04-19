-- ============================================================================
-- SaucedCarts/CartData.lua
-- ============================================================================
-- PURPOSE: Defines cart type properties and spawn configurations.
--          Properties here are for reference - actual item stats come from
--          items_saucedcarts.txt script definitions.
--
-- CONTEXT: SHARED (client + server)
--          Both need access to cart type data for UI and distributions.
-- ============================================================================

require "SaucedCarts/Core"

---@class SpawnRoomEntry
---@field room string Room name (e.g., "gigamart", "grocery")
---@field chance number Spawn probability 0-100

---@class VisualModels
---@field empty string Model name for empty state (0-32% full)
---@field partial string Model name for partial state (33-65% full)
---@field full string Model name for full state (66%+ full)

---@class UpgradeModels
---@field flashlight VisualModels|nil Models when flashlight installed

---@class CartTypeData
---@field name string Display name of the cart
---@field description string Flavor text description
---@field capacity number Storage capacity (units)
---@field weightReduction number Weight reduction percentage (0-100)
---@field runSpeedModifier number Movement speed multiplier (0.0-1.0)
---@field conditionMax number Maximum durability
---@field baseWeight number Base weight of empty cart (kg)
---@field repairItem string Full item type for repair material (e.g., "Base.ScrapMetal")
---@field repairAmount number Base condition restored per repair
---@field repairSkill Perks|nil Perk that affects repair (default: Perks.Maintenance at runtime)
---@field repairSkillBonus number Bonus condition per skill level (default: 1)
---@field repairTimeBase number Base repair duration in ticks (default: 100)
---@field repairXpGain number XP awarded per successful repair (default: 3)
---@field spawnRooms SpawnRoomEntry[] Room-based spawn locations with probabilities
---@field spawnWeight number Relative spawn weight for vehicle distributions
---@field visualModels VisualModels|nil Custom model names for fill states (optional)
---@field canHaveFlashlight boolean|nil Can install flashlight upgrade (default: true)
---@field upgradeModels UpgradeModels|nil Model overrides for upgraded states

--- Cart type definitions
--- Properties defined here are for reference/lookup - actual item stats come from items_saucedcarts.txt
---@type table<string, CartTypeData>
SaucedCarts.CartTypes = {
    ["SaucedCarts.ShoppingCart"] = {
        name = "Shopping Cart",
        description = "A metal shopping cart. Great for hauling supplies from stores.",
        capacity = 50,  -- PZ caps InventoryContainer items at 50 (ItemContainer.java:155-156)
        weightReduction = 95,
        runSpeedModifier = 0.70,
        conditionMax = 100,
        baseWeight = 8.0,
        repairItem = "Base.ScrapMetal",
        repairAmount = 10,  -- condition restored per repair
        -- Room-based world spawning (carts spawn on the ground)
        -- Note: Default spawn rooms are defined in SpawnLocations.lua
        -- This field is for addons to define custom spawn locations
        spawnRooms = {},
        spawnWeight = 6,  -- Weight for vehicle distributions
        -- Visual models for fill states (must match model definitions in scripts)
        visualModels = {
            empty = "ShoppingCartModel",
            partial = "ShoppingCartPartialModel",
            full = "ShoppingCartFullModel",
        },
        -- Upgrade capability (can install flashlight)
        canHaveFlashlight = true,
        -- Upgrade-specific visual models (cart with attached flashlight)
        upgradeModels = {
            flashlight = {
                empty = "ShoppingCartFlashlightModel",
                partial = "ShoppingCartFlashlightPartialModel",
                full = "ShoppingCartFlashlightFullModel",
            },
        },
    },
}

-- ============================================================================
-- CART REGISTRATION API
-- ============================================================================
-- External mods can use SaucedCarts.registerCart() to add custom cart types.
-- Registration must happen BEFORE OnGameStart (during mod loading).

-- Default values for optional fields
local CART_DEFAULTS = {
    description = "",
    capacity = 50,
    weightReduction = 90,
    runSpeedModifier = 0.75,
    conditionMax = 100,
    baseWeight = 5.0,
    repairItem = "Base.ScrapMetal",
    repairAmount = 10,
    repairSkill = nil,  -- nil = use Perks.Maintenance (resolved at runtime)
    repairSkillBonus = 1,  -- +1 condition per skill level
    repairTimeBase = 100,  -- Base repair duration in ticks
    repairXpGain = 3,  -- XP awarded per successful repair
    spawnRooms = {},  -- Room-based spawning (array of {room, chance})
    spawnWeight = 1,
    visualModels = nil,  -- nil = use convention-based naming (see CartVisuals.lua)
    canHaveFlashlight = true,  -- true = can install flashlight upgrade
    upgradeModels = nil,  -- nil = use standard fill-state models when upgraded
}

-- Expected types for each field (for validation)
-- Note: repairSkill is validated separately (Perk userdata or nil)
-- Note: This table is also used as the source of truth for field iteration
-- during registration (pairs() skips nil values in CART_DEFAULTS)
local FIELD_TYPES = {
    name = "string",  -- Required field, validated separately
    description = "string",
    capacity = "number",
    weightReduction = "number",
    runSpeedModifier = "number",
    conditionMax = "number",
    baseWeight = "number",
    repairItem = "string",
    repairAmount = "number",
    repairSkill = "skip",  -- Perk userdata, validated separately
    repairSkillBonus = "number",
    repairTimeBase = "number",
    repairXpGain = "number",
    spawnRooms = "table",  -- Array of {room, chance} entries
    spawnWeight = "number",
    visualModels = "table",  -- {empty, partial, full} model names
    canHaveFlashlight = "boolean",  -- Can install flashlight upgrade
    upgradeModels = "table",  -- {flashlight} with {empty, partial, full}
}

-- Valid ranges for numeric fields
local FIELD_RANGES = {
    capacity = {1, 1000},
    weightReduction = {0, 100},
    runSpeedModifier = {0.01, 2.0},
    conditionMax = {1, 1000},
    baseWeight = {0.1, 500},
    repairAmount = {1, 100},
    repairSkillBonus = {0, 10},  -- 0 = no skill bonus, 10 = max
    repairTimeBase = {10, 500},  -- Ticks (10 = instant-ish, 500 = very long)
    repairXpGain = {0, 50},  -- 0 = no XP, 50 = max
    spawnWeight = {0, 100},
}

-- =============================================================================
-- VALIDATOR SYNC CHECK
-- =============================================================================
-- Ensure every field in CART_DEFAULTS has a corresponding validator in FIELD_TYPES.
-- This prevents silent registration of unvalidated fields if CART_DEFAULTS is updated
-- but FIELD_TYPES is not.
for field, _ in pairs(CART_DEFAULTS) do
    if not FIELD_TYPES[field] then
        error("SaucedCarts: FIELD_TYPES missing validator for CART_DEFAULTS field: " .. tostring(field))
    end
end

--- Internal: Validate fullType format (must be "Module.ItemName")
---@param fullType any
---@return boolean valid
---@return string|nil error
local function validateFullType(fullType)
    if type(fullType) ~= "string" then
        return false, "fullType must be a string, got " .. type(fullType)
    end
    if fullType == "" then
        return false, "fullType cannot be empty"
    end
    -- Must have Module.ItemName format (alphanumeric + underscores)
    local module, itemName = fullType:match("^([%w_]+)%.([%w_]+)$")
    if not module or not itemName then
        return false, string.format("fullType must be 'ModuleName.ItemName' format, got '%s'", fullType)
    end
    return true, nil
end

--- Internal: Validate a single field value
---@param fieldName string
---@param value any
---@return boolean valid
---@return string|nil error
local function validateField(fieldName, value)
    -- Type check
    local expectedType = FIELD_TYPES[fieldName]
    -- "skip" means this field has special validation elsewhere (e.g., repairSkill)
    if expectedType == "skip" then
        return true, nil
    end
    if expectedType and type(value) ~= expectedType then
        return false, string.format("Field '%s' must be %s, got %s", fieldName, expectedType, type(value))
    end
    -- Range check for numbers
    local range = FIELD_RANGES[fieldName]
    if range and type(value) == "number" then
        if value < range[1] or value > range[2] then
            return false, string.format("Field '%s' must be between %s and %s, got %s",
                fieldName, tostring(range[1]), tostring(range[2]), tostring(value))
        end
    end
    return true, nil
end

--- Internal: Validate spawnRooms array
--- Each entry must be {room = "roomname", chance = 0-100}
---@param spawnRooms any
---@return boolean valid
---@return string|nil error
local function validateSpawnRooms(spawnRooms)
    if type(spawnRooms) ~= "table" then
        return false, "spawnRooms must be a table"
    end
    for i, entry in ipairs(spawnRooms) do
        if type(entry) ~= "table" then
            return false, string.format("spawnRooms[%d] must be a table, got %s", i, type(entry))
        end
        if not entry.room or type(entry.room) ~= "string" or entry.room == "" then
            return false, string.format("spawnRooms[%d].room must be a non-empty string", i)
        end
        if entry.chance then
            if type(entry.chance) ~= "number" then
                return false, string.format("spawnRooms[%d].chance must be a number", i)
            end
            if entry.chance < 0 or entry.chance > 100 then
                return false, string.format("spawnRooms[%d].chance must be 0-100, got %s", i, entry.chance)
            end
        end
    end
    return true, nil
end

--- Internal: Validate visualModels table
--- Must have {empty, partial, full} with string model names
---@param visualModels any
---@return boolean valid
---@return string|nil error
local function validateVisualModels(visualModels)
    if type(visualModels) ~= "table" then
        return false, "visualModels must be a table"
    end
    local requiredFields = {"empty", "partial", "full"}
    for _, field in ipairs(requiredFields) do
        local value = visualModels[field]
        if not value then
            return false, string.format("visualModels.%s is required", field)
        end
        if type(value) ~= "string" or value == "" then
            return false, string.format("visualModels.%s must be a non-empty string", field)
        end
    end
    return true, nil
end

--- Internal: Validate repairSkill field
--- Must be nil (use default Perks.Maintenance) or a Perk userdata
--- Note: We can't validate the specific Perk type at load time since Perks
--- may not be initialized yet. We verify it's userdata (Perk enum type).
---@param repairSkill any
---@return boolean valid
---@return string|nil error
local function validateRepairSkill(repairSkill)
    -- nil is valid (will use Perks.Maintenance at runtime)
    if repairSkill == nil then
        return true, nil
    end
    -- Must be userdata (Perk enum type in PZ)
    if type(repairSkill) ~= "userdata" then
        return false, string.format("repairSkill must be a Perk (userdata) or nil, got %s", type(repairSkill))
    end
    return true, nil
end

--- Internal: Validate upgradeModels table
--- Keys must be upgrade names (flashlight)
--- Values must be VisualModels tables {empty, partial, full}
---@param upgradeModels any
---@return boolean valid
---@return string|nil error
local function validateUpgradeModels(upgradeModels)
    if type(upgradeModels) ~= "table" then
        return false, "upgradeModels must be a table"
    end

    local validKeys = { flashlight = true }

    for key, models in pairs(upgradeModels) do
        if type(key) ~= "string" then
            return false, "upgradeModels keys must be strings"
        end
        if not validKeys[key] then
            return false, string.format("upgradeModels key '%s' is not valid (must be: flashlight)", key)
        end
        if type(models) ~= "table" then
            return false, string.format("upgradeModels.%s must be a table", key)
        end
        -- Validate as VisualModels (empty, partial, full)
        local requiredFields = { "empty", "partial", "full" }
        for _, field in ipairs(requiredFields) do
            local value = models[field]
            if not value then
                return false, string.format("upgradeModels.%s.%s is required", key, field)
            end
            if type(value) ~= "string" or value == "" then
                return false, string.format("upgradeModels.%s.%s must be a non-empty string", key, field)
            end
        end
    end

    return true, nil
end

--- Register a custom cart type for external mods
--- Call this from your mod's shared Lua file BEFORE OnGameStart
---
--- Example (minimal):
---   SaucedCarts.registerCart("MyMod.Wheelbarrow", {
---       name = "Wheelbarrow",
---       capacity = 40,
---       weightReduction = 80,
---   })
---
--- Example (with custom visual models):
---   SaucedCarts.registerCart("MyMod.Wheelbarrow", {
---       name = "Wheelbarrow",
---       capacity = 40,
---       visualModels = {
---           empty = "WheelbarrowModel",
---           partial = "WheelbarrowPartialModel",
---           full = "WheelbarrowFullModel",
---       },
---   })
---
--- NOTE: If visualModels is not provided, the system will attempt convention-based
--- naming derived from the item's StaticModel (e.g., "FooModel" -> "FooPartialModel").
--- For best results, always specify visualModels explicitly.
---
---@param fullType string Full item type (e.g., "MyMod.MyCart")
---@param data table Cart properties (only 'name' is required)
---@return boolean success Whether registration succeeded
---@return string|nil error Error message if failed
function SaucedCarts.registerCart(fullType, data)
    -- Check if registry is frozen (after OnGameStart)
    if SaucedCarts._registryFrozen then
        local msg = string.format("Cannot register cart '%s': registry is frozen after game start", tostring(fullType))
        SaucedCarts.error(msg)
        return false, msg
    end

    -- Validate fullType format
    local valid, err = validateFullType(fullType)
    if not valid then
        SaucedCarts.error("registerCart failed: " .. err)
        return false, err
    end

    -- Check for duplicate registration
    if SaucedCarts.CartTypes[fullType] then
        local msg = string.format("Cart type '%s' is already registered", fullType)
        SaucedCarts.error("registerCart failed: " .. msg)
        return false, msg
    end

    -- Validate data is a table
    if type(data) ~= "table" then
        local msg = "data must be a table, got " .. type(data)
        SaucedCarts.error("registerCart failed: " .. msg)
        return false, msg
    end

    -- Validate required field: name
    if not data.name then
        local msg = "Required field 'name' is missing"
        SaucedCarts.error("registerCart failed for '" .. fullType .. "': " .. msg)
        return false, msg
    end
    if type(data.name) ~= "string" or data.name == "" then
        local msg = "Field 'name' must be a non-empty string"
        SaucedCarts.error("registerCart failed for '" .. fullType .. "': " .. msg)
        return false, msg
    end

    -- Validate all provided fields
    for fieldName, value in pairs(data) do
        if FIELD_TYPES[fieldName] then
            valid, err = validateField(fieldName, value)
            if not valid then
                SaucedCarts.error("registerCart failed for '" .. fullType .. "': " .. err)
                return false, err
            end
        else
            -- Warn about unknown fields but don't fail (forward compatibility)
            SaucedCarts.debug(function() return string.format("registerCart: Unknown field '%s' for '%s' (ignored)", fieldName, fullType) end)
        end
    end

    -- Validate spawnRooms if provided
    if data.spawnRooms then
        valid, err = validateSpawnRooms(data.spawnRooms)
        if not valid then
            SaucedCarts.error("registerCart failed for '" .. fullType .. "': " .. err)
            return false, err
        end
    end

    -- Validate visualModels if provided
    if data.visualModels then
        valid, err = validateVisualModels(data.visualModels)
        if not valid then
            SaucedCarts.error("registerCart failed for '" .. fullType .. "': " .. err)
            return false, err
        end
    end

    -- Validate repairItem format if provided
    if data.repairItem then
        valid, err = validateFullType(data.repairItem)
        if not valid then
            local msg = "repairItem: " .. err
            SaucedCarts.error("registerCart failed for '" .. fullType .. "': " .. msg)
            return false, msg
        end
    end

    -- Validate repairSkill if provided (must be Perk userdata or nil)
    if data.repairSkill ~= nil then
        valid, err = validateRepairSkill(data.repairSkill)
        if not valid then
            SaucedCarts.error("registerCart failed for '" .. fullType .. "': " .. err)
            return false, err
        end
    end

    -- Validate upgradeModels if provided
    if data.upgradeModels then
        valid, err = validateUpgradeModels(data.upgradeModels)
        if not valid then
            SaucedCarts.error("registerCart failed for '" .. fullType .. "': " .. err)
            return false, err
        end
    end

    -- Build final cart data with defaults for missing optional fields
    local cartData = {}

    -- Debug: Log what we received for visualModels
    SaucedCarts.debug(function() return string.format(
        "registerCart '%s': data.visualModels=%s (type=%s)",
        fullType,
        data.visualModels and "defined" or "nil",
        type(data.visualModels)
    ) end)
    if data.visualModels then
        SaucedCarts.debug(function() return string.format(
            "registerCart '%s': visualModels.empty='%s', partial='%s', full='%s'",
            fullType,
            tostring(data.visualModels.empty),
            tostring(data.visualModels.partial),
            tostring(data.visualModels.full)
        ) end)
    end

    -- Copy fields from CART_DEFAULTS, overriding with data values if provided
    -- NOTE: pairs() skips keys with nil values, so we must use FIELD_TYPES as the
    -- source of truth for which fields exist (it has all fields including visualModels)
    for field, _ in pairs(FIELD_TYPES) do
        if data[field] ~= nil then
            cartData[field] = data[field]
        elseif CART_DEFAULTS[field] ~= nil then
            cartData[field] = CART_DEFAULTS[field]
        end
        -- If both are nil, field just won't be set (that's fine for optional fields like visualModels)
    end
    -- name is already in FIELD_TYPES and copied above, but ensure it's set from data
    -- (it has no default in CART_DEFAULTS, but data.name was validated as required)

    -- Debug: Verify visualModels was copied
    SaucedCarts.debug(function() return string.format(
        "registerCart '%s': after copy, cartData.visualModels=%s",
        fullType,
        cartData.visualModels and "defined" or "nil"
    ) end)

    -- Register the cart type
    SaucedCarts.CartTypes[fullType] = cartData

    -- Add spawn rooms to SpawnLocations if provided
    -- (SpawnLocations.lua must be loaded for this to work)
    if cartData.spawnRooms and #cartData.spawnRooms > 0 then
        if SaucedCarts.addSpawnRooms then
            SaucedCarts.addSpawnRooms(fullType, cartData.spawnRooms)
        else
            SaucedCarts.debug("registerCart: SpawnLocations not loaded yet, spawn rooms will be processed later")
        end
    end

    SaucedCarts.debug(string.format("Registered cart type '%s' (%s)", fullType, cartData.name))

    -- Fire registration event
    if SaucedCarts._fireEvent then
        SaucedCarts._fireEvent(SaucedCarts.Events.onCartRegistered, fullType, cartData)
    end

    return true, nil
end

--- Process any registrations queued by mods that loaded before SaucedCarts
local function processPendingRegistrations()
    local pending = SaucedCarts._pendingRegistrations or {}
    local count = #pending

    if count > 0 then
        SaucedCarts.debug(function() return "Processing " .. count .. " pending cart registration(s)" end)
    end

    for _, reg in ipairs(pending) do
        local success, err = SaucedCarts.registerCart(reg.fullType, reg.data)
        if not success then
            SaucedCarts.error("Pending registration for '" .. tostring(reg.fullType) .. "' failed: " .. tostring(err))
        end
    end

    -- Clear the queue
    SaucedCarts._pendingRegistrations = {}
end

-- Process any pending registrations now that CartData is loaded
processPendingRegistrations()

-- ============================================================================
-- CART DATA ACCESSORS
-- ============================================================================

--- Get cart data by item instance
---@param item InventoryItem The cart item
---@return CartTypeData|nil The cart type data, or nil if not found
function SaucedCarts.getCartData(item)
    if not item then return nil end
    local fullType = item:getFullType()
    return SaucedCarts.CartTypes[fullType]
end

--- Get cart data by full item type string
---@param fullType string Full item type (e.g., "SaucedCarts.ShoppingCart")
---@return CartTypeData|nil The cart type data, or nil if not found
function SaucedCarts.getCartDataByType(fullType)
    return SaucedCarts.CartTypes[fullType]
end

--- Get all cart type strings
---@return string[] Array of full item type strings
function SaucedCarts.getAllCartTypes()
    local types = {}
    for fullType, _ in pairs(SaucedCarts.CartTypes) do
        table.insert(types, fullType)
    end
    return types
end

--- Get cart display name from item or type
---@param itemOrType InventoryItem|string The cart item or full type string
---@return string The display name, or "Cart" if not found
function SaucedCarts.getCartName(itemOrType)
    local data
    if type(itemOrType) == "string" then
        data = SaucedCarts.getCartDataByType(itemOrType)
    else
        data = SaucedCarts.getCartData(itemOrType)
    end
    return data and data.name or "Cart"
end

SaucedCarts.debug(function() return "CartData loaded - " .. #SaucedCarts.getAllCartTypes() .. " cart types defined" end)

return SaucedCarts.CartTypes
