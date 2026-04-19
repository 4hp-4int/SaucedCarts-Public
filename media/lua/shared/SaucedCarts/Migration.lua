-- ============================================================================
-- SaucedCarts/Migration.lua
-- ============================================================================
-- PURPOSE: Schema versioning, cart migration, and orphan detection.
--          Handles forward compatibility for saved games when cart types
--          are renamed, removed, or modified.
--
-- CONTEXT: SHARED (client + server)
--          Migration logic runs on both sides for proper sync.
--
-- USAGE: Called automatically on game start via Core.lua
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/Upgrades"

---@class SaucedCartsMigration
SaucedCarts.Migration = {}

-- ============================================================================
-- ORPHAN DETECTION
-- ============================================================================

--- Check if an item looks like a SaucedCarts cart (even if unregistered)
--- Uses heuristics: SaucedCarts prefix, InventoryContainer, or ModData markers
---@param item InventoryItem|nil The item to check
---@return boolean True if item appears to be a cart (registered or orphaned)
function SaucedCarts.Migration.looksLikeCart(item)
    if not item then return false end

    -- Must be a container (carts hold items)
    if not instanceof(item, "InventoryContainer") then return false end

    local fullType = item:getFullType()

    -- Check for SaucedCarts module prefix
    if fullType and fullType:find("^SaucedCarts%.") then
        return true
    end

    -- Check for our ModData markers (from previously registered carts)
    local modData = item:getModData()
    if modData.SaucedCarts_schemaVersion then return true end
    if modData.SaucedCarts_multipliersApplied then return true end
    if modData.SaucedCarts_fillState then return true end
    if modData.SaucedCarts_isOrphan then return true end
    if modData.SaucedCarts_rawCapacity then return true end
    -- Check for upgrade system markers
    if modData.SaucedCarts_hasFlashlight then return true end
    if modData.SaucedCarts_batteryCharge then return true end

    return false
end

-- ============================================================================
-- CART MIGRATION
-- ============================================================================

