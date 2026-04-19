-- ============================================================================
-- SaucedCarts/Debug/MigrationCommands.lua
-- ============================================================================
-- PURPOSE: Migration and orphan recovery debug commands
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"

local Utils = require "SaucedCarts/Debug/Utils"

local MigrationCommands = {}

--- Force run migration on the currently held cart
--- Shows what issues are detected and fixed
function MigrationCommands.testMigration()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    require "SaucedCarts/Migration"

    local success, issues = SaucedCarts.Migration.forceMigrate(cart)

    print("=== Migration Test Results ===")
    print("  Cart: " .. cart:getFullType())
    print("  Success: " .. tostring(success))

    if #issues > 0 then
        print("  Issues found/fixed:")
        for _, issue in ipairs(issues) do
            print("    - " .. issue)
        end
    else
        print("  No issues detected")
    end

    print("==============================")
end

--- Mark the currently held cart as an orphan for testing
--- This simulates what happens when an addon is removed
function MigrationCommands.makeOrphan()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    require "SaucedCarts/Migration"

    if SaucedCarts.Migration.markAsOrphan(cart) then
        print("[SaucedCarts] Marked cart as orphan: " .. cart:getFullType())
        print("[SaucedCarts] Drop the cart and right-click to see recovery option")

        -- Add to orphan cache so context menu shows recovery option
        SaucedCarts._orphanedCarts = SaucedCarts._orphanedCarts or {}
        SaucedCarts._orphanedCarts[cart:getID()] = true
    else
        print("[SaucedCarts] Failed to mark cart as orphan")
    end
end

--- Clear orphan status from the currently held cart
function MigrationCommands.clearOrphan()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    require "SaucedCarts/Migration"

    if SaucedCarts.Migration.clearOrphanStatus(cart) then
        print("[SaucedCarts] Cleared orphan status from cart")

        -- Remove from orphan cache
        SaucedCarts._orphanedCarts = SaucedCarts._orphanedCarts or {}
        SaucedCarts._orphanedCarts[cart:getID()] = nil
    else
        print("[SaucedCarts] Failed to clear orphan status")
    end
end

--- Show detailed schema/migration info for the currently held cart
function MigrationCommands.showSchema()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    require "SaucedCarts/Migration"

    local info = SaucedCarts.Migration.getSchemaInfo(cart)

    print("=== Cart Schema Info ===")
    print("  Full Type: " .. tostring(info.fullType))
    print("  Schema Version: " .. tostring(info.schemaVersion))

    if info.previousVersion then
        print("  Previous Version: " .. tostring(info.previousVersion))
    end
    if info.migratedAt then
        print("  Migrated At: " .. os.date("%Y-%m-%d %H:%M:%S", info.migratedAt))
    end

    print("")
    print("  Is Orphan: " .. tostring(info.isOrphan))
    if info.isOrphan then
        print("  Orphaned Type: " .. tostring(info.orphanedType))
        if info.orphanedAt then
            print("  Orphaned At: " .. os.date("%Y-%m-%d %H:%M:%S", info.orphanedAt))
        end
    end

    if info.originalType then
        print("")
        print("  Original Type (aliased): " .. tostring(info.originalType))
        print("  Aliased To: " .. tostring(info.aliasedTo))
    end

    if info.restoredAt then
        print("")
        print("  Restored At: " .. os.date("%Y-%m-%d %H:%M:%S", info.restoredAt))
    end

    print("")
    print("  Multipliers Applied: " .. tostring(info.multipliersApplied))
    print("  Fill State: " .. tostring(info.fillState or "not set"))

    print("========================")
end

--- Find and list all orphan carts in player's inventory
function MigrationCommands.findOrphans()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    require "SaucedCarts/Migration"

    local orphans = SaucedCarts.Migration.findOrphans(player)

    print("=== Orphan Carts in Inventory ===")

    if #orphans == 0 then
        print("  No orphan carts found")
    else
        for i, cart in ipairs(orphans) do
            local modData = cart:getModData()
            local container = cart:getItemContainer()
            local itemCount = container and container:getItems():size() or 0

            print("  " .. i .. ". " .. tostring(modData.SaucedCarts_orphanedType or cart:getFullType()))
            print("     Items inside: " .. itemCount)
            print("     ID: " .. cart:getID())
        end
    end

    print("=================================")
end

