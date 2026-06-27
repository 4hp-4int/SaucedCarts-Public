-- ============================================================================
-- SaucedCarts/CartLoot.lua
-- ============================================================================
-- PURPOSE: Context-aware loot for world-spawned carts. Most carts spawn empty;
--          a fraction spawn loaded with loot appropriate to where they spawned
--          (grocery -> food, warehouse -> materials, toolstore -> tools, an
--          outdoor lot/driveway -> groceries, and ULTRA-rarely a survivor cache
--          of weapons + ammo).
--
-- CONTEXT: SHARED. The DECISION + mapping helpers are pure (no world deps) so
--          they're offline-testable; only fillCart() touches runtime globals
--          (instanceItem + ProceduralDistributions) and is called server-side
--          from WorldSpawning.processSpawnQueue.
--
-- GROUNDING: loot is sourced from vanilla `ProceduralDistributions.list` entries
--          (the same weighted item tables the base game / other mods fill
--          containers from), so addon items registered into those lists appear
--          in carts for free. We control the COUNT ourselves (vanilla
--          fillContainer would overfill a high-capacity cart).
-- ============================================================================

require "SaucedCarts/Core"

SaucedCarts.CartLoot = SaucedCarts.CartLoot or {}
local CartLoot = SaucedCarts.CartLoot

-- ============================================================================
-- TUNING
-- ============================================================================

-- LoadedCartSpawns sandbox enum: 1=Off (default — BETA, opt-in), 2=Rare,
-- 3=Some, 4=Common. Value = % chance a spawned cart is loaded (vs empty).
local LOAD_CHANCE = { [1] = 0, [2] = 15, [3] = 40, [4] = 70 }
-- Nominal density assumed only when decideCartLoad gets a nil density (the
-- pure-function fallback exercised by tests). Real spawns read the sandbox var,
-- which now defaults to Off (1) — the loaded-spawns feature ships off by default.
local LOAD_DEFAULT = 3

-- Of the carts that DO load: % that are a "light" load (rest are "loaded").
local LIGHT_SPLIT = 75
-- Of the carts that DO load: per-1000 chance of the ultra-rare survivor cache
-- (overrides tier). 15/1000 = 1.5%.
local SURVIVOR_PERMILLE = 15

-- Per-tier VALUABLE-loot weight budget (kg) — fill stops once exceeded, so the
-- "good stuff" is capped regardless of the cart's capacity (never OP).
local WEIGHT_BUDGET = { light = 8, loaded = 25, survivor = 15 }

-- The cart's visual fill model (empty/partial/full) is CAPACITY-% based
-- (CartVisuals.calculateFillState: contentsWeight / capacity vs the Config
-- thresholds). The small valuable-loot budget above rarely crosses the partial
-- threshold on its own — especially with a big CapacityMultiplier — so a loaded
-- cart would still look empty. To make it LOOK loaded without adding more
-- valuable loot, we pad with cheap junk up to the tier's target fill ratio.
--
-- Junk is capped so a huge-capacity cart isn't stuffed with 100kg of planks
-- (which would be heavy + weird, even if not "OP"): on such carts the cart just
-- won't reach full, which is an accepted trade-off.
local JUNK_WEIGHT_CAP = 25   -- max kg of junk added per cart
local JUNK_MAX_ITEMS  = 40   -- hard iteration guard

-- Low-value filler. instanceItem skips any ID missing in the current build, so
-- this list is forgiving. Plank is listed twice to bias toward a heavier item
-- (fewer pieces needed to fill the same space). All verified present in B42.
local JUNK_POOL = {
    "Base.Plank", "Base.Plank",
    "Base.Sheet", "Base.RippedSheets",
    "Base.EmptyJar", "Base.BrokenGlass",
    "Base.Magazine", "Base.Newspaper",
}

-- ============================================================================
-- CONTEXT -> vanilla distribution lists
-- ============================================================================
-- Each context maps to a set of `ProceduralDistributions.list` names. fillCart
-- merges their weighted items into one pool. Unknown/missing list names are
-- skipped at fill time, so this map is forgiving.

local CONTEXT_POOLS = {
    grocery   = { "GigamartCannedFood", "GigamartDryGoods", "GigamartBreakfast",
                  "GigamartCrisps", "GigamartCandy", "CrateCannedFood", "CrateCereal" },
    materials = { "CrateMetalwork", "CrateTools", "CrateRandomJunk" },
    tools     = { "ToolStoreTools", "GarageTools", "CrateTools", "ConstructionWorkerTools" },
    survivor  = { "GunStoreAmmunition", "GunStoreDisplayCase", "ArmyStorageGuns" },
    generic   = { "CrateRandomJunk", "GigamartDryGoods" },
}