--- Migrate a single cart item
--- Handles: schema versioning, type aliases, orphan detection, condition validation
---@param item InventoryItem The cart item to migrate
---@return boolean success Whether migration completed
---@return table issues List of issues found/fixed (strings)
function SaucedCarts.Migration.migrateCart(item)
    if not item then return false, {"nil item"} end

    local modData = item:getModData()
    local fullType = item:getFullType()
    local savedVersion = modData.SaucedCarts_schemaVersion or 0
    local issues = {}

    -- 1. Type alias migration (for renamed cart types)
    local aliasedType = SaucedCarts.TYPE_ALIASES and SaucedCarts.TYPE_ALIASES[fullType]
    if aliasedType then
        modData.SaucedCarts_originalType = fullType
        modData.SaucedCarts_aliasedTo = aliasedType
        table.insert(issues, "type_aliased")
        SaucedCarts.debug(function() return "Migration: aliased '" .. fullType .. "' to '" .. aliasedType .. "'" end)
    end

    -- 2. Orphan detection (cart type not registered)
    local isRegistered = SaucedCarts.isCart(item)
    local hasAlias = aliasedType ~= nil
    local isOrphan = not isRegistered and not hasAlias

    if isOrphan and SaucedCarts.Migration.looksLikeCart(item) then
        -- Only mark as orphan if it looks like one of our carts
        modData.SaucedCarts_isOrphan = true
        modData.SaucedCarts_orphanedAt = os.time()
        modData.SaucedCarts_orphanedType = fullType
        table.insert(issues, "orphaned")
        SaucedCarts.debug("Migration: detected orphan cart type '" .. fullType .. "'")
    elseif isRegistered and modData.SaucedCarts_isOrphan then
        -- Cart was previously orphaned but type is now registered (addon re-added)
        modData.SaucedCarts_isOrphan = nil
        modData.SaucedCarts_restoredAt = os.time()
        table.insert(issues, "restored")
        SaucedCarts.debug("Migration: restored previously orphaned cart '" .. fullType .. "'")
    end

    -- 3. Condition validation
    local condition = item:getCondition()
    local condMax = item:getConditionMax()

    if condition < 0 then
        item:setCondition(0)
        table.insert(issues, "condition_negative")
        SaucedCarts.debug(function() return "Migration: fixed negative condition for " .. fullType end)
    elseif condMax > 0 and condition > condMax then
        item:setCondition(condMax)
        table.insert(issues, "condition_overflow")
        SaucedCarts.debug(function() return "Migration: clamped condition overflow for " .. fullType end)
    end

    -- 4. Update schema version
    if savedVersion < SaucedCarts.SCHEMA_VERSION then
        modData.SaucedCarts_previousVersion = savedVersion
        modData.SaucedCarts_schemaVersion = SaucedCarts.SCHEMA_VERSION
        modData.SaucedCarts_migratedAt = os.time()

        if savedVersion > 0 then
            table.insert(issues, "schema_upgraded")
            SaucedCarts.debug(function() return "Migration: upgraded schema " .. savedVersion .. " -> " .. SaucedCarts.SCHEMA_VERSION end)
        else
            table.insert(issues, "schema_initialized")
        end
    end

    -- 5. Ensure upgrade system fields are properly initialized
    -- Note: Upgrades are optional - carts work fine without them
    -- This just ensures any partial/corrupted upgrade data is cleaned up
    if modData.SaucedCarts_hasFlashlight then
        -- Validate flashlight data exists
        if not modData.SaucedCarts_flashlightData then
            -- Flashlight flag set but no data - create defaults
            modData.SaucedCarts_flashlightData = {
                lightStrength = 0.8,
                lightDistance = 10,
                torchCone = true,
                originalType = "Base.Flashlight",
                originalName = "Flashlight",
            }
            table.insert(issues, "flashlight_data_repaired")
            SaucedCarts.debug(function() return "Migration: repaired missing flashlight data for " .. fullType end)
        end

        -- Validate battery charge is a number
        local charge = modData.SaucedCarts_batteryCharge
        if charge == nil or type(charge) ~= "number" then
            modData.SaucedCarts_batteryCharge = 0
            table.insert(issues, "battery_charge_repaired")
        elseif charge < 0 then
            modData.SaucedCarts_batteryCharge = 0
            table.insert(issues, "battery_charge_clamped")
        elseif charge > 1 then
            modData.SaucedCarts_batteryCharge = 1
            table.insert(issues, "battery_charge_clamped")
        end

        -- Validate light active is boolean
        if modData.SaucedCarts_isLightActive ~= nil and type(modData.SaucedCarts_isLightActive) ~= "boolean" then
            modData.SaucedCarts_isLightActive = false
            table.insert(issues, "light_state_repaired")
        end
    end

    -- 6. Ensure raw capacity is stored in ModData (v2 → v3 migration)
    -- CapacityOverride reads raw capacity from ModData to bypass Java's 50 cap.
    -- Old saves won't have this field, so compute it from CartData + sandbox multiplier.
    if savedVersion < 3 and SaucedCarts.isCart(item) then
        local rawCapKey = SaucedCarts.CapacityOverride
            and SaucedCarts.CapacityOverride.getRawCapacityKey()
        if rawCapKey and not modData[rawCapKey] then
            local cartData = SaucedCarts.getCartData(item)
            if cartData then
                local capMult = SandboxVars.SaucedCarts
                    and SandboxVars.SaucedCarts.CapacityMultiplier or 100
                modData[rawCapKey] = math.floor(cartData.capacity * capMult / 100)
                table.insert(issues, "rawcapacity_initialized")
                SaucedCarts.debug(function() return "Migration: initialized rawCapacity=" .. modData[rawCapKey] .. " for " .. fullType end)
            end
        end
    end

    return true, issues
end

