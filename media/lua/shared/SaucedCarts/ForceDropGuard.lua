-- ============================================================================
-- SaucedCarts/ForceDropGuard.lua
-- ============================================================================
-- PURPOSE: Prevent cart duplication by guarding vanilla forceDropHeavyItems().
--
--          Vanilla's forceDropHeavyItems (shared/TimedActions/
--          ISEquipWeaponAction.lua) has no safety check before adding the
--          hand-held item to the world. If the hand still references a cart
--          that has ALREADY been placed in the world (or removed from the
--          player's inventory) by a prior drop path, vanilla happily calls
--          AddWorldInventoryItem again, creating a second
--          IsoWorldInventoryObject that points at the same InventoryItem.
--          Observer clients receive the transmit and see two carts on the
--          ground — a duplicate containing all the original contents.
--
--          ISEnterVehicle:start() is the caller that produced the reported
--          bug. Same vanilla bug affects ISEquipWeaponAction,
--          ISEquipHeavyItem, ISGrabCorpseAction, and ISTakeGenerator — the
--          fix lives here instead of in any one caller.
--
--          Test coverage: pz-test-kit offline reproduction at
--          media/lua/client/SaucedCarts/Tests/OfflineForceDropDupeTests.lua.
--
-- CONTEXT: SHARED (client + server). forceDropHeavyItems is called on
--          client (SP) and server (MP via ClientCommands.onDropHeavyItem);
--          the guard must run in both.
--
-- DESIGN:  Wraps the global forceDropHeavyItems(). The wrapper body is
--          exported as a pure function (makeGuardedForceDrop) so the
--          offline test harness can exercise the guard without installing
--          it globally.
-- ============================================================================
--
-- LOAD ORDER: Required from Core.lua at the end of its load. Do NOT add
-- `require "SaucedCarts/Core"` here — that would trigger a recursive
-- require warning because Core hasn't finished loading when we're loaded.
-- The SaucedCarts namespace, SaucedCarts.isCart, and SaucedCarts.debug
-- are already defined by the time this file runs.
-- ============================================================================

local ForceDropGuard = {}

--- Build a guarded forceDropHeavyItems wrapper.
---
--- The returned function defers to `originalFn` after clearing any stale
--- cart hand references that would otherwise cause vanilla to call
--- AddWorldInventoryItem on an item that's already in the world.
---
--- @param originalFn function The unguarded forceDropHeavyItems to wrap.
--- @param isCartFn function(item) → boolean. Injected so tests can supply
---                 a pure-Lua check instead of SaucedCarts.isCart (which
---                 requires a real Java userdata item).
--- @return function Guarded forceDropHeavyItems(character).
function ForceDropGuard.makeGuardedForceDrop(originalFn, isCartFn)
    return function(character)
        if not character or not character:getCurrentSquare() then
            return originalFn(character)
        end

        pcall(function()
            local primary = character:getPrimaryHandItem()
            if primary and isCartFn(primary) then
                -- Guard 1: cart already on ground. Vanilla would call
                -- AddWorldInventoryItem again → dupe.
                if primary.getWorldItem and primary:getWorldItem() then
                    character:removeFromHands(primary)
                    return
                end
                -- Guard 2: cart already removed from inventory. Vanilla
                -- would still call AddWorldInventoryItem → dupe.
                local inv = character:getInventory()
                if inv and inv.contains and not inv:contains(primary) then
                    character:removeFromHands(primary)
                    return
                end
            end

            local secondary = character:getSecondaryHandItem()
            if secondary and isCartFn(secondary) then
                if secondary.getWorldItem and secondary:getWorldItem() then
                    character:setSecondaryHandItem(nil)
                    return
                end
                local inv = character:getInventory()
                if inv and inv.contains and not inv:contains(secondary) then
                    character:setSecondaryHandItem(nil)
                    return
                end
            end
        end)

        return originalFn(character)
    end
end

--- Install the guard on the global forceDropHeavyItems. Idempotent.
function ForceDropGuard.install()
    if SaucedCarts._forceDropGuardInstalled then return end
    if not forceDropHeavyItems then
        SaucedCarts.debug("ForceDropGuard: forceDropHeavyItems not defined yet, skipping init")
        return
    end
    SaucedCarts._forceDropGuardInstalled = true

    forceDropHeavyItems = ForceDropGuard.makeGuardedForceDrop(
        forceDropHeavyItems,
        SaucedCarts.isCart
    )

    SaucedCarts.debug("ForceDropGuard: wrapped forceDropHeavyItems()")
end

-- Install at game start, after all shared files (including
-- ISEquipWeaponAction, which defines forceDropHeavyItems) have loaded.
Events.OnGameStart.Add(ForceDropGuard.install)

SaucedCarts.ForceDropGuard = ForceDropGuard
return ForceDropGuard
