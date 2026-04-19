--[[
    SaucedCarts — Building-signature spawn filter tests
    ====================================================

    Exercises SaucedCarts.evaluateSpawnEligibility / canSpawnInBuilding
    against mocked BuildingDef/IsoBuilding surfaces. We test OUR filter
    logic, not PZ's isResidential/isShop implementations — those are
    already PZ's concern.

    Scenarios:
      - base entry (no opt-outs) in a residential building  -> denied
      - base entry in an outdoor square (no building)        -> denied
      - base entry in a commercial building                  -> allowed
      - entry with allowResidential in residential           -> allowed
      - entry with allowOutdoor on outdoor square            -> allowed
      - entry with skipFrameworkFilters anywhere             -> allowed
      - StrictShopOnly sandbox on, non-shop commercial       -> denied
      - StrictShopOnly sandbox on, shop commercial           -> allowed
      - nil building without allowOutdoor                    -> denied
      - def missing (degraded path)                          -> allowed
      - addSpawnRooms propagates flags to SpawnEntry         -> preserved
]]

if isServer() and not isClient() then return end

if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/SpawnLocations"

-- ============================================================================
-- MOCKS
-- ============================================================================

local function makeBuildingDef(opts)
    opts = opts or {}
    return {
        _residential = opts.residential == true,
        _shop        = opts.shop == true,
        isResidential = function(self) return self._residential end,
        isShop        = function(self) return self._shop end,
    }
end

local function makeBuilding(def)
    return {
        _def = def,
        getDef = function(self) return self._def end,
    }
end

-- Save/restore sandbox around tests that flip StrictShopOnly.
SandboxVars = SandboxVars or {}
SandboxVars.SaucedCarts = SandboxVars.SaucedCarts or {}
local function withStrictShopOnly(value, fn)
    local saved = SandboxVars.SaucedCarts.StrictShopOnly
    SandboxVars.SaucedCarts.StrictShopOnly = value
    local ok, err = pcall(fn)
    SandboxVars.SaucedCarts.StrictShopOnly = saved
    if not ok then error(err) end
end

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

tests["base_entry_residential_denied"] = function()
    local b = makeBuilding(makeBuildingDef({ residential = true }))
    local entry = { type = "X.Cart", chance = 50 }
    local e = SaucedCarts.evaluateSpawnEligibility(b, entry)
    if not Assert.isFalse(e.allowed, "residential denied") then return false end
    return Assert.equal(e.reason, "residential_denied", "reason tag")
end

tests["base_entry_outdoor_denied"] = function()
    local entry = { type = "X.Cart", chance = 50 }
    local e = SaucedCarts.evaluateSpawnEligibility(nil, entry)
    if not Assert.isFalse(e.allowed, "outdoor denied") then return false end
    return Assert.equal(e.reason, "outdoor_denied", "reason tag")
end

tests["base_entry_commercial_allowed"] = function()
    local b = makeBuilding(makeBuildingDef({ residential = false, shop = true }))
    local entry = { type = "X.Cart", chance = 50 }
    return Assert.isTrue(SaucedCarts.canSpawnInBuilding(b, entry),
        "commercial building allowed")
end

tests["allowResidential_opts_in"] = function()
    local b = makeBuilding(makeBuildingDef({ residential = true }))
    local entry = { type = "X.Cart", chance = 50, allowResidential = true }
    return Assert.isTrue(SaucedCarts.canSpawnInBuilding(b, entry),
        "allowResidential bypasses residential filter")
end

tests["allowOutdoor_opts_in"] = function()
    local entry = { type = "X.Cart", chance = 50, allowOutdoor = true }
    local e = SaucedCarts.evaluateSpawnEligibility(nil, entry)
    if not Assert.isTrue(e.allowed, "allowOutdoor opts in") then return false end
    return Assert.equal(e.reason, "outdoor_allowed", "reason tag")
end

