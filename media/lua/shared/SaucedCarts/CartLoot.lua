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
--
-- SANDBOX:  a loaded cart is a container of loot, so it answers to the same
--          sandbox knobs every other container does — see the "SANDBOX LOOT
--          SETTINGS" section below. A server running Insane loot rarity, a
--          banned-item list, or late-game loot decay would otherwise find carts
--          quietly handing out the loot the rest of the world was tuned to
--          withhold.
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
-- SANDBOX LOOT SETTINGS
-- ============================================================================
-- Three vanilla knobs, applied where vanilla applies them:
--
--   1. PER-ITEM CATEGORY RARITY — `ItemPickerJava.getLootModifier(itemType)`
--      returns the multiplier for that item's loot category (the B42
--      FoodLootNew / WeaponLootNew / ToolLootNew / … sandbox floats: 1.0 is
--      normal, Apocalypse ships 0.6-0.8, Insane bottoms out near 0.05). It
--      ALSO returns 0.0 when the item sits on the admin `LootItemRemovalList`
--      or its whole category is set to None (ItemPickerJava.java:1497-1512),
--      which is why a zero is an unconditional skip and not just a low roll:
--      vanilla's own container path returns a 0.0 spawn chance for those
--      (getActualSpawnChance:2104-2106). Calling this from Lua is vanilla's
--      own idiom — StoryTable_Initialization.lua:9 does exactly this.
--
--   2. LOOT DECAY OVER TIME — `getSandboxOptions():getCurrentLootMultiplier()`
--      (SandboxOptions.java:1283-1290, `1 - diminishedLootPercentage/100`).
--      Vanilla folds this into the per-item spawn chance; we fold it into the
--      cart's load chance instead — same net effect on a two-stage
--      decide-then-fill design, without double-dipping the same scalar.
--
--   3. RemoveStoryLoot — the survivor cache (weapons + ammo abandoned in a
--      cart) is a hand-authored narrative stash, i.e. exactly the "randomized
--      world story" loot this option exists to switch off. When it's on, that
--      tier degrades to an ordinary loaded cart rather than to empty.
--
-- Scaling is DOWNWARD only: a modifier at or above 1.0 keeps the designed
-- load, it never inflates it past the tier's weight budget.

--- Loot-category multiplier for an item type, mirroring vanilla's junk rule.
--- Returns 1.0 (i.e. no gating) when ItemPickerJava isn't reachable — offline
--- tests and any context without a loaded script manager keep legacy
--- behaviour rather than silently spawning nothing.
---@param itemType string|nil full type, e.g. "Base.Plank"
---@param isJunk boolean|nil junk padding: vanilla clamps a nonzero modifier to
---                          1.0 (ItemPickerJava.java:2086-2092), so filler is
---                          exempt from category scaling but still obeys the
---                          removal list
---@return number modifier 0 = never spawn
function CartLoot.lootModifierFor(itemType, isJunk)
    if not itemType then return 0 end

    -- No type-guard on the Java global on purpose: Kahlua's `type()` for an
    -- exposed Java class is not a value we should be asserting on, and a guard
    -- that guessed wrong would silently disable the whole gate in-game while
    -- every offline test kept passing. Let pcall be the only gate — a nil
    -- ItemPickerJava raises on index and lands in the same fallback.
    local ok, value = pcall(function()
        return ItemPickerJava.getLootModifier(itemType)
    end)
    if not ok or type(value) ~= "number" then return 1.0 end

    -- Vanilla's isJunk clamp, inlined rather than calling the two-arg overload
    -- (Kahlua resolves Java overloads by arity and we only need the one rule).
    if isJunk and value > 0 then return 1.0 end
    return value
end

--- Keep-or-skip roll against a loot multiplier (pure).
--- 0 never keeps, >= 1 always keeps, fractional keeps with p = modifier.
---@param modifier number
---@param rng fun(n:number):number
---@return boolean
function CartLoot.rollKeep(modifier, rng)
    if type(modifier) ~= "number" or modifier <= 0 then return false end
    if modifier >= 1 then return true end
    return rng(1000) < math.floor(modifier * 1000 + 0.5)
end

--- Current world loot-decay multiplier, clamped to [0,1]. 1.0 when the
--- sandbox isn't reachable.
---@return number
function CartLoot.worldLootMultiplier()
    local ok, value = pcall(function()
        return getSandboxOptions():getCurrentLootMultiplier()
    end)
    if not ok or type(value) ~= "number" then return 1.0 end
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

--- Is RemoveStoryLoot on? False when the sandbox isn't reachable.
---@return boolean
function CartLoot.storyLootRemoved()
    local ok, value = pcall(function()
        return getSandboxOptions():getOptionByName("RemoveStoryLoot"):getValue()
    end)
    return (ok and value == true) or false
end

