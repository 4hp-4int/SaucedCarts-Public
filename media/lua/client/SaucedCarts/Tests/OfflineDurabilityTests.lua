--[[
    SaucedCarts/Tests/OfflineDurabilityTests.lua
    =============================================

    Coverage for Durability — distance-based condition decay + break handling.

    Scope:
      * applyAccumulatedDamage: distance-to-damage math, partial-tile
        remainder carryover, zero-condition clamp, nil safety.
      * dropContentsAndDestroy: cart-contents migration to world,
        salvage drop, broadcast counts (dupe vector V8).
      * getTilesPerDamage: constant getter.

    Duplication safety (V8): break-fires-drop-contents-once.
      If a regression ever calls dropContentsAndDestroy twice for the
      same cart (e.g., both `applyAccumulatedDamage` reaching zero AND
      the user's manual drop queue firing), items would duplicate on
      the ground. Tests lock single-call semantics at the mock layer.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"
require "SaucedCarts/Durability"

local Durability = SaucedCarts.Durability

-- Register a cart type so getCartData finds it (needed indirectly if any
-- codepath reads it — Durability itself doesn't but safety first).
local TEST_CART_TYPE = "SaucedCarts.TestDurabilityCart"
if not SaucedCarts.isRegistered(TEST_CART_TYPE) then
    SaucedCarts.registerCart(TEST_CART_TYPE, {
        name         = "TestDurabilityCart",
        capacity     = 50,
        conditionMax = 100,
    })
end

-- instanceItem() returns nil for non-registered types by default. Durability
-- drops salvage (Base.ScrapMetal, Base.Wire, Base.MetalPipe) via instanceItem
-- — we stub it to return Fixtures.item so the world-add broadcast path fires
-- and tests can count salvage drops.
--
-- ZombRandFloat is not in the pz-test-kit default stubs. Durability's
-- dropSalvage calls ZombRandFloat(0.3, 0.7) for item placement offsets.
-- Stub it to return the midpoint so the test is deterministic.
local origInstanceItem = instanceItem
local origZombRandFloat = ZombRandFloat
local salvageStub
local function installSalvageStub()
    salvageStub = {
        ["Base.ScrapMetal"] = true,
        ["Base.Wire"]       = true,
        ["Base.MetalPipe"]  = true,
    }
    instanceItem = function(fullType)
        if salvageStub and salvageStub[fullType] then
            return F.item({ fullType = fullType, weight = 0.5 })
        end
        return origInstanceItem and origInstanceItem(fullType) or nil
    end
    ZombRandFloat = function(a, b) return (a + b) / 2 end
end
local function uninstallSalvageStub()
    instanceItem = origInstanceItem
    ZombRandFloat = origZombRandFloat
    salvageStub = nil
end

--- Build a mock cart with a specific initial condition + distancePushed.
--- Mirrors the ModData shape the production pickup flow writes.
local function makeCart(opts)
    opts = opts or {}
    local cart = F.item({
        id           = opts.id,
        fullType     = opts.fullType or TEST_CART_TYPE,
        condition    = opts.condition or 100,
        conditionMax = opts.conditionMax or 100,
    })
    cart._type = "InventoryContainer"
    local md = cart:getModData()
    md.SaucedCarts_distancePushed = opts.distancePushed or 0
    cart._innerContainer = F.container({
        containingItem = cart,
        typeName       = "ShoppingCart",
        capacity       = opts.capacity or 50,
    })
    cart.getItemContainer = function(self) return self._innerContainer end
    return cart
end

-- Recognize our Lua-table mock as a cart (additive — real userdata still
-- routes through the original safeIsCart implementation).
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item.getFullType and (item:getFullType() or ""):find("^SaucedCarts%.") then
        return true
    end
    return origSafeIsCart(item)
end

local tests = {}

-- ============================================================================
-- getTilesPerDamage — stable API
-- ============================================================================

tests["getTilesPerDamage_returns_a_positive_number"] = function()
    local n = Durability.getTilesPerDamage()
    if not Assert.equal(type(n), "number", "returns a number") then return false end
    return Assert.greater(n, 0, "value is positive (0 would div-by-zero in apply)")
end

-- ============================================================================
-- applyAccumulatedDamage — pure function on ModData
-- ============================================================================

tests["apply_nil_cart_returns_zero"] = function()
    return Assert.equal(Durability.applyAccumulatedDamage(nil), 0,
        "nil cart is safe — returns 0 without crashing")
end

tests["apply_with_zero_distance_noop"] = function()
    local cart = makeCart({ condition = 100, distancePushed = 0 })
    local result = Durability.applyAccumulatedDamage(cart)
    if not Assert.equal(result, 100, "returned condition unchanged") then return false end
    if not Assert.equal(cart:getCondition(), 100, "cart condition still 100") then return false end
    return Assert.equal(cart:getModData().SaucedCarts_distancePushed, 0,
        "distancePushed untouched when no damage applied")
end

tests["apply_with_subthreshold_distance_noop"] = function()
    -- Less than TILES_PER_DAMAGE accumulated → no damage fires.
    local tpd = Durability.getTilesPerDamage()
    local cart = makeCart({ condition = 100, distancePushed = tpd - 1 })
    local result = Durability.applyAccumulatedDamage(cart)
    if not Assert.equal(result, 100, "no damage yet, condition unchanged") then return false end
    return Assert.equal(cart:getModData().SaucedCarts_distancePushed, tpd - 1,
        "distancePushed preserved for next tick to resume accumulation")
end

tests["apply_exactly_threshold_deals_one_damage_zero_remainder"] = function()
    local tpd = Durability.getTilesPerDamage()
    local cart = makeCart({ condition = 100, distancePushed = tpd })
    local result = Durability.applyAccumulatedDamage(cart)
    if not Assert.equal(result, 99, "one damage applied") then return false end
    if not Assert.equal(cart:getCondition(), 99, "cart condition = 99") then return false end
    return Assert.equal(cart:getModData().SaucedCarts_distancePushed, 0,
        "no remainder — threshold exactly consumed")
end

tests["apply_multiple_of_threshold_deals_multiple_damage"] = function()
    local tpd = Durability.getTilesPerDamage()
    local cart = makeCart({ condition = 100, distancePushed = tpd * 3 })
    local result = Durability.applyAccumulatedDamage(cart)
    if not Assert.equal(result, 97, "3 damage from 3×TILES_PER_DAMAGE") then return false end
    return Assert.equal(cart:getModData().SaucedCarts_distancePushed, 0,
        "zero remainder when perfect multiple")
end

tests["apply_preserves_remainder_for_next_tick"] = function()
    -- CRITICAL: partial-tile progress carries over. Otherwise rapid
    -- stop/pickup cycles would discard small distances and carts would
    -- live forever if user never pushed a full TILES_PER_DAMAGE in one
    -- burst. This is the "partial tile progress" contract.
    local tpd = Durability.getTilesPerDamage()
    local cart = makeCart({ condition = 100, distancePushed = tpd + 37 })
    local result = Durability.applyAccumulatedDamage(cart)
    if not Assert.equal(result, 99, "one damage from the full threshold") then return false end
    return Assert.equal(cart:getModData().SaucedCarts_distancePushed, 37,
        "37-tile remainder preserved for next pickup cycle")
end

tests["apply_clamps_at_zero_condition"] = function()
    -- Massive accumulation (e.g., long push session with low condition)
    -- must not produce a negative condition — clamp at 0.
    local tpd = Durability.getTilesPerDamage()
    local cart = makeCart({ condition = 5, distancePushed = tpd * 100 })
    local result = Durability.applyAccumulatedDamage(cart)
    if not Assert.equal(result, 0, "condition clamped at 0, not negative") then return false end
    return Assert.equal(cart:getCondition(), 0, "cart condition = 0")
end

tests["apply_zero_return_signals_break_eligibility"] = function()
    -- The pickup action watches for the "just broke" transition — return
    -- value == 0 is the signal. This test locks that contract: a cart
    -- that breaks this tick returns exactly 0.
    local cart = makeCart({
        condition = 1,
        distancePushed = Durability.getTilesPerDamage(),
    })
    return Assert.equal(Durability.applyAccumulatedDamage(cart), 0,
        "1 → 0 transition returns 0 as the break signal")
end

tests["apply_uses_floor_not_round_for_damage"] = function()
    -- 149 / 110 = 1.35 → 1 damage. Floor behavior means sub-threshold
    -- distance accumulates conservatively; round-up would over-punish.
    local tpd = Durability.getTilesPerDamage()   -- 110
    local cart = makeCart({ condition = 50, distancePushed = math.floor(tpd * 1.35) })
    local result = Durability.applyAccumulatedDamage(cart)
    return Assert.equal(result, 49, "floor(1.35) = 1 damage, not 2")
end

-- ============================================================================
-- dropContentsAndDestroy — break-time contents migration
-- ============================================================================

tests["dcd_nil_cart_returns_false"] = function()
    return Assert.isFalse(Durability.dropContentsAndDestroy(nil, nil, nil),
        "nil cart safe — returns false without side effects")
end

tests["dcd_missing_square_returns_false"] = function()
    local cart = makeCart()
    local player = F.player()   -- no square set
    return Assert.isFalse(Durability.dropContentsAndDestroy(cart, player, nil),
        "no resolvable square → abort instead of crashing")
end

tests["dcd_moves_all_cart_contents_to_square"] = function()
    installSalvageStub()
    local cart = makeCart()
    local inner = cart:getItemContainer()
    local items = {
        F.item({ id = 101, fullType = "Base.Screwdriver" }),
        F.item({ id = 102, fullType = "Base.Plank" }),
        F.item({ id = 103, fullType = "Base.Nails" }),
    }
    for _, it in ipairs(items) do inner:AddItem(it) end
    local sq = F.square(0, 0, 0)
    -- M1 refactor: dropContentsAndDestroy now routes items through
    -- performCartTransfer, which requires a non-nil player. Pass one.
    local player = F.player({ square = sq })

    local ok = Durability.dropContentsAndDestroy(cart, player, sq)
    uninstallSalvageStub()

    if not Assert.isTrue(ok, "dropContentsAndDestroy returned success") then return false end
    if not Assert.equal(inner:getItems():size(), 0, "cart is empty") then return false end
    -- Cart had 3 contents + up to 4 salvage items (max 2 scrap + 1 wire + 1 pipe).
    -- Content items should be in the square's worldObjects.
    for _, it in ipairs(items) do
        if not Assert.isTrue(sq:getWorldObjects():contains(it:getWorldItem()),
            "content item " .. it:getID() .. " landed on square") then return false end
    end
    return true
end

tests["dcd_fires_exactly_one_addWorldInventoryItem_per_content"] = function()
    -- DUPLICATION VECTOR V8: if a regression loops twice or the caller
    -- also separately drops contents, each content item would produce
    -- multiple world-item adds. Lock single-add semantics.
    installSalvageStub()
    local cart = makeCart()
    local inner = cart:getItemContainer()
    for i = 1, 5 do
        inner:AddItem(F.item({ id = 200 + i, fullType = "Base.Plank" }))
    end
    local sq = F.square(0, 0, 0)
    local player = F.player({ square = sq })  -- M1 refactor: needs player

    Durability.dropContentsAndDestroy(cart, player, sq)
    uninstallSalvageStub()

    -- 5 content drops + up to 4 salvage drops = 9 world-add calls max, 5 min.
    -- Content-specific count is 5 — each unique content ID appears once.
    local contentDrops = 0
    for _, call in ipairs(sq._private.addWorldInvCalls) do
        if call.item:getID() >= 201 and call.item:getID() <= 205 then
            contentDrops = contentDrops + 1
        end
    end
    return Assert.equal(contentDrops, 5,
        "5 content items produced exactly 5 world-add calls (no dupe path)")
end

tests["dcd_world_adds_use_5arg_auto_transmit"] = function()
    -- The break-path AddWorldInventoryItem intentionally uses 5-arg with
    -- transmit=true (not the 4-arg implicit-true). This was the pattern
    -- the v2.1.4 fix landed on. Regression guard: if a future edit drops
    -- the explicit transmit flag, this test fails.
    installSalvageStub()
    local cart = makeCart()
    local inner = cart:getItemContainer()
    inner:AddItem(F.item({ id = 301, fullType = "Base.Stone" }))
    local sq = F.square(0, 0, 0)

    Durability.dropContentsAndDestroy(cart, nil, sq)
    uninstallSalvageStub()

    local allFiveArg = true
    for _, call in ipairs(sq._private.addWorldInvCalls) do
        if call.argCount ~= 5 then allFiveArg = false; break end
    end
    return Assert.isTrue(allFiveArg,
        "every AddWorldInventoryItem call used the 5-arg form (explicit transmit)")
end

tests["dcd_drops_salvage_when_instanceItem_available"] = function()
    installSalvageStub()
    local cart = makeCart()   -- no contents
    local sq = F.square(0, 0, 0)

    Durability.dropContentsAndDestroy(cart, nil, sq)
    uninstallSalvageStub()

    -- Salvage is randomized per ZombRand; mock_environment's ZombRand in
    -- the test harness is deterministic-ish. We just assert SOME salvage
    -- appeared — the exact count is RNG-dependent.
    local salvageCount = 0
    for _, call in ipairs(sq._private.addWorldInvCalls) do
        local t = call.item:getFullType()
        if t == "Base.ScrapMetal" or t == "Base.Wire" or t == "Base.MetalPipe" then
            salvageCount = salvageCount + 1
        end
    end
    return Assert.greaterEq(salvageCount, 1,
        "at least one salvage item dropped (ScrapMetal guaranteed min=1)")
end

tests["dcd_prefers_explicit_square_over_player_square"] = function()
    -- When both a player-square and an explicit override square are
    -- supplied, the override wins. This matters for ground carts: the
    -- cart's square (not the player's) is where the break-drop should go.
    installSalvageStub()
    local cart = makeCart()
    cart:getItemContainer():AddItem(F.item({ id = 401, fullType = "Base.Stone" }))
    local playerSq = F.square(10, 10, 0)
    local cartSq   = F.square(20, 20, 0)
    local player = F.player({ square = playerSq })

    Durability.dropContentsAndDestroy(cart, player, cartSq)
    uninstallSalvageStub()

    if not Assert.isFalse(playerSq:getWorldObjects():size() > 0,
        "nothing landed on player's square") then return false end
    return Assert.greater(cartSq:getWorldObjects():size(), 0,
        "everything landed on the explicit cart square")
end

tests["dcd_falls_back_to_player_square_when_no_override"] = function()
    installSalvageStub()
    local cart = makeCart()
    cart:getItemContainer():AddItem(F.item({ id = 501, fullType = "Base.Stone" }))
    local sq = F.square(5, 5, 0)
    local player = F.player({ square = sq })

    Durability.dropContentsAndDestroy(cart, player, nil)
    uninstallSalvageStub()

    return Assert.greater(sq:getWorldObjects():size(), 0,
        "player's current square used as fallback drop target")
end

tests["dcd_empty_cart_still_drops_salvage"] = function()
    -- Break-reward: even a brand-new empty cart breaking gives salvage
    -- back. No contents to migrate, but dropSalvage still runs.
    installSalvageStub()
    local cart = makeCart()   -- no contents
    local sq = F.square(0, 0, 0)

    local ok = Durability.dropContentsAndDestroy(cart, nil, sq)
    uninstallSalvageStub()

    if not Assert.isTrue(ok, "success on empty cart") then return false end
    return Assert.greater(sq:getWorldObjects():size(), 0,
        "salvage dropped even with zero contents")
end

return tests
