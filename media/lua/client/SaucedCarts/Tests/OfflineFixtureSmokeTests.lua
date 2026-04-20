--[[
    SaucedCarts/Tests/OfflineFixtureSmokeTests.lua
    ==============================================

    Smoke tests that prove the PZTestKit.Fixtures surface behaves faithfully.

    These are not testing SaucedCarts code — they're testing the test
    infrastructure. Every other offline suite depends on these fixtures
    behaving the way the real PZ Java classes do, so if one of these fails,
    ALL downstream tests are suspect and must be re-evaluated.

    What we check:
      - Fidelity to documented Java behaviour (dupe-id guard on AddItem,
        back-ref maintenance, side-effect counters).
      - The AddWorldInventoryItem 4-vs-5-arg surface that caught the
        v2.1.4 ghost-item regression is faithfully reproduced.
      - Network + event spies record the calls tests will assert on.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

local tests = {}

-- ============================================================================
-- item()
-- ============================================================================

tests["item_has_core_accessors"] = function()
    local it = F.item({ id = 42, fullType = "Base.Screwdriver", weight = 0.3 })
    if not Assert.equal(it:getID(), 42, "id round-trips") then return false end
    if not Assert.equal(it:getFullType(), "Base.Screwdriver", "fullType") then return false end
    if not Assert.equal(it:getType(), "Screwdriver", "short type parsed from fullType") then return false end
    return Assert.equal(it:getActualWeight(), 0.3, "weight")
end

tests["item_setWorldItem_is_counted"] = function()
    local it = F.item()
    it:setWorldItem("placeholder1")
    it:setWorldItem(nil)
    return Assert.equal(it._private.setWorldItemCount, 2,
        "setWorldItem increments the counter tests assert against")
end

-- ============================================================================
-- container() — dupe-id guard, back-ref, recursive getItemById
-- ============================================================================

tests["container_AddItem_sets_back_ref"] = function()
    local c = F.container()
    local it = F.item({ id = 100 })
    c:AddItem(it)
    return Assert.equal(it:getContainer(), c,
        "item.container back-ref set on AddItem (matches ItemContainer.java:470)")
end

tests["container_AddItem_dupe_id_returns_existing_no_insert"] = function()
    -- Matches ItemContainer.java:453-455: when containsID(item.id) is true,
    -- the method logs and returns the existing item without adding a dupe.
    local c = F.container()
    local it = F.item({ id = 777 })
    c:AddItem(it)
    local again = c:AddItem(it)   -- same object; same id
    if not Assert.equal(again, it, "returns the already-present item") then return false end
    return Assert.equal(c:getItems():size(), 1,
        "list size stays 1 — dupe guard prevents silent duplication")
end

tests["container_AddItem_removes_from_prior_container"] = function()
    -- Matches ItemContainer.java:466-468: AddItem pulls the item from its
    -- previous container's list before setting the new back-ref.
    local src = F.container()
    local dst = F.container()
    local it  = F.item({ id = 200 })
    src:AddItem(it)
    dst:AddItem(it)
    if not Assert.isFalse(src:contains(it), "item left source container") then return false end
    if not Assert.isTrue(dst:contains(it), "item landed in destination") then return false end
    return Assert.equal(it:getContainer(), dst, "back-ref points at destination")
end

tests["container_Remove_clears_back_ref"] = function()
    local c = F.container()
    local it = F.item({ id = 300 })
    c:AddItem(it)
    c:Remove(it)
    if not Assert.isFalse(c:contains(it), "item left container") then return false end
    return Assert.isNil(it:getContainer(), "back-ref nulled on Remove")
end

tests["container_getItemById_recurses_into_nested_containers"] = function()
    -- Matches ItemContainer.java:3369-3385: getItemById recurses into
    -- InventoryContainer items' inner containers. This is load-bearing for
    -- the inv:getItemById(cartId) path in findCartNearPlayer.
    local outer = F.container()
    local innerCart = F.item({ id = 900, fullType = "SaucedCarts.ShoppingCart" })
    innerCart._type = "InventoryContainer"
    innerCart._innerContainer = F.container({ containingItem = innerCart })
    innerCart.getItemContainer = function(self) return self._innerContainer end
    outer:AddItem(innerCart)
    local deepItem = F.item({ id = 901 })
    innerCart._innerContainer:AddItem(deepItem)

    if not Assert.equal(outer:getItemById(900), innerCart, "finds top-level") then return false end
    return Assert.equal(outer:getItemById(901), deepItem, "recurses into inner container")
end

-- ============================================================================
-- square() — the 4-arg vs 5-arg AddWorldInventoryItem surface
-- ============================================================================

tests["square_AddWorldInventoryItem_4arg_broadcasts_internally"] = function()
    -- The real regression-catch. The 4-arg form defaults transmit=true and
    -- fires transmitCompleteItemToClients internally. Our mock reproduces
    -- that so a mod calling the 4-arg form AND manually transmitting is
    -- observably double-broadcasting.
    local sq = F.square(10, 10, 0)
    local it = F.item({ id = 500 })
    sq:AddWorldInventoryItem(it, 0.5, 0.5, 0.0)   -- 4-arg: transmit defaults true

    if not Assert.equal(#sq._private.addWorldInvCalls, 1, "one call recorded") then return false end
    local call = sq._private.addWorldInvCalls[1]
    if not Assert.equal(call.argCount, 4, "argCount detects 4-arg overload") then return false end
    return Assert.equal(it:getWorldItem()._private.transmitCompleteCount, 1,
        "4-arg form fired transmitCompleteItemToClients internally (matches Java default)")
end

tests["square_AddWorldInventoryItem_5arg_false_skips_internal_broadcast"] = function()
    local sq = F.square(10, 10, 0)
    local it = F.item({ id = 501 })
    sq:AddWorldInventoryItem(it, 0.5, 0.5, 0.0, false)

    if not Assert.equal(sq._private.addWorldInvCalls[1].argCount, 5, "5-arg form detected") then return false end
    return Assert.equal(it:getWorldItem()._private.transmitCompleteCount, 0,
        "transmit=false skips the internal broadcast — caller can fire it exactly once themselves")
end

tests["square_transmitRemoveItemFromSquare_actually_removes"] = function()
    -- Matches IsoGridSquare.java:6268+ (server-side): the packet handler
    -- calls o.removeFromWorld()/removeFromSquare() so the object leaves the
    -- square.objects list. Our mock reproduces that so re-lookups don't
    -- find the stale entry.
    local sq = F.square(0, 0, 0)
    local it = F.item({ id = 502 })
    sq:AddWorldInventoryItem(it, 0.5, 0.5, 0.0, false)
    local wi = it:getWorldItem()
    sq:transmitRemoveItemFromSquare(wi)

    if not Assert.equal(sq._private.transmitRemoveCount, 1, "remove counted once") then return false end
    return Assert.isFalse(sq:getObjects():contains(wi),
        "worldItem removed from objects list — matches server-side side effect")
end

-- ============================================================================
-- worldItem() — lifecycle counters
-- ============================================================================

tests["worldItem_lifecycle_counters_independent"] = function()
    local sq = F.square(0, 0, 0)
    local it = F.item({ id = 600 })
    sq:AddWorldInventoryItem(it, 0.5, 0.5, 0.0, false)
    local wi = it:getWorldItem()

    wi:removeFromWorld()
    wi:removeFromSquare()
    wi:setSquare(nil)

    if not Assert.equal(wi._private.removeFromWorldCount, 1, "removeFromWorld once") then return false end
    if not Assert.equal(wi._private.removeFromSquareCount, 1, "removeFromSquare once") then return false end
    return Assert.equal(wi._private.setSquareNilCount, 1, "setSquare(nil) once")
end

-- ============================================================================
-- player() — hand-slot state + counters
-- ============================================================================

tests["player_setPrimaryHandItem_updates_state_and_counts"] = function()
    local p  = F.player()
    local it = F.item({ id = 700 })
    p:setPrimaryHandItem(it)
    if not Assert.equal(p:getPrimaryHandItem(), it, "hand slot set") then return false end
    if not Assert.isTrue(p:isEquipped(it), "isEquipped sees the hand slot") then return false end
    return Assert.equal(p._private.setPrimaryCount, 1, "setter invocation counted")
end

tests["player_removeFromHands_clears_matching_slots"] = function()
    local p = F.player()
    local it = F.item({ id = 701 })
    p:setPrimaryHandItem(it)
    p:setSecondaryHandItem(it)  -- two-handed
    p:removeFromHands(it)
    if not Assert.isNil(p:getPrimaryHandItem(), "primary cleared") then return false end
    return Assert.isNil(p:getSecondaryHandItem(), "secondary cleared")
end

-- ============================================================================
-- world() — cell integration + teardown hygiene
-- ============================================================================

tests["world_install_stubs_getCell"] = function()
    local savedGetCell = _G.getCell
    local w = F.world()
    local sq1 = w:square(5, 5, 0)
    local sq2 = getCell():getGridSquare(5, 5, 0)
    w:teardown()
    if not Assert.equal(sq1, sq2, "getCell() returns the world's square registry") then return false end
    return Assert.equal(_G.getCell, savedGetCell, "teardown restored getCell global")
end

tests["world_network_spy_captures_send_calls"] = function()
    local w = F.world()
    sendClientCommand("p", "module", "cmd", { foo = 1 })
    sendServerCommand("module", "cmd", { bar = 2 })
    local clientCount = w.network:count("sendClientCommand")
    local serverCount = w.network:count("sendServerCommand")
    w:teardown()
    if not Assert.equal(clientCount, 1, "sendClientCommand captured once") then return false end
    return Assert.equal(serverCount, 1, "sendServerCommand captured once")
end

-- ============================================================================
-- withSandbox()
-- ============================================================================

tests["withSandbox_restores_prior_values"] = function()
    SandboxVars = SandboxVars or {}
    SandboxVars.SaucedCarts = SandboxVars.SaucedCarts or {}
    SandboxVars.SaucedCarts.CapacityMultiplier = 100   -- pre-existing
    F.withSandbox("SaucedCarts", { CapacityMultiplier = 200 }, function()
        Assert.equal(SandboxVars.SaucedCarts.CapacityMultiplier, 200, "override active inside fn")
    end)
    return Assert.equal(SandboxVars.SaucedCarts.CapacityMultiplier, 100,
        "prior value restored after fn")
end

tests["withSandbox_deletes_keys_that_didnt_exist_before"] = function()
    SandboxVars = SandboxVars or {}
    SandboxVars.SaucedCarts = SandboxVars.SaucedCarts or {}
    SandboxVars.SaucedCarts.BrandNewKey = nil
    F.withSandbox("SaucedCarts", { BrandNewKey = 42 }, function()
        Assert.equal(SandboxVars.SaucedCarts.BrandNewKey, 42, "set inside fn")
    end)
    return Assert.isNil(SandboxVars.SaucedCarts.BrandNewKey,
        "key cleared on exit since it didn't exist before")
end

return tests