--- Manually recover items from held orphan cart
--- Alternative to using context menu
function MigrationCommands.recoverOrphan()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    require "SaucedCarts/Migration"

    if not SaucedCarts.Migration.isOrphan(cart) then
        print("[SaucedCarts] ERROR: Held cart is not an orphan")
        print("[SaucedCarts] Use SaucedCartsDebug.makeOrphan() first to test recovery")
        return
    end

    -- Unequip first (with MP sync)
    player:setPrimaryHandItem(nil)
    player:setSecondaryHandItem(nil)
    sendEquip(player)

    local success, result = SaucedCarts.Migration.recoverOrphanCart(cart, player)

    if success then
        print("[SaucedCarts] Recovered " .. result .. " items from orphan cart")

        -- Refresh UI
        local pdata = getPlayerData(player:getPlayerNum())
        if pdata then
            pdata.playerInventory:refreshBackpacks()
            pdata.lootInventory:refreshBackpacks()
        end
    else
        print("[SaucedCarts] Recovery failed: " .. tostring(result))
    end
end

--- Simulate receiving an orphan notification (for UI testing)
function MigrationCommands.testOrphanNotification()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    -- Create a fake orphan list (just use held cart if any)
    local cart = SaucedCarts.getHeldCart(player)
    local fakeOrphans = cart and {cart} or {}

    require "SaucedCarts/OrphanRecovery"

    if #fakeOrphans > 0 then
        SaucedCarts.OrphanRecovery.notifyOrphans(player, fakeOrphans)
        print("[SaucedCarts] Sent orphan notification for held cart")
    else
        -- Send notification with fake count
        local msg = "SaucedCarts: 3 carts have missing types. Right-click to recover items."
        if HaloTextHelper and HaloTextHelper.addTextWithArrow then
            HaloTextHelper.addTextWithArrow(player, msg, true, HaloTextHelper.getColorWarning())
        end
        print("[SaucedCarts] Sent test orphan notification (no actual orphans)")
    end
end

--- Run comprehensive migration system tests
function MigrationCommands.testMigrationSystem()
    print("=== Migration System Tests ===")

    local player, err = Utils.getPlayer()
    if not player then
        print("  ERROR: No player found")
        return
    end

    require "SaucedCarts/Migration"

    -- Test 1: Schema version constants
    print("\nTest 1: Schema version")
    print("  SCHEMA_VERSION = " .. tostring(SaucedCarts.SCHEMA_VERSION))
    print("  TYPE_ALIASES count = " .. tostring(#(SaucedCarts.TYPE_ALIASES or {})))
    print("  Result: " .. (SaucedCarts.SCHEMA_VERSION >= 1 and "PASS" or "FAIL"))

    -- Test 2: looksLikeCart function
    print("\nTest 2: looksLikeCart detection")
    local cart = SaucedCarts.getHeldCart(player)
    if cart then
        local looks = SaucedCarts.Migration.looksLikeCart(cart)
        print("  Held cart looks like cart: " .. tostring(looks))
        print("  Result: " .. (looks and "PASS" or "FAIL"))
    else
        print("  Skipped (not holding a cart)")
    end

    -- Test 3: Migration function
    print("\nTest 3: migrateCart function")
    if cart then
        local success, issues = SaucedCarts.Migration.migrateCart(cart)
        print("  Success: " .. tostring(success))
        print("  Issues: " .. #issues)
        print("  Result: " .. (success and "PASS" or "FAIL"))
    else
        print("  Skipped (not holding a cart)")
    end

    -- Test 4: isOrphan detection
    print("\nTest 4: isOrphan detection")
    if cart then
        local isOrphan = SaucedCarts.Migration.isOrphan(cart)
        print("  Is orphan: " .. tostring(isOrphan))
        print("  Result: PASS (function works)")
    else
        print("  Skipped (not holding a cart)")
    end

    -- Test 5: getSchemaInfo function
    print("\nTest 5: getSchemaInfo function")
    if cart then
        local info = SaucedCarts.Migration.getSchemaInfo(cart)
        print("  Schema version: " .. tostring(info.schemaVersion))
        print("  Full type: " .. tostring(info.fullType))
        print("  Result: " .. (info.schemaVersion and "PASS" or "FAIL"))
    else
        print("  Skipped (not holding a cart)")
    end

    -- Test 6: findOrphans function
    print("\nTest 6: findOrphans function")
    local orphans = SaucedCarts.Migration.findOrphans(player)
    print("  Orphans found: " .. #orphans)
    print("  Result: PASS (function works)")

    print("\n=== Tests Complete ===")
end

return MigrationCommands