--- Read the live sandbox into the options table decideCartLoad takes. Kept
--- separate so the decision itself stays pure and offline-testable.
---@return table { worldMult = number, removeStoryLoot = boolean }
function CartLoot.sandboxLootOptions()
    return {
        worldMult       = CartLoot.worldLootMultiplier(),
        removeStoryLoot = CartLoot.storyLootRemoved(),
    }
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
---@param opts table|nil { worldMult = number, removeStoryLoot = boolean } —
---            from CartLoot.sandboxLootOptions(); omitting it means "no
---            sandbox scaling", i.e. the original pre-gate behaviour
---@return table { tier = "empty"|"light"|"loaded"|"survivor", count = number }
function CartLoot.decideCartLoad(density, rng, opts)
    density = density or LOAD_DEFAULT
    local chance = LOAD_CHANCE[density] or LOAD_CHANCE[LOAD_DEFAULT]

    -- Loot decay over time thins carts exactly as it thins every other
    -- container. Scaling the LOAD CHANCE (not the per-item roll) keeps this
    -- scalar applied once; the per-item gate in fillCart owns category rarity.
    local worldMult = opts and opts.worldMult
    if type(worldMult) == "number" and worldMult < 1 then
        chance = chance * (worldMult > 0 and worldMult or 0)
    end

    if chance <= 0 then return { tier = "empty", count = 0 } end
    if rng(100) >= chance then return { tier = "empty", count = 0 } end

    -- The survivor roll is consumed unconditionally, so the rng stream up to
    -- this decision point is identical with and without RemoveStoryLoot; only
    -- the branch taken after a HIT differs (survivor -> ordinary loaded cart).
    local survivorRoll = rng(1000)
    if survivorRoll < SURVIVOR_PERMILLE and not (opts and opts.removeStoryLoot) then
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
--- Does this item type only exist to turn into something else on creation?
---
--- `OnCreate = Foo.Bar` in an item script is stored as Item.luaCreate and
--- fires at instantiation (InventoryItem.java:4558). Several weapon packs use
--- it for placeholder entries injected straight into vanilla distribution
--- lists — Guns of Marz puts `*_Spawner` stubs into GunStoreGuns and
--- ArmyStorageGuns, which the "survivor" context draws from.
---
--- They break cart loot two ways:
---   * the sandbox gate reads the WRONG item. A spawner stub is base:weapon
---     with no Ranged and no ammo type, so getLootType classifies it as MELEE
---     — a server that set firearms to Extremely Rare still gets guns in
---     survivor carts, scaled by the melee slider instead.
---   * it resolves a TICK LATER, off an OnTick retry queue, because at
---     instanceItem time the item has no container yet. fillCart therefore
---     measures a stub's weight, and WorldSpawning picks the cart's visual
---     model from that — so a cart can look near-empty and then quietly
---     contain a rifle, a magazine and two boxes of ammo.
---
--- Filtering by OnCreate rather than by name needs no knowledge of any
--- specific mod, and costs nothing real: the spawner families duplicate guns
--- already reachable from the same lists.
---@param itemType string full type
---@return boolean
function CartLoot.isPlaceholderItem(itemType)
    if not itemType then return false end
    local ok, luaCreate = pcall(function()
        local script = getScriptManager and getScriptManager():FindItem(itemType)
        return script and script.getLuaCreate and script:getLuaCreate()
    end)
    -- Unreachable script manager (offline tests, early boot) => treat as a
    -- normal item. Never silently empty the pool on a lookup failure.
    if not ok then return false end
    return type(luaCreate) == "string" and luaCreate ~= ""
end