--- Migrate all carts in a player's inventory
--- Called on game start to handle carts from saved games
---@param player IsoPlayer The player to check
---@return number migrated Number of carts migrated
---@return table orphans List of orphaned cart items
function SaucedCarts.Migration.migratePlayerInventory(player)
    if not player then return 0, {} end

    local inventory = player:getInventory()
    if not inventory then return 0, {} end

    local migrated = 0
    local orphans = {}
    local items = inventory:getItems()

    for i = 0, items:size() - 1 do
        local item = items:get(i)

        -- Check registered carts AND items that look like carts (orphans)
        if SaucedCarts.isCart(item) or SaucedCarts.Migration.looksLikeCart(item) then
            local success, issues = SaucedCarts.Migration.migrateCart(item)

            if success then
                migrated = migrated + 1

                -- Track orphans for notification
                for _, issue in ipairs(issues) do
                    if issue == "orphaned" then
                        table.insert(orphans, item)
                    end
                end
            end
        end
    end

    -- Notify about orphans (client-side only)
    if #orphans > 0 and isClient() then
        require("SaucedCarts/OrphanRecovery")
        if SaucedCarts.OrphanRecovery and SaucedCarts.OrphanRecovery.notifyOrphans then
            SaucedCarts.OrphanRecovery.notifyOrphans(player, orphans)
        end
    end

    if migrated > 0 then
        SaucedCarts.debug(function() return "Migration: processed " .. migrated .. " cart(s), " .. #orphans .. " orphan(s)" end)
    end

    return migrated, orphans
end

-- ============================================================================
-- ORPHAN RECOVERY
-- ============================================================================

--- Recover items from an orphan cart to player inventory
--- Transfers all contents and removes the broken cart
---@param cart InventoryItem The orphaned cart to recover from
---@param player IsoPlayer The player to receive items
---@return boolean success Whether recovery completed
---@return number|string result Item count on success, error message on failure
function SaucedCarts.Migration.recoverOrphanCart(cart, player)
    if not cart then return false, "cart is nil" end
    if not player then return false, "player is nil" end
    if not instanceof(cart, "InventoryContainer") then return false, "not a container" end

    local container = cart:getItemContainer()
    if not container then return false, "no container found" end

    local playerInv = player:getInventory()
    local itemCount = container:getItems():size()
    local recovered = 0

    -- Transfer items to player inventory (iterate backwards to avoid index shifting)
    local items = container:getItems()
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        container:Remove(item)
        playerInv:AddItem(item)

        -- Sync in MP and SP (not on dedicated server)
        if not isServer() then
            sendAddItemToContainer(playerInv, item)
        end

        recovered = recovered + 1
    end

    -- Remove the broken cart
    playerInv:Remove(cart)

    -- Sync removal in MP and SP (not on dedicated server)
    if not isServer() then
        sendRemoveItemFromContainer(playerInv, cart)
    end

    local cartType = cart:getFullType()
    SaucedCarts.debug("Recovered " .. recovered .. " items from orphan cart '" .. cartType .. "'")

    return true, recovered
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Check if a cart is an orphan (type not registered)
---@param item InventoryItem|nil The item to check
---@return boolean True if item is an orphaned cart
function SaucedCarts.Migration.isOrphan(item)
    if not item then return false end
    local modData = item:getModData()
    return modData.SaucedCarts_isOrphan == true
end

--- Get schema info for a cart (for debugging)
---@param item InventoryItem The cart to inspect
---@return table info Schema information
function SaucedCarts.Migration.getSchemaInfo(item)
    if not item then return {error = "nil item"} end

    local modData = item:getModData()

    return {
        fullType = item:getFullType(),
        schemaVersion = modData.SaucedCarts_schemaVersion or 0,
        previousVersion = modData.SaucedCarts_previousVersion,
        migratedAt = modData.SaucedCarts_migratedAt,
        isOrphan = modData.SaucedCarts_isOrphan or false,
        orphanedAt = modData.SaucedCarts_orphanedAt,
        orphanedType = modData.SaucedCarts_orphanedType,
        originalType = modData.SaucedCarts_originalType,
        aliasedTo = modData.SaucedCarts_aliasedTo,
        restoredAt = modData.SaucedCarts_restoredAt,
        multipliersApplied = modData.SaucedCarts_multipliersApplied or false,
        fillState = modData.SaucedCarts_fillState,
        rawCapacity = modData.SaucedCarts_rawCapacity,
        -- Upgrade system info
        hasFlashlight = modData.SaucedCarts_hasFlashlight or false,
        batteryCharge = modData.SaucedCarts_batteryCharge or 0,
        isLightActive = modData.SaucedCarts_isLightActive or false,
        flashlightData = modData.SaucedCarts_flashlightData,
    }
end

--- Find all orphan carts in a player's inventory
---@param player IsoPlayer The player to check
---@return table orphans List of orphaned cart items
function SaucedCarts.Migration.findOrphans(player)
    if not player then return {} end

    local inventory = player:getInventory()
    if not inventory then return {} end

    local orphans = {}
    local items = inventory:getItems()

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if SaucedCarts.Migration.isOrphan(item) then
            table.insert(orphans, item)
        end
    end

    return orphans
end

--- Force migrate a specific cart (for debugging)
---@param item InventoryItem The cart to migrate
---@return boolean success
---@return table issues
function SaucedCarts.Migration.forceMigrate(item)
    return SaucedCarts.Migration.migrateCart(item)
end

--- Mark a cart as orphan for testing purposes
---@param item InventoryItem The cart to mark as orphan
---@return boolean success
function SaucedCarts.Migration.markAsOrphan(item)
    if not item then return false end

    local modData = item:getModData()
    modData.SaucedCarts_isOrphan = true
    modData.SaucedCarts_orphanedAt = os.time()
    modData.SaucedCarts_orphanedType = item:getFullType()

    SaucedCarts.debug(function() return "Marked cart as orphan for testing: " .. item:getFullType() end)

    return true
end

--- Clear orphan status from a cart (for testing)
---@param item InventoryItem The cart to clear
---@return boolean success
function SaucedCarts.Migration.clearOrphanStatus(item)
    if not item then return false end

    local modData = item:getModData()
    modData.SaucedCarts_isOrphan = nil
    modData.SaucedCarts_orphanedAt = nil
    modData.SaucedCarts_orphanedType = nil

    SaucedCarts.debug(function() return "Cleared orphan status from cart: " .. item:getFullType() end)

    return true
end

SaucedCarts.debug("Migration module loaded")

return SaucedCarts.Migration