tests["skipFrameworkFilters_bypasses_all"] = function()
    -- Residential + StrictShopOnly + non-shop: every filter should deny.
    -- skipFrameworkFilters must still allow.
    withStrictShopOnly(true, function()
        local b = makeBuilding(makeBuildingDef({ residential = true, shop = false }))
        local entry = { type = "X.Cart", chance = 50, skipFrameworkFilters = true }
        local e = SaucedCarts.evaluateSpawnEligibility(b, entry)
        if not Assert.isTrue(e.allowed, "skipFrameworkFilters allows everything") then
            error("fail")
        end
        if not Assert.equal(e.reason, "skipFrameworkFilters", "reason tag") then
            error("fail")
        end
    end)
    return true
end

tests["strictShopOnly_denies_non_shop_commercial"] = function()
    withStrictShopOnly(true, function()
        local b = makeBuilding(makeBuildingDef({ residential = false, shop = false }))
        local entry = { type = "X.Cart", chance = 50 }
        local e = SaucedCarts.evaluateSpawnEligibility(b, entry)
        if not Assert.isFalse(e.allowed, "non-shop denied under strict") then error("fail") end
        if not Assert.equal(e.reason, "not_shop_strict", "reason tag") then error("fail") end
    end)
    return true
end

tests["strictShopOnly_allows_shop"] = function()
    withStrictShopOnly(true, function()
        local b = makeBuilding(makeBuildingDef({ residential = false, shop = true }))
        local entry = { type = "X.Cart", chance = 50 }
        if not Assert.isTrue(SaucedCarts.canSpawnInBuilding(b, entry),
            "shop allowed under strict") then error("fail") end
    end)
    return true
end

tests["strictShopOnly_off_allows_non_shop_commercial"] = function()
    -- Sanity: with StrictShopOnly off (default), a non-shop commercial
    -- building still passes the filter if it isn't residential.
    withStrictShopOnly(false, function()
        local b = makeBuilding(makeBuildingDef({ residential = false, shop = false }))
        local entry = { type = "X.Cart", chance = 50 }
        if not Assert.isTrue(SaucedCarts.canSpawnInBuilding(b, entry),
            "non-shop commercial allowed when StrictShopOnly off") then error("fail") end
    end)
    return true
end

tests["no_def_degrades_to_allow"] = function()
    -- Building with no getDef — the defensive "degrade to allow" branch
    -- keeps spawns working on buildings with unusual surfaces instead of
    -- silently suppressing them.
    local b = { getDef = function() return nil end }
    local entry = { type = "X.Cart", chance = 50 }
    local e = SaucedCarts.evaluateSpawnEligibility(b, entry)
    if not Assert.isTrue(e.allowed, "no-def allows") then return false end
    return Assert.equal(e.reason, "no_def_degraded_allow", "reason tag")
end

tests["addSpawnRooms_propagates_flags"] = function()
    -- Register a cart type with per-entry flags and verify the flags
    -- survive into the SpawnLocation table so the server-side filter
    -- sees them at runtime.
    SaucedCarts.addSpawnRooms("Test.FlagCart", {
        { room = "testroom_A", chance = 10, allowResidential = true },
        { room = "testroom_B", chance = 20, allowOutdoor = true },
        { room = "testroom_C", chance = 30, skipFrameworkFilters = true },
    })

    local entries = SaucedCarts.getSpawnEntriesForRoom("testroom_A")
    if not Assert.notNil(entries, "entries A") then return false end
    if not Assert.isTrue(entries[1].allowResidential, "flag A preserved") then return false end

    entries = SaucedCarts.getSpawnEntriesForRoom("testroom_B")
    if not Assert.isTrue(entries[1].allowOutdoor, "flag B preserved") then return false end

    entries = SaucedCarts.getSpawnEntriesForRoom("testroom_C")
    if not Assert.isTrue(entries[1].skipFrameworkFilters, "flag C preserved") then return false end

    return true
end

-- ============================================================================
-- DEFAULT ROOM LIST HYGIENE
-- ============================================================================
-- Guard against regressions where someone adds a "supermarket" or "mall"
-- style phantom to the default list. In offline tests, ItemPickerJava
-- isn't available — getPhantomSpawnRooms() would flag every entry. We
-- instead assert against a hardcoded expected-vanilla set derived from
-- PZ's Distributions.lua. If PZ renames or removes a room, this test
-- catches it on the next run.