--- Walk a flat `type1, weight1, type2, weight2, ...` distribution array into
--- weighted pool entries, applying the sandbox gate as a WEIGHT rather than a
--- later coin flip. See buildWeightedPool for why.
---@param items table flat array
---@param pool table accumulator
---@param modFn function|nil (itemType, isJunk) -> modifier
---@param isJunk boolean
local function absorbDistArray(items, pool, modFn, isJunk)
    if type(items) ~= "table" then return end
    local i, n = 1, #items
    while i + 1 <= n do
        local t = items[i]
        local w = tonumber(items[i + 1]) or 1
        if type(t) == "string" and w > 0 and not CartLoot.isPlaceholderItem(t) then
            if modFn then
                local m = modFn(t, isJunk)
                if type(m) ~= "number" then m = 1 end
                -- 0 (removal list / category None) drops the entry outright:
                -- the same hard guarantee the old reject path gave.
                -- Above 1 is NOT allowed to inflate — scaling is downward only,
                -- matching the tier's weight budget.
                if m > 0 then
                    pool[#pool + 1] = { type = t, weight = w * (m < 1 and m or 1) }
                end
            else
                pool[#pool + 1] = { type = t, weight = w }
            end
        end
        i = i + 2
    end
end

--- Build the weighted pick pool for a set of distribution list names.
---
--- SANDBOX RARITY IS FOLDED INTO THE WEIGHT, not applied as a pick-then-reject
--- roll. The old shape picked an item and then binned it on a failed roll,
--- which consumed one of the tier's `count` either way — so suppression made
--- carts THINNER rather than differently composed, and a firearms-suppressed
--- survivor cache arrived close to empty. A cart is meant to be a reward; a
--- suppressed category should redirect the budget, not delete it.
---
--- Aggregate odds for any given suppressed item are unchanged. What changes is
--- the substitution behaviour: the cart still fills from whatever remains, so
--- firearms-off yields a cache of ammo and gear instead of nothing.
---@param names table list of ProceduralDistributions.list keys
---@param modFn function|nil loot-modifier lookup; omitted = no scaling
---@return table pool
function CartLoot.buildWeightedPool(names, modFn)
    local pool = {}
    local PD = ProceduralDistributions
    if type(PD) ~= "table" or type(PD.list) ~= "table" then return pool end
    for _, name in ipairs(names) do
        local dist = PD.list[name]
        absorbDistArray(dist and dist.items, pool, modFn, false)
    end
    return pool
end

--- Build a junk pool from the CONTEXT'S OWN distribution tables.
---
--- Every vanilla table carries a `junk` sub-table beside `items` and we never
--- read it: measured across all 1350 tables in ProceduralDistributions, all
--- 1350 have a junk block and 292 are non-empty (Paperwork in 91, DishCloth in
--- 40, Doodle in 33, the character photos in 24 each). That is thematic,
--- per-container clutter — exactly what the global JUNK_POOL approximates.
--- A grocery cart padded with a dishcloth and paperwork reads better than one
--- padded with planks and jars.
---
--- Returns an empty pool for the ~78% of contexts whose junk blocks are all
--- empty; padToFillState falls back to JUNK_POOL there.
---@param names table list of ProceduralDistributions.list keys
---@param modFn function|nil loot-modifier lookup
---@return table pool
function CartLoot.buildJunkPool(names, modFn)
    local pool = {}
    local PD = ProceduralDistributions
    if type(PD) ~= "table" or type(PD.list) ~= "table" then return pool end
    for _, name in ipairs(names) do
        local dist = PD.list[name]
        local junk = dist and dist.junk
        absorbDistArray(junk and junk.items, pool, modFn, true)
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
---@param modFn fun(itemType:string, isJunk:boolean):number|nil loot-modifier
---             lookup; defaults to CartLoot.lootModifierFor. Injected so tests
---             can drive the sandbox gate without a live ItemPickerJava.
---@return number placedCount
---@return number placedWeight
function CartLoot.fillCart(cartItem, contextKey, tier, count, rng, modFn)
    if tier == "empty" or not cartItem then return 0, 0 end
    local container = cartItem.getItemContainer and cartItem:getItemContainer()
    if not container or not container.AddItem then return 0, 0 end

    modFn = modFn or CartLoot.lootModifierFor

    local poolKey = (tier == "survivor") and "survivor" or contextKey
    -- Sandbox rarity is applied HERE, as pick weight. Do not also roll per
    -- pick — that would apply the modifier twice. A fully suppressed context
    -- yields an empty pool and returns early on the guard below, which is the
    -- same outcome the old reject path reached by binning every pick.
    local pool = CartLoot.buildWeightedPool(CartLoot.poolFor(poolKey), modFn)
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
---@param modFn fun(itemType:string, isJunk:boolean):number|nil see fillCart.
---             Junk is exempt from category rarity (vanilla's isJunk clamp)
---             but a filler type on the admin removal list is still skipped.
---@return number junkCount
---@return number junkWeight
function CartLoot.padToFillState(cartItem, targetRatio, rng, modFn, contextKey)
    if not cartItem or not targetRatio then return 0, 0 end
    local container = cartItem.getItemContainer and cartItem:getItemContainer()
    if not container or not container.AddItem or not container.getCapacity then
        return 0, 0
    end
    local capacity = container:getCapacity() or 0
    if capacity <= 0 then return 0, 0 end

    modFn = modFn or CartLoot.lootModifierFor

    -- Prefer the CONTEXT'S own junk (thematic, per-container) and fall back to
    -- the global JUNK_POOL, which is the common case — about 78% of vanilla
    -- junk blocks are empty. Placeholder and zero-modifier entries are already
    -- filtered out during pool construction.
    local ctxJunk = contextKey and CartLoot.buildJunkPool(CartLoot.poolFor(contextKey), modFn) or nil
    local useCtx = ctxJunk and #ctxJunk > 0

    local target = targetRatio * capacity
    local junkCount, junkWeight, guard = 0, 0, 0
    while container:getCapacityWeight() < target
        and junkWeight < JUNK_WEIGHT_CAP
        and guard < JUNK_MAX_ITEMS do
        guard = guard + 1
        local typ
        if useCtx then
            typ = CartLoot.pickWeighted(ctxJunk, rng)
        else
            typ = JUNK_POOL[1 + rng(#JUNK_POOL)]
            -- The global pool is a bare list, so it still needs the gate here.
            -- Junk bypasses category rarity (vanilla's isJunk clamp) but must
            -- still obey the removal list. Banned filler is skipped, not
            -- substituted: the guard counter still advances, so an all-banned
            -- JUNK_POOL terminates instead of spinning.
            if typ and not CartLoot.rollKeep(modFn(typ, true), rng) then typ = nil end
        end
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
