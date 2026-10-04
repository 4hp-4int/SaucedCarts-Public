--[[
    Cart loot against the REAL loot system
    ======================================
    v2.1.21 made loaded carts obey the vanilla loot sandbox. "Vanilla" here
    means three engine pieces, all real in this file:

      * vanilla's ProceduralDistributions tables, loaded from the install,
      * ItemPickerJava.getLootModifier -- the same per-category rarity and
        LootItemRemovalList check every container in the game rolls through,
        recomputed from the real sandbox by InitSandboxLootSettings,
      * real items minted from the parsed scripts into a real cart.

    Options are set through the engine's typed options (PZEngine.sandboxSet),
    so a value the engine would refuse is refused here too.

    Engine-guarded: with no PZ install (CI) this file contributes no tests.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end
if not (PZEngine and PZEngine.available() and PZEngine.sandboxSet and PZEngine.loadVanilla) then return {} end
if not ItemPickerJava then return {} end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartData"
require "SaucedCarts/CartLoot"
local CartLoot = SaucedCarts.CartLoot

-- getSandboxOptions is a LuaManager global in game; the harness has the
-- real SandboxOptions class exposed, so point the global at its instance.
getSandboxOptions = getSandboxOptions or function() return SandboxOptions.instance end

local distLoaded = false
local function ensureDistributions()
    if distLoaded then return true end
    if not ProceduralDistributions then
        -- ProceduralDistributions references ClutterTables.*, which the
        -- Distribution_*Junk files define; the game loads them first.
        for _, f in ipairs({ "Distribution_BinJunk", "Distribution_ClosetJunk", "Distribution_CounterJunk",
            "Distribution_DeskJunk", "Distribution_ShelfJunk", "Distribution_SideTableJunk",
            "Distribution_BagsAndContainers" }) do
            local ok, err = PZEngine.loadVanilla("server/Items/" .. f)
            if not ok then print(f .. ": " .. tostring(err)) end
        end
        local ok, err = PZEngine.loadVanilla("server/Items/ProceduralDistributions")
        if not ok then print("ProceduralDistributions: " .. tostring(err)) return false end
    end
    distLoaded = ProceduralDistributions ~= nil
    return distLoaded
end

--- Run fn with sandbox options set (engine-validated), loot modifiers
--- recomputed, real instanceItem behind the global; restore afterwards.
local function withLoot(settings, fn)
    local before = {}
    for name, value in pairs(settings) do
        before[name] = SandboxOptions.instance:getOptionByName(name):asConfigOption():getValueAsObject()
        PZEngine.sandboxSet(name, value)
    end
    ItemPickerJava.InitSandboxLootSettings()
    local mockInstance = instanceItem
    instanceItem = PZEngine.instanceItem
    local ok, result = pcall(fn)
    instanceItem = mockInstance
    for name, value in pairs(before) do PZEngine.sandboxSet(name, value) end
    ItemPickerJava.InitSandboxLootSettings()
    if not ok then error(result, 0) end
    return result
end

-- Deterministic rng: rng(n) -> [0, n).
local function lcg(seed)
    local s = seed
    return function(n)
        s = (s * 1103515245 + 12345) % 2147483648
        return s % n
    end
end

local function cartWithLoot(context, tier, count, seed)
    local c = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    local placed = CartLoot.fillCart(c, context, tier, count, lcg(seed))
    return c, placed
end

local function contents(c)
    local out, items = {}, c:getItemContainer():getItems()
    for i = 0, items:size() - 1 do out[#out + 1] = items:get(i) end
    return out
end

local function isFirearm(it)
    return instanceof(it, "HandWeapon") and it:isRanged()
end

local tests = {}

tests["loot_engine_rarity_reacts_to_the_real_sandbox"] = function()
    return withLoot({}, function()
        if not Assert.isTrue(ItemPickerJava.getLootModifier("Base.Pistol") > 0,
            "default: pistols spawn") then return false end
        return withLoot({ RangedWeaponLootNew = 0 }, function()
            return Assert.equal(ItemPickerJava.getLootModifier("Base.Pistol"), 0,
                "RangedWeaponLootNew 0: the engine's own gate says never")
        end)
    end)
end

tests["loot_every_cart_pool_item_is_real"] = function()
    if not Assert.isTrue(ensureDistributions(), "vanilla ProceduralDistributions loaded") then return false end
    return withLoot({}, function()
        for _, ctx in ipairs({ "grocery", "materials", "tools", "survivor", "generic" }) do
            local pool = CartLoot.buildWeightedPool(CartLoot.poolFor(ctx))
            if not Assert.isTrue(#pool > 0, ctx .. ": pool built from vanilla tables") then return false end
            for _, e in ipairs(pool) do
                -- Through instanceItem, as fillCart spawns -- NOT FindItem:
                -- vanilla's tables list names like "JerryCanEmpty" that are no
                -- script item, and InventoryItemFactory.CreateItem resolves them
                -- itself (InventoryItemFactory.java:62).
                if not Assert.notNil(instanceItem(e.type),
                    ctx .. ": " .. e.type .. " spawns a real item") then return false end
            end
        end
        return true
    end)
end

-- "Reweight instead of reject": with firearms off, a survivor cache still
-- arrives full -- of everything else that belongs there.
tests["loot_firearms_off_survivor_cart_still_fills_without_guns"] = function()
    if not ensureDistributions() then return false end
    return withLoot({ RangedWeaponLootNew = 0 }, function()
        local c, placed = cartWithLoot("survivor", "survivor", 8, 7)
        if not Assert.isTrue(placed >= 1, "the cart is not empty (" .. placed .. " items)") then return false end
        for _, it in ipairs(contents(c)) do
            if not Assert.isFalse(isFirearm(it), "no firearm: " .. it:getFullType()) then return false end
        end
        return true
    end)
end

-- Vanilla's "XEmpty" entries are not items; the engine's item factory turns
-- them into the container, empty. CartLoot relies on that, unaided.
tests["loot_empty_suffix_spawns_an_empty_container"] = function()
    return withLoot({}, function()
        local can = instanceItem("JerryCanEmpty")
        if not Assert.notNil(can, "JerryCanEmpty spawns something") then return false end
        if not Assert.equal(can:getFullType(), "Base.JerryCan", "a jerry can") then return false end
        return Assert.isTrue(can:getFluidContainer():isEmpty(), "and it is empty")
    end)
end

tests["loot_banned_item_never_spawns"] = function()
    if not ensureDistributions() then return false end
    return withLoot({}, function()
        -- Find something the tools pool actually rolls, then ban it.
        local pool = CartLoot.buildWeightedPool(CartLoot.poolFor("tools"))
        local banned = pool[1] and pool[1].type
        if not Assert.notNil(banned, "tools pool has items") then return false end
        return withLoot({ LootItemRemovalList = banned }, function()
            if not Assert.equal(ItemPickerJava.getLootModifier(banned), 0,
                "the engine reads " .. banned .. " as banned") then return false end
            for seed = 1, 40 do
                local c = cartWithLoot("tools", "full", 10, seed)
                for _, it in ipairs(contents(c)) do
                    if it:getFullType() == banned then
                        return Assert.fail("banned " .. banned .. " spawned (seed " .. seed .. ")")
                    end
                end
            end
            return true
        end)
    end)
end

tests["loot_story_loot_option_is_the_real_one"] = function()
    return withLoot({ RemoveStoryLoot = true }, function()
        if not Assert.isTrue(CartLoot.storyLootRemoved(), "RemoveStoryLoot on") then return false end
        return withLoot({ RemoveStoryLoot = false }, function()
            return Assert.isFalse(CartLoot.storyLootRemoved(), "RemoveStoryLoot off")
        end)
    end)
end

return tests