-- Rooms we've verified exist in media/lua/server/Items/Distributions.lua.
-- Update when adding new vanilla rooms to DEFAULT_SPAWN_LOCATIONS.
local KNOWN_VANILLA_ROOMS = {
    gigamart = true, grocery = true, departmentstore = true,
    grocerystorage = true, warehouse = true,
    housewarestore = true, departmentstorage = true, producestorage = true,
    toolstore = true, gardenstore = true,
    furniturestore = true, furniturestorage = true,
    outdoorsupply = true, carsupply = true, generalstore = true,
    giftstore = true, garagestorage = true, electronicstore = true,
    storageunit = true, liquorstore = true, petstore = true,
    clothingstorage = true, generalstorestorage = true,
    camping = true, campingstorage = true, giftstorage = true,
    outdoorsupply_storage = true,
    clothingstore = true, sportstore = true,
    bookstore = true, conveniencestore = true, cornerstore = true,
    storage = true, lobby = true, pawnshop = true,
}

tests["default_rooms_have_no_phantom_names"] = function()
    -- Test only the rooms owned by the base ShoppingCart. Other tests
    -- (addSpawnRooms_propagates_flags) may have already registered test-only
    -- phantom rooms like "testroom_A" — we intentionally exclude non-base
    -- cart types.
    local violations = {}
    for roomName, entries in pairs(SaucedCarts.SpawnLocations) do
        local hasBaseCart = false
        for _, e in ipairs(entries) do
            if e.type == "SaucedCarts.ShoppingCart" then
                hasBaseCart = true
                break
            end
        end
        if hasBaseCart and not KNOWN_VANILLA_ROOMS[roomName] then
            table.insert(violations, roomName)
        end
    end
    if #violations > 0 then
        table.sort(violations)
        return Assert.equal(#violations, 0,
            "base ShoppingCart should only spawn in vanilla rooms, got phantoms: "
            .. table.concat(violations, ", "))
    end
    return Assert.equal(#violations, 0, "no phantom names in base defaults")
end

tests["isVanillaRoom_nil_safe_offline"] = function()
    -- Offline harness has no ItemPickerJava — function must degrade to false
    -- without throwing.
    if not Assert.isFalse(SaucedCarts.isVanillaRoom("grocery"),
        "offline: isVanillaRoom returns false (no ItemPickerJava)") then return false end
    if not Assert.isFalse(SaucedCarts.isVanillaRoom(""),
        "empty string rejected") then return false end
    return Assert.isFalse(SaucedCarts.isVanillaRoom(nil),
        "nil rejected")
end

tests["isVanillaRoom_uses_ItemPickerJava_when_present"] = function()
    -- Inject a mock ItemPickerJava globally, exercise the Lua wrapper,
    -- then restore. Proves the wrapper actually consults PZ's Java API
    -- when it's available.
    local saved = ItemPickerJava
    ItemPickerJava = {
        hasDistributionForRoom = function(name)
            return name == "grocery" or name == "gigamart"
        end,
    }
    local ok1 = SaucedCarts.isVanillaRoom("grocery")
    local ok2 = SaucedCarts.isVanillaRoom("gigamart")
    local ok3 = SaucedCarts.isVanillaRoom("notaroom")
    ItemPickerJava = saved

    if not Assert.isTrue(ok1, "grocery recognised") then return false end
    if not Assert.isTrue(ok2, "gigamart recognised") then return false end
    return Assert.isFalse(ok3, "unknown room rejected")
end

tests["canSpawnInBuilding_is_boolean_wrapper"] = function()
    -- canSpawnInBuilding is the ergonomic boolean version of
    -- evaluateSpawnEligibility — they must agree in both directions.
    local b = makeBuilding(makeBuildingDef({ residential = true }))
    local entry = { type = "X.Cart", chance = 50 }
    if not Assert.equal(
        SaucedCarts.canSpawnInBuilding(b, entry),
        SaucedCarts.evaluateSpawnEligibility(b, entry).allowed,
        "boolean matches full result"
    ) then return false end

    local entry2 = { type = "X.Cart", chance = 50, allowResidential = true }
    return Assert.equal(
        SaucedCarts.canSpawnInBuilding(b, entry2),
        SaucedCarts.evaluateSpawnEligibility(b, entry2).allowed,
        "boolean matches full result (flag case)"
    )
end

return tests
