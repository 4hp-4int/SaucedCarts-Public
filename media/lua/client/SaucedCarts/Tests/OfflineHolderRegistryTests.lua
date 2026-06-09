--[[
    SaucedCarts/Tests/OfflineHolderRegistryTests.lua
    ================================================

    Locks the holder registry (CartState/HolderRegistry.lua): key-level
    transitions, idempotence + count maintenance, the OnEquipPrimary
    handler's register/unregister decision, and reportObserved's divergence
    accounting (one missed event = ONE divergence, resynced — not one per
    frame).

    Phase-2 contract: the registry is AUTHORITATIVE for CartStateHandler's
    per-frame early exit. reportObserved is the audit path (holder hand-check
    + slow reconciler): hands are physical truth, so any disagreement resyncs
    the registry toward the hands and ticks the divergence meter.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"

local ok, HolderRegistry = pcall(require, "SaucedCarts/CartState/HolderRegistry")
if not ok or type(HolderRegistry) ~= "table" then return {} end

--- Mock local IsoPlayer (keyed by onlineID, like MP). _type satisfies the
--- kit's instanceof mock — handleEquipPrimary gates on instanceof IsoPlayer.
local function mkPlayer(onlineId)
    return {
        _type = "IsoPlayer",
        getOnlineID = function() return onlineId end,
        getPlayerNum = function() return 0 end,
        isLocalPlayer = function() return true end,
    }
end

local isCartYes = function() return true end
local isCartNo  = function() return false end

local tests = {}

tests["register_unregister_idempotent_with_count"] = function()
    HolderRegistry.reset()
    local r1 = HolderRegistry.registerKey(7)
    local r2 = HolderRegistry.registerKey(7)          -- duplicate
    local countAfterReg = HolderRegistry.count()
    local u1 = HolderRegistry.unregisterKey(7)
    local u2 = HolderRegistry.unregisterKey(7)        -- duplicate
    return Assert.isTrue(r1, "first register changes state")
        and Assert.isFalse(r2, "duplicate register is a no-op")
        and Assert.equal(countAfterReg, 1, "count tracks single holder")
        and Assert.isTrue(u1, "first unregister changes state")
        and Assert.isFalse(u2, "duplicate unregister is a no-op")
        and Assert.equal(HolderRegistry.count(), 0, "count back to zero")
end

tests["nil_key_is_safe_noop"] = function()
    HolderRegistry.reset()
    local r = HolderRegistry.registerKey(nil)
    local u = HolderRegistry.unregisterKey(nil)
    return Assert.isFalse(r, "register(nil) no-op")
        and Assert.isFalse(u, "unregister(nil) no-op")
        and Assert.isFalse(HolderRegistry.isHolderKey(nil), "isHolder(nil) false")
        and Assert.equal(HolderRegistry.count(), 0, "count untouched")
end

tests["equip_primary_cart_registers_noncart_unregisters"] = function()
    HolderRegistry.reset()
    local p = mkPlayer(11)
    HolderRegistry.handleEquipPrimary(p, {}, isCartYes)   -- cart equipped
    local registered = HolderRegistry.isHolder(p)
    HolderRegistry.handleEquipPrimary(p, {}, isCartNo)    -- swapped to non-cart
    local afterSwap = HolderRegistry.isHolder(p)
    return Assert.isTrue(registered, "cart equip registers")
        and Assert.isFalse(afterSwap, "non-cart equip unregisters")
end

tests["equip_primary_nil_item_unregisters"] = function()
    -- setPrimaryHandItem(nil) fires OnEquipPrimary with nil item (unequip).
    HolderRegistry.reset()
    local p = mkPlayer(12)
    HolderRegistry.handleEquipPrimary(p, {}, isCartYes)
    HolderRegistry.handleEquipPrimary(p, nil, isCartNo)
    return Assert.isFalse(HolderRegistry.isHolder(p), "nil-item equip unregisters")
end

tests["non_isoplayer_subject_ignored"] = function()
    -- OnEquipPrimary fires for any IsoGameCharacter subclass (NPC mods,
    -- dummies). Monorepo doctrine: gate every handler on subject type.
    HolderRegistry.reset()
    local npc = mkPlayer(14)
    npc._type = "IsoGameCharacter"
    HolderRegistry.handleEquipPrimary(npc, {}, isCartYes)
    return Assert.equal(HolderRegistry.count(), 0, "non-IsoPlayer subjects never register")
end

tests["remote_player_ignored"] = function()
    HolderRegistry.reset()
    local remote = mkPlayer(13)
    remote.isLocalPlayer = function() return false end
    HolderRegistry.handleEquipPrimary(remote, {}, isCartYes)
    return Assert.equal(HolderRegistry.count(), 0, "remote players never register")
end

tests["shadow_agreement_counts_nothing"] = function()
    HolderRegistry.reset()
    HolderRegistry.registerKey(21)
    local d1 = HolderRegistry.reportObserved(21, true)    -- agree: holder
    local d2 = HolderRegistry.reportObserved(99, false)   -- agree: non-holder
    local stats = HolderRegistry.getStats()
    return Assert.isFalse(d1, "agreement (holder) not a divergence")
        and Assert.isFalse(d2, "agreement (non-holder) not a divergence")
        and Assert.equal(stats.divergences, 0, "zero divergences")
end

tests["shadow_missed_equip_counts_once_then_resyncs"] = function()
    -- Registry missed an equip event: poll sees a cart, registry doesn't.
    -- Must count ONE divergence and resync — repeated frames stay quiet.
    HolderRegistry.reset()
    local d1 = HolderRegistry.reportObserved(31, true)    -- diverged
    local d2 = HolderRegistry.reportObserved(31, true)    -- next frame: resynced
    local stats = HolderRegistry.getStats()
    return Assert.isTrue(d1, "missed equip detected")
        and Assert.isFalse(d2, "resync stops repeat counting")
        and Assert.equal(stats.divergences, 1, "one missed event = one divergence")
        and Assert.isTrue(HolderRegistry.isHolderKey(31), "resynced toward the poll")
end

tests["shadow_missed_unequip_counts_once_then_resyncs"] = function()
    HolderRegistry.reset()
    HolderRegistry.registerKey(41)
    local d1 = HolderRegistry.reportObserved(41, false)   -- registry stale
    local d2 = HolderRegistry.reportObserved(41, false)
    local stats = HolderRegistry.getStats()
    return Assert.isTrue(d1, "missed unequip detected")
        and Assert.isFalse(d2, "resync stops repeat counting")
        and Assert.equal(stats.divergences, 1, "one divergence")
        and Assert.isFalse(HolderRegistry.isHolderKey(41), "resynced to non-holder")
        and Assert.equal(HolderRegistry.count(), 0, "count resynced too")
end

tests["reset_clears_everything"] = function()
    HolderRegistry.reset()
    HolderRegistry.registerKey(51)
    HolderRegistry.reportObserved(52, true)               -- force a divergence
    HolderRegistry.reset()
    local stats = HolderRegistry.getStats()
    return Assert.equal(stats.holders, 0, "holders cleared")
        and Assert.equal(stats.divergences, 0, "divergences cleared")
        and Assert.isFalse(HolderRegistry.isHolderKey(51), "holder gone after reset")
end

return tests
