--[[
    SaucedCarts/Tests/OfflineCorpseCartExemptionTests.lua
    =====================================================

    A GROUND CART USED FOR CORPSES MUST EARN THE WORLD-CLEANUP EXEMPTION.

    Found on a live dual-client dedi (2026-08-29), not offline: cart 1987885066
    had taken TWO corpse loads and TWO corpse unloads and was still
    ignoreRemoveSandbox=false, i.e. still eligible for the chunk-load cleanup
    filter at IsoGridSquare.java:3311. On that world (keep-list mode,
    HoursForWorldItemRemoval=0) it would be discarded on the next chunk load.

    Why neither existing exemption covered it:

      * the TRANSFER-time exemption hangs off the performCartTransfer
        chokepoint, and the corpse pipeline never goes through it. The load
        side does cartContainer:AddItem(corpseItem) directly in
        CorpseStorage.handleLoadCorpseToCart; the unload side delegates to
        vanilla ISGrabCorpseItem:complete, which does srcContainer:DoRemoveItem
        itself.

      * the FORCE-DROP exemption does not apply either. ISGrabCorpseItem:
        complete does call forceDropHeavyItems, but a cart sitting on the
        ground is not in anyone's hands, so there is nothing there to flag.

    So the corpse feature was the one way to use a cart all day without ever
    marking it player-handled. These tests pin both ends.

    NOTE ON THE UNLOAD HARNESS: GrabCorpseInterceptor self-skips when the
    vanilla ISGrabCorpseItem class is absent (it is, offline) and nothing else
    in the mod requires the module, so this file stubs the class and then
    requires it - making this file deterministically the first and only
    requirer regardless of Kahlua's arbitrary file order.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert
local F = PZTestKit.Fixtures

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/CorpseStorage"
-- The load path funnels through SaucedCarts.performCartTransfer, which
-- lives here. CorpseStorage cannot require it back (CartTransferInterceptor
-- requires CorpseStorage), so the test has to pull it in explicitly.
require "SaucedCarts/CartTransferInterceptor"

local CS = SaucedCarts.CorpseStorage

local TEST_CART_TYPE = "SaucedCarts.TestCorpseExemptCart"
if not SaucedCarts.isRegistered(TEST_CART_TYPE) then
    SaucedCarts.registerCart(TEST_CART_TYPE, {
        name = "TestCorpseExemptCart", capacity = 150, conditionMax = 20,
    })
end

-- ----------------------------------------------------------------------------
-- Fixtures
-- ----------------------------------------------------------------------------

local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(item)
    if type(item) == "table" and item._type == "InventoryContainer"
        and item.getFullType and (item:getFullType() or ""):find("^SaucedCarts%.") then
        return true
    end
    return origSafeIsCart(item)
end

local function makeCart(opts)
    opts = opts or {}
    local cart = F.item({ id = opts.id, fullType = TEST_CART_TYPE, weight = 2.0 })
    cart._type = "InventoryContainer"
    cart._innerContainer = F.container({
        containingItem = cart, typeName = "ShoppingCart", capacity = 150,
    })
    cart.getItemContainer = function(self) return self._innerContainer end
    return cart
end

--- A cart sitting in the world with NO exemption - what WorldSpawning leaves,
--- and what a player finds and uses in place.
local function makeGroundCart(opts)
    local cart = makeCart(opts)
    local sq = F.square(0, 0, 0)
    sq:AddWorldInventoryItem(cart, 0.5, 0.5, 0, false)
    return cart, sq
end

--- nil = no world item at all (equipped); else the flag's value.
local function exemptState(cart)
    local wi = cart.getWorldItem and cart:getWorldItem()
    if not wi then return nil end
    return wi._private.ignoreRemoveSandbox == true
end

local function makeCorpseItem(id)
    local it = F.item({ id = id, fullType = "Base.CorpseMale", weight = 60.0 })
    it.isHumanCorpse  = function() return true end
    it.isAnimalCorpse = function() return false end
    return it
end

local function makeDeadBody(sq, corpseItem)
    local priv = { invalidated = 0 }
    local b = { _type = "IsoDeadBody", _private = priv }
    b.getID             = function() return 42 end
    b.getObjectIDAsLong = function() return 1042 end
    b.getItem           = function() return corpseItem end
    b.getSquare         = function() return sq end
    b.invalidateCorpse  = function() priv.invalidated = priv.invalidated + 1 end
    return b
end

--- Sandbox with the corpse feature ON and a real rot threshold, so
--- isEnabled() passes and _getRotThresholds() returns a number.
local function withSandbox(fn)
    local origVars = _G.SandboxVars
    local origOpts = _G.SandboxOptions
    local origIO   = _G.instanceof
    _G.SandboxVars = { SaucedCarts = { EnableMod = true, EnableCorpseStorage = true } }
    _G.SandboxOptions = {
        instance = {
            getOptionByName = function(_, name)
                if name == "HoursForCorpseRemoval" then
                    return { getValue = function() return 24 end }
                end
                return nil
            end,
        },
    }
    _G.instanceof = function(obj, cls)
        if obj == nil then return false end
        if type(obj) == "table" and obj._type == cls then return true end
        if type(obj) == "table" and cls == "IsoGameCharacter" and obj._type == "IsoPlayer" then
            return false
        end
        if origIO then return origIO(obj, cls) end
        return false
    end
    local ok, err = pcall(fn)
    _G.SandboxVars = origVars
    _G.SandboxOptions = origOpts
    _G.instanceof = origIO
    if not ok then error(err) end
end

local tests = {}

-- ============================================================================
-- LOAD SIDE - CorpseStorage.handleLoadCorpseToCart
-- ============================================================================

tests["loading_a_corpse_exempts_a_ground_cart"] = function()
    local result
    withSandbox(function()
        local cart, sq = makeGroundCart({ id = 7001 })
        local corpse = makeCorpseItem(7101)
        local body = makeDeadBody(sq, corpse)

        if exemptState(cart) ~= false then error("precondition: cart should start unflagged") end

        local player = F.player({ square = sq })
        player.isDraggingCorpse   = function() return true end
        player.getGrapplingTarget = function() return body end
        player.setDoGrappleLetGo  = function() end
        player:getInventory():AddItem(cart)

        sq.removeCorpse = function() end

        local origGetCell = _G.getCell
        _G.getCell = function()
            return {
                getZombieList = function() return { size = function() return 0 end, get = function() return nil end } end,
                getGridSquare = function(_, x, y, z)
                    return (x == 0 and y == 0 and z == 0) and sq or nil
                end,
            }
        end
        sq.getDeadBodys = function()
            return { size = function() return 1 end, get = function() return body end }
        end

        CS.handleLoadCorpseToCart(player, {
            cartId = cart:getID(), ghostId = 1042, ghostKind = "body",
            ghostX = 0, ghostY = 0, ghostZ = 0,
        })

        _G.getCell = origGetCell
        result = { landed = cart:getItemContainer():contains(corpse), exempt = exemptState(cart) }
    end)

    if not Assert.isTrue(result.landed,
        "guard: the corpse actually reached the cart") then return false end
    return Assert.isTrue(result.exempt,
        "a ground cart loaded with a corpse is exempt from world cleanup")
end

tests["loading_a_corpse_repaints_the_cart"] = function()
    -- The second concern the corpse path was silently missing. Before the
    -- convergence nothing repainted the cart on a corpse load, and the live
    -- dedi log shows the consequence directly: GroundVisualReconciler's ~15s
    -- sweep healing the cart afterwards ("healed drifted ground cart
    -- 1987885066 -> ShoppingCartPartialModel"). Routing through
    -- performCartTransfer means the chokepoint repaints it immediately, and
    -- the sweep goes back to being a safety net rather than the mechanism.
    local painted
    withSandbox(function()
        local cart, sq = makeGroundCart({ id = 7005 })
        local corpse = makeCorpseItem(7106)
        local body = makeDeadBody(sq, corpse)

        local player = F.player({ square = sq })
        player.isDraggingCorpse   = function() return true end
        player.getGrapplingTarget = function() return body end
        player.setDoGrappleLetGo  = function() end
        player:getInventory():AddItem(cart)
        sq.removeCorpse = function() end

        local origGetCell = _G.getCell
        _G.getCell = function()
            return {
                getZombieList = function() return { size = function() return 0 end, get = function() return nil end } end,
                getGridSquare = function(_, x, y, z)
                    return (x == 0 and y == 0 and z == 0) and sq or nil
                end,
            }
        end
        sq.getDeadBodys = function()
            return { size = function() return 1 end, get = function() return body end }
        end

        -- Spy that always restores, even if the handler throws.
        local origVisual = SaucedCarts.updateCartVisual
        local seen = {}
        SaucedCarts.updateCartVisual = function(c) seen[#seen + 1] = c end
        local ok = pcall(function()
            CS.handleLoadCorpseToCart(player, {
                cartId = cart:getID(), ghostId = 1042, ghostKind = "body",
                ghostX = 0, ghostY = 0, ghostZ = 0,
            })
        end)
        SaucedCarts.updateCartVisual = origVisual
        _G.getCell = origGetCell
        if not ok then error("handler threw") end

        painted = false
        for _, c in ipairs(seen) do if c == cart then painted = true end end
    end)

    return Assert.isTrue(painted,
        "the cart is repainted at load time, not 15s later by the sweep")
end

tests["loading_into_an_equipped_cart_has_no_world_item_to_flag"] = function()
    -- Precision + fail-safe: markDropPersistent must no-op on a cart with no
    -- world item rather than throw inside the handler's pcall, which would
    -- abort the load.
    local result
    withSandbox(function()
        local cart = makeCart({ id = 7002 })   -- never placed in the world
        local sq = F.square(0, 0, 0)
        local corpse = makeCorpseItem(7102)
        local body = makeDeadBody(sq, corpse)

        local player = F.player({ square = sq })
        player.isDraggingCorpse   = function() return true end
        player.getGrapplingTarget = function() return body end
        player.setDoGrappleLetGo  = function() end
        player:getInventory():AddItem(cart)
        sq.removeCorpse = function() end

        local origGetCell = _G.getCell
        _G.getCell = function()
            return {
                getZombieList = function() return { size = function() return 0 end, get = function() return nil end } end,
                getGridSquare = function(_, x, y, z)
                    return (x == 0 and y == 0 and z == 0) and sq or nil
                end,
            }
        end
        sq.getDeadBodys = function()
            return { size = function() return 1 end, get = function() return body end }
        end

        local ok = pcall(function()
            CS.handleLoadCorpseToCart(player, {
                cartId = cart:getID(), ghostId = 1042, ghostKind = "body",
                ghostX = 0, ghostY = 0, ghostZ = 0,
            })
        end)
        _G.getCell = origGetCell
        result = { ok = ok, landed = cart:getItemContainer():contains(corpse), exempt = exemptState(cart) }
    end)

    if not Assert.isTrue(result.ok, "handler did not throw") then return false end
    if not Assert.isTrue(result.landed, "the corpse still loaded") then return false end
    return Assert.isNil(result.exempt, "equipped cart has no world item - nothing to flag")
end

-- ============================================================================
-- UNLOAD SIDE - GrabCorpseInterceptor wrapping ISGrabCorpseItem:complete
-- ============================================================================
-- Stub the vanilla class, then require the interceptor. See the header note:
-- nothing else in the mod requires this module, so this is deterministic.

local vanillaCompleteCalls = 0
_G.ISGrabCorpseItem = {
    complete = function() vanillaCompleteCalls = vanillaCompleteCalls + 1; return true end,
}
require "SaucedCarts/GrabCorpseInterceptor"

local function runGrabComplete(cart, corpse, character)
    local action = {
        item = corpse,
        character = character,
    }
    return ISGrabCorpseItem.complete(action)
end

tests["grab_interceptor_installed_over_the_stub"] = function()
    -- Guard the harness itself: if the hook never installed, every unload test
    -- below would vacuously pass by calling the stub directly.
    return Assert.isTrue(ISGrabCorpseItem._SaucedCarts_grabHookInstalled == true,
        "interceptor wrapped the stubbed vanilla class")
end

tests["unloading_a_corpse_exempts_a_ground_cart"] = function()
    -- Fresh corpse (age 0 < skeletonAt 24) so the interceptor delegates to
    -- vanilla - the COMMON path, and the one that never touches
    -- performCartTransfer.
    local result
    withSandbox(function()
        local cart = makeGroundCart({ id = 7003 })
        local corpse = makeCorpseItem(7103)
        cart:getItemContainer():AddItem(corpse)
        corpse.getContainer = function() return cart:getItemContainer() end

        if exemptState(cart) ~= false then error("precondition: cart should start unflagged") end

        local before = vanillaCompleteCalls
        runGrabComplete(cart, corpse, F.player({ square = F.square(0, 0, 0) }))
        result = { exempt = exemptState(cart), delegated = (vanillaCompleteCalls > before) }
    end)

    if not Assert.isTrue(result.delegated,
        "guard: a fresh corpse still delegates to vanilla's complete") then return false end
    return Assert.isTrue(result.exempt,
        "taking a corpse out of a ground cart marks it player-handled")
end

tests["unload_exempts_even_on_the_rotted_silent_drop_path"] = function()
    -- Past skeletonAt the interceptor handles it itself and never calls
    -- vanilla. The exemption must not live on the delegating branch only.
    local result
    withSandbox(function()
        local cart = makeGroundCart({ id = 7004 })
        local corpse = makeCorpseItem(7104)
        cart:getItemContainer():AddItem(corpse)
        corpse.getContainer = function() return cart:getItemContainer() end
        -- Stamp it old enough to be past the 24h threshold.
        corpse:getModData()[CS._CORPSE_DEATHTIME_KEY] = -1000

        local before = vanillaCompleteCalls
        runGrabComplete(cart, corpse, F.player({ square = F.square(0, 0, 0) }))
        result = { exempt = exemptState(cart), delegated = (vanillaCompleteCalls > before) }
    end)

    if not Assert.isFalse(result.delegated,
        "guard: a rotted corpse is silent-dropped, not delegated") then return false end
    return Assert.isTrue(result.exempt,
        "the silent-drop branch flags the cart too")
end

tests["unload_from_a_non_cart_container_is_untouched"] = function()
    -- Precision: crates/dumpsters/coffins keep vanilla behaviour end to end.
    local result
    withSandbox(function()
        local crate = F.container({ typeName = "crate", capacity = 50 })
        crate.getContainingItem = function() return nil end
        local corpse = makeCorpseItem(7105)
        crate:AddItem(corpse)
        corpse.getContainer = function() return crate end

        local before = vanillaCompleteCalls
        runGrabComplete(nil, corpse, F.player({ square = F.square(0, 0, 0) }))
        result = { delegated = (vanillaCompleteCalls > before) }
    end)
    return Assert.isTrue(result.delegated,
        "a non-cart source goes straight to vanilla")
end

PZTestKit.registerTests("offline_corpse_cart_exemption", tests)

return tests