-- Vanilla room name -> context key. Interior carts carry their room; anything
-- unmapped falls through to "generic". (Outdoor carts pass "grocery" directly —
-- the "unloading / escaped-from-the-store" theme — see WorldSpawning.)
local ROOM_CONTEXT = {
    -- grocery / food
    gigamart = "grocery", grocery = "grocery", grocerystorage = "grocery",
    producestorage = "grocery", conveniencestore = "grocery", cornerstore = "grocery",
    gasstore = "grocery", gas2go = "grocery", zippeestore = "grocery", candystore = "grocery",
    -- materials / storage / industrial
    warehouse = "materials", storageunit = "materials", storage = "materials",
    garagestorage = "materials", departmentstorage = "materials", loggingwarehouse = "materials",
    loggingfactory = "materials", factory = "materials", factorystorage = "materials",
    cabinetshipping = "materials", dogfoodshipping = "materials", golfshipping = "materials",
    jerkyshipping = "materials", knifeshipping = "materials", radioshipping = "materials",
    -- tools / hardware / garages
    toolstore = "tools", ww_toolstore = "tools", gardenstore = "tools", carsupply = "tools",
    carsupplysport = "tools", paintershop = "tools", barbecuestore = "tools",
    firegarage = "tools", policegarage = "tools", housewarestore = "tools",
}

--- Resolve a spawn room name to a loot context key (pure).
---@param roomName string|nil
---@return string context key
function CartLoot.contextForRoom(roomName)
    if not roomName then return "generic" end
    return ROOM_CONTEXT[roomName] or "generic"
end

--- Distribution-list names for a context key (pure).
---@param contextKey string
---@return string[]
function CartLoot.poolFor(contextKey)
    return CONTEXT_POOLS[contextKey] or CONTEXT_POOLS.generic
end

-- ============================================================================
-- DECISION (pure)
-- ============================================================================
-- rng(n) returns an int in [0, n-1] like ZombRand. Call order (so tests can
-- script it):
--   [1] load roll       rng(100)         -> empty unless < LOAD_CHANCE[density]
--   [2] survivor roll   rng(1000)        -> survivor if < SURVIVOR_PERMILLE
--   [3] light/loaded    rng(100)         -> light if < LIGHT_SPLIT
--   [4] count roll      rng(range)       -> tier-specific count

--- Decide whether/how a spawned cart is loaded. Context-independent (the tier
--- is the same regardless of location; the location only affects WHICH loot via
--- poolFor at fill time).
---@param density number sandbox enum 1..4 (1=Off)
---@param rng fun(n:number):number
---@return table { tier = "empty"|"light"|"loaded"|"survivor", count = number }
function CartLoot.decideCartLoad(density, rng)
    density = density or LOAD_DEFAULT
    local chance = LOAD_CHANCE[density] or LOAD_CHANCE[LOAD_DEFAULT]
    if chance <= 0 then return { tier = "empty", count = 0 } end
    if rng(100) >= chance then return { tier = "empty", count = 0 } end

    if rng(1000) < SURVIVOR_PERMILLE then
        return { tier = "survivor", count = 2 + rng(3) }      -- 2..4 weapons/ammo
    end
    if rng(100) < LIGHT_SPLIT then
        return { tier = "light", count = 2 + rng(4) }          -- 2..5 items
    end
    return { tier = "loaded", count = 6 + rng(7) }             -- 6..12 items
end

-- ============================================================================
-- WEIGHTED POOL (pure-ish; reads ProceduralDistributions at runtime)
-- ============================================================================

