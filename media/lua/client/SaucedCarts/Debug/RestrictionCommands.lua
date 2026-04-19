-- ============================================================================
-- SaucedCarts/Debug/RestrictionCommands.lua
-- ============================================================================
-- PURPOSE: Container restriction testing debug commands
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"

local Utils = require "SaucedCarts/Debug/Utils"

local RestrictionCommands = {}

--- Test if container restrictions are working
--- Checks if the isItemAllowed hook is blocking cart transfers
function RestrictionCommands.testContainerRestriction()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    require "SaucedCarts/ContainerRestrictions"

    if not SaucedCarts.ContainerRestrictions then
        print("[SaucedCarts] ERROR: ContainerRestrictions module not loaded")
        return
    end

    local result = SaucedCarts.ContainerRestrictions.testRestriction(player)
    print("[SaucedCarts] Container restriction test: " .. result)
end

--- Test that unequipping a cart drops it to the ground
function RestrictionCommands.testUnequipDrop()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print("[SaucedCarts] ERROR: Not holding a cart - equip a cart first")
        return
    end

    print("[SaucedCarts] Triggering unequip action...")
    print("[SaucedCarts] Cart should drop to ground (not stay in inventory)")

    -- Use the unequip action to test our hook
    ISTimedActionQueue.add(ISUnequipAction:new(player, cart, 50))
end

--- Check the current state of all restriction hooks
function RestrictionCommands.showRestrictionStatus()
    print("=== Cart Restriction Status ===")

    -- Check ContainerRestrictions (shared)
    require "SaucedCarts/ContainerRestrictions"
    if SaucedCarts.ContainerRestrictions then
        print("  ContainerRestrictions module: Loaded")
        print("    - isItemAllowed hook: " .. tostring(SaucedCarts.ContainerRestrictions.isInitialized()))
        print("    - Unequip hook: " .. tostring(SaucedCarts.ContainerRestrictions.isUnequipHookInitialized()))
    else
        print("  ContainerRestrictions module: NOT LOADED")
    end

    -- Check GrabRestrictions (client)
    if SaucedCarts.GrabRestrictions then
        print("  GrabRestrictions module: Loaded")
        print("    - Hooks initialized: " .. tostring(SaucedCarts.GrabRestrictions.isInitialized()))
    else
        print("  GrabRestrictions module: NOT LOADED")
    end

    -- Check TransferRestrictions (client)
    if SaucedCarts.TransferRestrictions then
        print("  TransferRestrictions module: Loaded")
        print("    - All hooks initialized: " .. tostring(SaucedCarts.TransferRestrictions.isInitialized()))
    else
        print("  TransferRestrictions module: NOT LOADED")
    end

    print("================================")
end

--- Test all restriction layers
function RestrictionCommands.testAllRestrictions()
    print("=== Testing All Restriction Layers ===")

    local player, err = Utils.getPlayer()
    if not player then
        print("  ERROR: " .. err)
        return
    end

    -- Test 1: Container restriction (isItemAllowed)
    print("\n[Test 1] Container Restriction (isItemAllowed)")
    require "SaucedCarts/ContainerRestrictions"
    if SaucedCarts.ContainerRestrictions then
        local result = SaucedCarts.ContainerRestrictions.testRestriction(player)
        print("  Result: " .. result)
    else
        print("  SKIPPED: Module not loaded")
    end

    -- Test 2: Check if player is holding cart for other tests
    local cart = SaucedCarts.getHeldCart(player)
    if not cart then
        print("\n[Test 2-4] SKIPPED: Not holding a cart")
        print("  Equip a cart to run additional tests")
    else
        print("\n[Test 2] Cart Detection")
        print("  isCart(): " .. tostring(SaucedCarts.isCart(cart)))
        print("  Cart type: " .. tostring(cart:getFullType()))
        print("  Result: PASS")

        print("\n[Test 3] Grab Restrictions Module")
        if SaucedCarts.GrabRestrictions then
            print("  Module loaded: Yes")
            print("  Hooks initialized: " .. tostring(SaucedCarts.GrabRestrictions.isInitialized()))
            print("  Result: " .. (SaucedCarts.GrabRestrictions.isInitialized() and "PASS" or "FAIL"))
        else
            print("  Module loaded: No")
            print("  Result: FAIL")
        end

        print("\n[Test 4] Transfer Restrictions Module")
        if SaucedCarts.TransferRestrictions then
            print("  Module loaded: Yes")
            print("  Hooks initialized: " .. tostring(SaucedCarts.TransferRestrictions.isInitialized()))
            print("  Result: " .. (SaucedCarts.TransferRestrictions.isInitialized() and "PASS" or "FAIL"))
        else
            print("  Module loaded: No")
            print("  Result: FAIL")
        end
    end

    print("\n=== Tests Complete ===")
end

return RestrictionCommands
