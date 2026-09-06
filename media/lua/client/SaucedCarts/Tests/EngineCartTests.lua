--[[
    Carts against the REAL engine
    =============================
    This config's own header used to say the interesting tests were stuck
    in-game because offline had no "instanceItem for real InventoryContainer".
    Engine mode ends that: PZEngine.instanceItem mints a REAL
    SaucedCarts.ShoppingCart from the mod's script parsed by PZ's own
    ScriptManager, with a real ItemContainer inside. What that buys:

      * The CartData registry's "MUST match the script" comments become
        executable — capacity, conditionMax, baseWeight verified against the
        real parsed script for EVERY registered cart, including future ones.
      * The vanilla transfer canon (ISTransferAction.transferItem, loaded
        real via vanilla_requires) runs against real Java containers — the
        DoRemoveItem/AddItem path where every dupe vector in this mod's
        history lived, with real item IDs.
      * Engine-lore comments (the ItemContainer 50-capacity cap) get pinned
        by execution instead of trusted from a java line number.

    Engine-guarded: with no PZ install (CI) this file contributes no tests.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end
if not (PZEngine and PZEngine.available()) then return {} end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartData"

local function near(actual, expected, tol, label)
    local ok = type(actual) == "number" and math.abs(actual - expected) <= tol
    return Assert.isTrue(ok, label .. " (" .. tostring(actual) .. " ~ " .. tostring(expected) .. ")")
end

local tests = {}

tests["engine_cart_is_a_real_container_item"] = function()
    local cart = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    if not Assert.isTrue(cart ~= nil, "engine mints the mod's cart from its real script") then
        return false
    end
    if not Assert.isTrue(instanceof(cart, "InventoryContainer"), "and it is a real InventoryContainer") then
        return false
    end
    local inv = cart:getInventory()
    if not Assert.isTrue(inv ~= nil, "with a real ItemContainer inside") then return false end
    -- FIRST ENGINE FINDING for this mod: the effective capacity of a
    -- carried container is min(script Capacity, 50 - the container's OWN
    -- weight) — InventoryContainer.getCapacity subtracts actualWeight
    -- (InventoryContainer.java:81-86). Script says 50, the cart weighs 8,
    -- the game answers 42. The registry lore "PZ caps at 50" was the
    -- half of the formula you can see from ItemContainer.java alone.
    return Assert.equal(cart:getCapacity(), 42, "real effective capacity = 50 - 8")
end

tests["engine_registry_matches_the_real_scripts"] = function()
    -- CartData mirrors script fields because some have no Lua getter, held
    -- in sync by comment discipline alone until now. Every registered cart
    -- (including addon carts, if any are loaded) gets its mirror checked
    -- against the item the real parser built.
    local bad = {}
    local count = 0
    for fullType, entry in pairs(SaucedCarts.CartTypes) do
        count = count + 1
        local cart = PZEngine.instanceItem(fullType)
        if not cart then
            bad[#bad + 1] = fullType .. ": not in the real registry"
        else
            local inv = cart:getInventory()
            -- The registry documents the SCRIPT capacity; the game's
            -- effective value is min(script, 50 - baseWeight)
            -- (InventoryContainer.java:81-86). Check the formula, so the
            -- mirror stays honest for every cart including addon carts.
            if inv and entry.capacity and entry.baseWeight then
                local effective = math.min(entry.capacity, 50 - entry.baseWeight)
                if inv:getCapacity() ~= effective then
                    bad[#bad + 1] = fullType .. ": effective capacity "
                        .. effective .. " vs script " .. inv:getCapacity()
                end
            end
            if entry.conditionMax and cart:getConditionMax() ~= entry.conditionMax then
                bad[#bad + 1] = fullType .. ": conditionMax " .. entry.conditionMax .. " vs script " .. cart:getConditionMax()
            end
            if entry.baseWeight and math.abs(cart:getActualWeight() - entry.baseWeight) > 0.01 then
                bad[#bad + 1] = fullType .. ": baseWeight " .. entry.baseWeight .. " vs script " .. cart:getActualWeight()
            end
        end
    end
    if not Assert.isTrue(count >= 1, "registry has carts (" .. count .. ")") then return false end
    return Assert.equal(#bad, 0,
        "registry mirrors the real scripts; offenders: " .. table.concat(bad, ", "))
end

tests["engine_vanilla_transfer_moves_real_items_without_duping"] = function()
    -- The canonical move, on real Java containers: vanilla's own
    -- ISTransferAction.transferItem (real file via vanilla_requires) between
    -- a real cart inventory and a real duffel inventory. The invariant every
    -- SaucedCarts dupe incident violated: after a transfer there is exactly
    -- ONE item, same Java ID, in exactly one container.
    local cart = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    local bag = PZEngine.instanceItem("Base.Bag_DuffelBag")
    if not Assert.isTrue(cart ~= nil and bag ~= nil, "real cart and real duffel") then return false end
    local src, dest = cart:getInventory(), bag:getInventory()

    local bulb = PZEngine.instanceItem("Base.LightBulb")
    src:AddItem(bulb)
    local id = bulb:getID()
    if not Assert.isTrue(src:contains(bulb), "seeded into the cart") then return false end

    local character = { getInventory = function() return dest end }
    ISTransferAction:transferItem(character, bulb, src, dest, nil)

    if not Assert.isFalse(src:contains(bulb), "gone from the cart") then return false end
    if not Assert.isTrue(dest:contains(bulb), "arrived in the duffel") then return false end
    if not Assert.equal(bulb:getID(), id, "same Java item id — moved, not recreated") then return false end
    return Assert.equal(dest:getItems():size(), 1, "exactly one item exists")
end

tests["engine_container_capacity_cap_lore_is_executable"] = function()
    -- CartData carries the lore "PZ caps InventoryContainer items at 50
    -- (ItemContainer.java:155-156)" as a comment. Pin the behavior itself:
    -- a real cart's container refuses to report past the cap however the
    -- capacity got there.
    local cart = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    local inv = cart:getInventory()
    inv:setCapacity(120)
    return Assert.isTrue(inv:getCapacity() <= 50,
        "the java-side cap holds (asked 120, got " .. inv:getCapacity() .. ")")
end

tests["engine_weight_reduction_is_real"] = function()
    -- WeightReduction 95 is why a loaded cart is pushable: contents count
    -- 5%. And equipping discounts the cart's OWN weight to 30% —
    -- ZomboidGlobals.EquippedOrWornEncumbranceMultiplier from the game's
    -- real defines.lua (0.3), which the engine boot now loads. Ten real
    -- bulbs at 0.3 = 3.0 raw: equipped weight = 8·0.3 + 3.0·0.05 = 2.55.
    -- Real InventoryContainer weight math end to end, not our arithmetic.
    local cart = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    local inv = cart:getInventory()
    for _ = 1, 10 do inv:AddItem(PZEngine.instanceItem("Base.LightBulb")) end
    local carried = cart:getEquippedWeight()
    return near(carried, 8.0 * 0.3 + 3.0 * 0.05, 0.05,
        "equipped weight = own weight at 30% + contents at 5%")
end

tests["engine_transfer_batch_preserves_every_item"] = function()
    -- Twenty distinct real items through the vanilla canon, both
    -- directions. The dupe class this mod's history is made of shows up as
    -- a count or identity mismatch; real Java IDs make identity checkable.
    local cart = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    local bag = PZEngine.instanceItem("Base.Bag_DuffelBag")
    local src, dest = cart:getInventory(), bag:getInventory()
    local character = { getInventory = function() return dest end }

    local ids = {}
    local items = {}
    for i = 1, 20 do
        local item = PZEngine.instanceItem("Base.LightBulb")
        src:AddItem(item)
        items[i] = item
        ids[item:getID()] = true
    end

    for _, item in ipairs(items) do
        ISTransferAction:transferItem(character, item, src, dest, nil)
    end
    if not Assert.equal(src:getItems():size(), 0, "cart emptied") then return false end
    if not Assert.equal(dest:getItems():size(), 20, "duffel holds all twenty") then return false end
    for i = 0, dest:getItems():size() - 1 do
        local got = dest:getItems():get(i)
        if not ids[got:getID()] then
            return Assert.isTrue(false, "unknown id appeared: " .. tostring(got:getID()))
        end
        ids[got:getID()] = nil
    end

    -- And back again: the return trip must also be lossless.
    local backChar = { getInventory = function() return src end }
    for i = dest:getItems():size() - 1, 0, -1 do
        ISTransferAction:transferItem(backChar, dest:getItems():get(i), dest, src, nil)
    end
    if not Assert.equal(dest:getItems():size(), 0, "duffel emptied on return") then return false end
    return Assert.equal(src:getItems():size(), 20, "cart holds all twenty again")
end

tests["engine_nested_bag_in_cart_transfers_whole"] = function()
    -- A packed bag moved INTO the cart must arrive with its contents —
    -- the containment chain (item -> its container -> containing item) is
    -- real Java state here, the exact structure the pocketing and
    -- bag-in-vehicle incidents lived on.
    local cart = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    local bag = PZEngine.instanceItem("Base.Bag_DuffelBag")
    local bulb = PZEngine.instanceItem("Base.LightBulb")
    bag:getInventory():AddItem(bulb)

    local staging = PZEngine.instanceItem("Base.Bag_BigHikingBag")
    local src = staging:getInventory()
    src:AddItem(bag)

    local dest = cart:getInventory()
    local character = { getInventory = function() return dest end }
    ISTransferAction:transferItem(character, bag, src, dest, nil)

    if not Assert.isTrue(dest:contains(bag), "bag arrived in the cart") then return false end
    if not Assert.isTrue(bag:getInventory():contains(bulb), "with its contents intact") then return false end
    return Assert.equal(bag:getInventory():getItems():size(), 1, "and nothing duplicated inside")
end

tests["engine_findCart_resolves_through_real_nested_containers"] = function()
    -- The server-side equip resolver (ISCartEquipAction:findCart) walking
    -- REAL Java containers: cart nested inside a real duffel inside the
    -- "player inventory". The mock matrix (OfflineEquipResolutionTests)
    -- proves the ladder's shape; this proves the walk against the real
    -- getItems/instanceof/getInventory surface it runs on in production.
    require "SaucedCarts/TimedActions/ISCartEquipAction"

    local backpack = PZEngine.instanceItem("Base.Bag_BigHikingBag")
    local duffel = PZEngine.instanceItem("Base.Bag_DuffelBag")
    local cart = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    duffel:getInventory():AddItem(cart)
    backpack:getInventory():AddItem(duffel)

    local action = setmetatable({
        character  = { getInventory = function() return backpack:getInventory() end,
                       getX = function() return nil end,
                       getY = function() return nil end,
                       getZ = function() return nil end },
        cartId     = cart:getID(),
        sourceType = "inventory",
    }, { __index = ISCartEquipAction })

    local found = action:findCart()
    if not Assert.isTrue(found ~= nil, "nested real cart resolves") then return false end
    if not Assert.equal(found:getID(), cart:getID(), "and it is the exact item") then return false end

    -- ID-exactness on real items too: a different id resolves nothing.
    local miss = setmetatable({
        character  = action.character,
        cartId     = cart:getID() + 1,
        sourceType = "inventory",
    }, { __index = ISCartEquipAction })
    return Assert.isTrue(miss:findCart() == nil, "wrong id resolves nothing")
end

tests["engine_additem_does_not_enforce_capacity"] = function()
    -- Load-bearing lore made executable: ItemContainer.AddItem enforces
    -- NOTHING — capacity is the CALLER's job (TransactionManager server-
    -- side, UI checks client-side). This is precisely why SaucedCarts
    -- ships its own capacity gate; if the engine ever starts enforcing,
    -- this test tells us the mod's gate needs re-deriving.
    local cart = PZEngine.instanceItem("SaucedCarts.ShoppingCart")
    local inv = cart:getInventory()
    for _ = 1, 60 do inv:AddItem(PZEngine.instanceItem("Base.Log")) end
    return Assert.equal(inv:getItems():size(), 60,
        "sixty logs accepted into a 42-capacity cart — enforcement is the caller's")
end

return tests