--- Build a flat weighted pool [{type=string, weight=number}, ...] by merging the
--- `.items` arrays of the named ProceduralDistributions lists. Missing lists
--- (or a missing ProceduralDistributions global, e.g. offline) are skipped.
---@param names string[]
---@return table[]
function CartLoot.buildWeightedPool(names)
    local pool = {}
    local PD = ProceduralDistributions
    if type(PD) ~= "table" or type(PD.list) ~= "table" then return pool end
    for _, name in ipairs(names) do
        local dist = PD.list[name]
        local items = dist and dist.items
        if type(items) == "table" then
            -- items is a flat array: type1, weight1, type2, weight2, ...
            local i = 1
            local n = #items
            while i + 1 <= n do
                local t = items[i]
                local w = tonumber(items[i + 1]) or 1
                if type(t) == "string" and w > 0 then
                    pool[#pool + 1] = { type = t, weight = w }
                end
                i = i + 2
            end
        end
    end
    return pool
end

--- Weighted-random pick of a type string from a pool (pure).
---@param pool table[] {type=, weight=}
---@param rng fun(n:number):number
---@return string|nil
function CartLoot.pickWeighted(pool, rng)
    if not pool or #pool == 0 then return nil end
    local total = 0
    for _, e in ipairs(pool) do total = total + (e.weight or 0) end
    if total <= 0 then return pool[1].type end
    local r, cum = rng(total), 0
    for _, e in ipairs(pool) do
        cum = cum + (e.weight or 0)
        if r < cum then return e.type end
    end
    return pool[#pool].type
end

-- ============================================================================
-- FILL (server-side execution)
-- ============================================================================

--- Fill a cart item's container with `count` weighted picks from the context's
--- pool, stopping at the tier weight budget. Returns (placedCount, placedWeight).
--- Caller (WorldSpawning) uses placedWeight to choose the visual model.
---@param cartItem InventoryItem the cart (InventoryContainer) item
---@param contextKey string loot context (e.g. "grocery"); ignored for survivor
---@param tier string "light"|"loaded"|"survivor" (empty handled by caller)
---@param count number target item count
---@param rng fun(n:number):number
---@return number placedCount
---@return number placedWeight
function CartLoot.fillCart(cartItem, contextKey, tier, count, rng)
    if tier == "empty" or not cartItem then return 0, 0 end
    local container = cartItem.getItemContainer and cartItem:getItemContainer()
    if not container or not container.AddItem then return 0, 0 end

    local poolKey = (tier == "survivor") and "survivor" or contextKey
    local pool = CartLoot.buildWeightedPool(CartLoot.poolFor(poolKey))
    if #pool == 0 then return 0, 0 end

    local budget = WEIGHT_BUDGET[tier] or 10
    local placed, weightUsed = 0, 0
    for _ = 1, (count or 0) do
        if weightUsed >= budget then break end
        local typ = CartLoot.pickWeighted(pool, rng)
        if typ then
            local li = instanceItem(typ)
            if li then
                local w = (li.getActualWeight and li:getActualWeight())
                    or (li.getWeight and li:getWeight()) or 1
                container:AddItem(li)
                weightUsed = weightUsed + w
                placed = placed + 1
            end
        end
    end
    return placed, weightUsed
end

--- Target capacity-fill ratio for a tier's visual. Light/survivor aim for the
--- PARTIAL threshold ("at least looks loaded"); loaded aims for FULL. Pure;
--- reads the shared fill thresholds from Config.
---@param tier string
---@return number ratio 0..1
function CartLoot.fillTargetFor(tier)
    local C = SaucedCarts.Config
    local partial = (C and C.FILL_PARTIAL_THRESHOLD) or 0.33
    local full    = (C and C.FILL_FULL_THRESHOLD) or 0.66
    if tier == "loaded" then return full end
    return partial
end

--- Pad a cart with cheap junk until its capacity-fill reaches `targetRatio`,
--- capped at JUNK_WEIGHT_CAP / JUNK_MAX_ITEMS. Uses the SAME weight basis as
--- CartVisuals.calculateFillState (container:getCapacityWeight() / capacity), so
--- the resulting visual is honest. Returns (junkCount, junkWeight).
---@param cartItem InventoryItem
---@param targetRatio number 0..1
---@param rng fun(n:number):number
---@return number junkCount
---@return number junkWeight
function CartLoot.padToFillState(cartItem, targetRatio, rng)
    if not cartItem or not targetRatio then return 0, 0 end
    local container = cartItem.getItemContainer and cartItem:getItemContainer()
    if not container or not container.AddItem or not container.getCapacity then
        return 0, 0
    end
    local capacity = container:getCapacity() or 0
    if capacity <= 0 then return 0, 0 end

    local target = targetRatio * capacity
    local junkCount, junkWeight, guard = 0, 0, 0
    while container:getCapacityWeight() < target
        and junkWeight < JUNK_WEIGHT_CAP
        and guard < JUNK_MAX_ITEMS do
        guard = guard + 1
        local typ = JUNK_POOL[1 + rng(#JUNK_POOL)]
        local li = typ and instanceItem(typ)
        if li then
            local w = (li.getActualWeight and li:getActualWeight())
                or (li.getWeight and li:getWeight()) or 1
            container:AddItem(li)
            junkWeight = junkWeight + w
            junkCount = junkCount + 1
        end
    end
    return junkCount, junkWeight
end

SaucedCarts.debug("CartLoot loaded")

return CartLoot
