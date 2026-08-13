--[[
    SaucedCarts — the "Grab option leak" (post-createMenu sweep)
    ============================================================

    Field report (prsly, 2026-08): the vanilla "Grab" option shows on a
    ground cart; clicking it fires our "I can't put a grocery cart in my
    pocket" block message. The behavior layer held — the menu entry leaked.

    Mechanism: vanilla B42 no longer adds ANY option wired to
    ISWorldObjectContextMenu.onGrabWItem / onGrabHalfWItems / onGrabAllWItems
    (dead legacy handlers, zero vanilla call sites). A third-party mod re-adds
    the B41-style Grab wired to them. Our OnFillWorldObjectContextMenu
    name-based removal only wins when it runs AFTER the re-adding mod's
    handler (event order = mod load order) and any custom label defeats it.

    Fix under test: TransferRestrictions' post-createMenu sweep — runs after
    every fill handler, matches by HANDLER IDENTITY (live fields + pre-hook
    originals in GrabRestrictions.legacyOriginals), removes an option only
    when everything it targets is a cart.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/Restrictions/TransferRestrictions"
require "SaucedCarts/Restrictions/GrabRestrictions"

local TR = SaucedCarts.TransferRestrictions
local sweep = TR._sweepMenuForCartGrabs

-- ----------------------------------------------------------------------------
-- Fixtures
-- ----------------------------------------------------------------------------

-- Distinct function values standing in for the legacy handlers.
local fnGrab = function() end
local fnGrabHalf = function() end
local fnGrabAll = function() end
local fnPushCart = function() end -- our own option's handler — must never match
local fnOldGrab = function() end  -- "pre-hook original" a mod captured early

local function makeCartItem() return { _isCart = true } end
local function makeLootItem() return { _isCart = false } end

local function makeWItem(item)
    return { _class = "IsoWorldInventoryObject", getItem = function() return item end }
end

--- Minimal ISContextMenu stand-in matching the fields the sweep touches.
--- Vanilla's numOptions invariant: numOptions == #options + 1.
local function makeMenu(options)
    local menu = {
        options = options or {},
        optionPool = {},
        _subs = {},
        calcHeight = function() end,
        getSubMenu = function(self, num) return self._subs[num] end,
    }
    for i, opt in ipairs(menu.options) do opt.id = i end
    menu.numOptions = #menu.options + 1
    return menu
end

local function makeOption(name, onSelect, param1)
    return { name = name, onSelect = onSelect, param1 = param1 }
end

--- Run fn with the sweep's environment stubbed: a fake
--- ISWorldObjectContextMenu carrying our handler stand-ins, a table-aware
--- instanceof, an additive safeIsCart, and one entry in legacyOriginals.
--- Always restores, even when fn throws (spy-leak gotcha).
local function withSweepEnv(fn)
    local realISWOCM = _G.ISWorldObjectContextMenu
    local realInstanceof = _G.instanceof
    local realSafeIsCart = SaucedCarts.safeIsCart
    local grabR = SaucedCarts.GrabRestrictions
    local hadOriginal = grabR and grabR.legacyOriginals[fnOldGrab]

    _G.ISWorldObjectContextMenu = {
        onGrabWItem = fnGrab,
        onGrabHalfWItems = fnGrabHalf,
        onGrabAllWItems = fnGrabAll,
    }
    _G.instanceof = function(o, cls) return type(o) == "table" and o._class == cls end
    SaucedCarts.safeIsCart = function(item)
        if type(item) == "table" and item._isCart ~= nil then return item._isCart end
        return realSafeIsCart(item)
    end
    if grabR then grabR.legacyOriginals[fnOldGrab] = true end

    local ok, err = pcall(fn)

    _G.ISWorldObjectContextMenu = realISWOCM
    _G.instanceof = realInstanceof
    SaucedCarts.safeIsCart = realSafeIsCart
    if grabR and not hadOriginal then grabR.legacyOriginals[fnOldGrab] = nil end

    if not ok then error(err) end
end

local tests = {}

-- ----------------------------------------------------------------------------
-- Removal cases
-- ----------------------------------------------------------------------------

tests["sweep_removes_leaked_cart_grab_option"] = function()
    local result
    withSweepEnv(function()
        local menu = makeMenu({
            makeOption("Push Cart", fnPushCart, makeWItem(makeCartItem())),
            makeOption("Grab", fnGrab, makeWItem(makeCartItem())),
        })
        local removed = sweep(menu, 0)
        result = { removed = removed, count = #menu.options,
                   survivor = menu.options[1] and menu.options[1].name,
                   numOptions = menu.numOptions, pooled = #menu.optionPool }
    end)
    if not Assert.equal(result.removed, 1, "one leaked option removed") then return false end
    if not Assert.equal(result.count, 1, "menu compacted to one option") then return false end
    if not Assert.equal(result.survivor, "Push Cart", "our own option survives") then return false end
    if not Assert.equal(result.numOptions, 2, "numOptions invariant (#options + 1) holds") then return false end
    return Assert.equal(result.pooled, 1, "removed option returned to the pool")
end

tests["sweep_matches_by_handler_not_by_label"] = function()
    -- A mod's custom label ("Take Cart (5kg)") defeats name-based removal;
    -- handler identity must not care.
    local removed
    withSweepEnv(function()
        local menu = makeMenu({
            makeOption("Take Cart (5kg)", fnGrab, makeWItem(makeCartItem())),
        })
        removed = sweep(menu, 0)
    end)
    return Assert.equal(removed, 1, "custom-labeled option still swept by identity")
end

tests["sweep_removes_option_wired_to_prehook_original"] = function()
    -- Mods that captured ISWorldObjectContextMenu.onGrabWItem at THEIR file
    -- load hold the pre-hook original — covered via legacyOriginals.
    local removed
    withSweepEnv(function()
        local menu = makeMenu({
            makeOption("Grab", fnOldGrab, makeWItem(makeCartItem())),
        })
        removed = sweep(menu, 0)
    end)
    return Assert.equal(removed, 1, "pre-hook original matched via legacyOriginals")
end

tests["sweep_removes_grab_all_when_every_target_is_a_cart"] = function()
    local removed
    withSweepEnv(function()
        local menu = makeMenu({
            makeOption("Grab all", fnGrabAll,
                { makeWItem(makeCartItem()), makeWItem(makeCartItem()) }),
        })
        removed = sweep(menu, 0)
    end)
    return Assert.equal(removed, 1, "all-cart grab-all removed")
end

tests["sweep_cleans_submenus_one_level_down"] = function()
    local result
    withSweepEnv(function()
        local sub = makeMenu({
            makeOption("Grab", fnGrab, makeWItem(makeCartItem())),
            makeOption("Grab", fnGrab, makeWItem(makeLootItem())),
        })
        local parentOpt = makeOption("Grab...", fnPushCart, nil)
        parentOpt.subOption = 1
        local menu = makeMenu({ parentOpt })
        menu._subs[1] = sub
        local removed = sweep(menu, 0)
        result = { removed = removed, parentCount = #menu.options, subCount = #sub.options }
    end)
    if not Assert.equal(result.removed, 1, "cart entry removed from submenu") then return false end
    if not Assert.equal(result.parentCount, 1, "parent option untouched") then return false end
    return Assert.equal(result.subCount, 1, "non-cart submenu entry survives")
end

tests["sweep_handles_adjacent_leaks_without_skipping"] = function()
    -- Compaction shifts the next option into the removed slot; the sweep must
    -- re-examine that index or every second adjacent leak survives.
    local result
    withSweepEnv(function()
        local menu = makeMenu({
            makeOption("Grab", fnGrab, makeWItem(makeCartItem())),
            makeOption("Grab", fnGrabHalf, { makeWItem(makeCartItem()) }),
            makeOption("Push Cart", fnPushCart, makeWItem(makeCartItem())),
        })
        local removed = sweep(menu, 0)
        result = { removed = removed, count = #menu.options,
                   survivor = menu.options[1] and menu.options[1].name }
    end)
    if not Assert.equal(result.removed, 2, "both adjacent leaks removed") then return false end
    if not Assert.equal(result.count, 1, "only one option left") then return false end
    return Assert.equal(result.survivor, "Push Cart", "the survivor is ours")
end

-- ----------------------------------------------------------------------------
-- Non-removal cases (precision: never touch legitimate options)
-- ----------------------------------------------------------------------------

tests["sweep_leaves_grab_for_ordinary_loot"] = function()
    local removed
    withSweepEnv(function()
        local menu = makeMenu({
            makeOption("Grab", fnGrab, makeWItem(makeLootItem())),
        })
        removed = sweep(menu, 0)
    end)
    return Assert.equal(removed, 0, "a mod's grab option for normal loot is not ours to touch")
end

tests["sweep_leaves_cart_options_with_unrelated_handlers"] = function()
    -- Our own "Push Cart" option targets a cart but uses our handler.
    local removed
    withSweepEnv(function()
        local menu = makeMenu({
            makeOption("Push Cart", fnPushCart, makeWItem(makeCartItem())),
        })
        removed = sweep(menu, 0)
    end)
    return Assert.equal(removed, 0, "cart option with non-legacy handler survives")
end

tests["sweep_leaves_mixed_grab_all_lists"] = function()
    -- Mixed cart+loot list: the menu entry is legitimate for the loot; the
    -- click-time filter in GrabRestrictions handles the cart.
    local removed
    withSweepEnv(function()
        local menu = makeMenu({
            makeOption("Grab all", fnGrabAll,
                { makeWItem(makeCartItem()), makeWItem(makeLootItem()) }),
        })
        removed = sweep(menu, 0)
    end)
    return Assert.equal(removed, 0, "mixed list kept — click-time filter owns that case")
end

tests["sweep_tolerates_hostile_shapes"] = function()
    local results = {}
    withSweepEnv(function()
        results.nilMenu = sweep(nil, 0)
        results.boolMenu = sweep(true, 0) -- createMenu test-mode return
        results.noOptions = sweep({}, 0)
        local menu = makeMenu({
            makeOption("Grab", fnGrab, nil),               -- no target at all
            makeOption("Grab", fnGrab, { }),               -- empty list
            makeOption("Grab", "not a function", makeWItem(makeCartItem())),
        })
        results.hostile = sweep(menu, 0)
        results.hostileCount = #menu.options
    end)
    if not Assert.equal(results.nilMenu, 0, "nil menu is a no-op") then return false end
    if not Assert.equal(results.boolMenu, 0, "boolean (test-mode) return is a no-op") then return false end
    if not Assert.equal(results.noOptions, 0, "empty menu is a no-op") then return false end
    if not Assert.equal(results.hostile, 0, "malformed options are never removed") then return false end
    return Assert.equal(results.hostileCount, 3, "malformed options all left in place")
end

return tests
