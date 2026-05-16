--[[
    SaucedCarts — Right-click "Unequip" duplicates the cart (MP)
    ============================================================

    Player report: right-click a held cart → Unequip; the cart briefly
    enters inventory then drops as TWO. Friend: "unequipped it and it
    duplicated an exact copy in place."

    Root cause: ContainerRestrictions hooks ISUnequipAction:complete in a
    SHARED file to force-drop carts. In MP the timed-action lifecycle runs
    complete() on BOTH the client and the server; each runs the hook and
    calls square:AddWorldInventoryItem(item, ..., true) → two world carts.
    The mod already has a server-authoritative drop path (requestInstantDrop,
    used by InstantDrop.handle) but the unequip hook never used it.

    Fix: on a MP client the unequip hook must DELEGATE to the server
    (requestInstantDrop) and NOT create the world item locally; the SP /
    dedicated-server path must be idempotent (skip if the cart is already a
    world item) so a double complete() can't make two.

    These tests assert the MP client never spawns a world cart on unequip
    (it delegates) and that double-complete stays at one. Pre-fix the client
    branch calls AddWorldInventoryItem → fail.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/ContainerRestrictions"

-- ----------------------------------------------------------------------------
-- Mocks
-- ----------------------------------------------------------------------------

local function makeSquare()
    local sq = { _x = 10, _y = 20, _z = 0, _addWorldCount = 0 }
    sq.getX = function(self) return self._x end
    sq.getY = function(self) return self._y end
    sq.getZ = function(self) return self._z end
    -- The duplication primitive. On a MP client this must NEVER be called
    -- (the server does the authoritative drop).
    sq.AddWorldInventoryItem = function(self, item)
        self._addWorldCount = self._addWorldCount + 1
        return item
    end
    return sq
end

local function makeInventory()
    local inv = { _items = {} }
    inv.AddItem = function(self, it) table.insert(self._items, it); return it end
    inv.Remove = function(self, it)
        for i, x in ipairs(self._items) do
            if x == it then table.remove(self._items, i); return end
        end
    end
    inv.contains = function(self, it)
        for _, x in ipairs(self._items) do if x == it then return true end end
        return false
    end
    return inv
end

local function makeCart()
    local md = {}
    local item = {
        _id = 9001, _type = "InventoryContainer",
        _fullType = "SaucedCarts.ShoppingCart", _worldItem = nil,
    }
    item.getID = function(self) return self._id end
    item.getFullType = function(self) return self._fullType end
    item.getModData = function(self) return md end
    item.getConditionMax = function(self) return 100 end
    item.getCondition = function(self) return 100 end
    item.getWorldItem = function(self) return self._worldItem end
    item.setWorldItem = function(self, w) self._worldItem = w end
    return item
end

local function makeCharacter(square, inv)
    local ch = { _type = "IsoPlayer", _vars = {} }
    ch.getOnlineID = function(self) return 5 end          -- MP client → truthy
    ch.getCurrentSquare = function(self) return square end
    ch.getInventory = function(self) return inv end
    ch.removeFromHands = function(self) end
    ch.setVariable = function(self, k, v) self._vars[k] = v end
    ch.getVariableString = function(self, k) return self._vars[k] end
    return ch
end

-- safeIsCart must accept the Lua-table cart (additive shim, same as the
-- sibling deposit tests).
local origSafeIsCart = SaucedCarts.safeIsCart
SaucedCarts.safeIsCart = function(it)
    if type(it) == "table" and it._type == "InventoryContainer"
        and it._fullType and it._fullType:find("^SaucedCarts") then
        return true
    end
    return origSafeIsCart(it)
end

-- Install the ISUnequipAction.complete hook the way the game does
-- (OnGameStart). Provide just enough container-metatable surface that
-- initContainerRestrictions returns gracefully instead of throwing and
-- aborting the OnGameStart listener before initUnequipHook runs.
local hooksInstalled = false
local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true
    if not __classmetatables then
        __classmetatables = setmetatable({}, {
            __index = function() return { __index = {} } end,
        })
    end
    if not ItemContainer then ItemContainer = { class = "ItemContainer" } end
    -- Per-listener isolation: a plain triggerEvent aborts the whole chain if
    -- an earlier mod listener throws offline.
    local evt = Events and Events.OnGameStart
    if evt and evt._listeners then
        for _, fn in ipairs(evt._listeners) do pcall(fn) end
    end
end

-- Spy on the server-delegation call.
local function withNetworkSpy(fn)
    local orig = SaucedCarts.Network.sendToServer
    local sent = {}
    SaucedCarts.Network.sendToServer = function(player, cmd, args)
        table.insert(sent, { cmd = cmd, args = args })
    end
    local ok, err = pcall(fn, sent)
    SaucedCarts.Network.sendToServer = orig
    if not ok then error(err) end
end

local function sentCmd(sent, cmd)
    for _, s in ipairs(sent) do if s.cmd == cmd then return true end end
    return false
end

-- Stub the heavy deps the pre-fix local-drop path touches so it actually
-- REACHES square:AddWorldInventoryItem. Without this the mock cart makes
-- the drop pcall throw early and the dupe primitive is never exercised —
-- the test would pass pre-fix for the wrong reason.
local function withDropEnv(fn)
    local D = SaucedCarts.Durability
    local origApply = D and D.applyAccumulatedDamage
    local origVisual = SaucedCarts.updateCartVisual
    local origSend = _G.sendRemoveItemFromContainer
    if D then D.applyAccumulatedDamage = function() return 100 end end
    SaucedCarts.updateCartVisual = function() end
    _G.sendRemoveItemFromContainer = function() end
    local ok, err = pcall(fn)
    if D then D.applyAccumulatedDamage = origApply end
    SaucedCarts.updateCartVisual = origVisual
    _G.sendRemoveItemFromContainer = origSend
    if not ok then error(err) end
end

-- Invoke the hooked complete() with a minimal action table (avoids
-- ISUnequipAction:new's hotbar wiring; still exercises the wrapped fn).
local function runHookedUnequip(character, cart, times)
    withDropEnv(function()
        for _ = 1, times do
            local action = setmetatable({ character = character, item = cart },
                { __index = ISUnequipAction })
            ISUnequipAction.complete(action)
        end
    end)
end

local function hookReady()
    local cr = SaucedCarts.ContainerRestrictions
    return cr and cr.isUnequipHookInitialized and cr.isUnequipHookInitialized()
end

-- ----------------------------------------------------------------------------
-- Tests  (kit default: isClient()=true, isServer()=false → an MP client)
-- ----------------------------------------------------------------------------

local tests = {}

tests["unequip_mp_client_delegates_and_spawns_no_world_cart"] = function()
    installHooks()
    if not hookReady() then
        return PZTestKit.skip("ISUnequipAction hook unavailable (no vanilla_requires PZ install)")
    end
    local sq = makeSquare()
    local inv = makeInventory()
    local cart = makeCart()
    inv:AddItem(cart)
    local chr = makeCharacter(sq, inv)

    local sawRequest
    withNetworkSpy(function(sent)
        runHookedUnequip(chr, cart, 1)
        sawRequest = sentCmd(sent, "requestInstantDrop")
    end)

    if not Assert.equal(sq._addWorldCount, 0,
        "MP client must NOT spawn a world cart on unequip (got "
        .. sq._addWorldCount .. ")") then
        return false
    end
    if not Assert.isTrue(sawRequest,
        "MP client delegates the drop via requestInstantDrop") then
        return false
    end
    return Assert.isTrue(inv:contains(cart),
        "cart left in inventory for server-authoritative drop (no local tear-out)")
end

-- Models the MP client+server dual execution of the shared hook: complete()
-- runs twice. The client must still never create a local world cart.
tests["unequip_double_complete_no_duplicate_world_cart"] = function()
    installHooks()
    if not hookReady() then
        return PZTestKit.skip("ISUnequipAction hook unavailable (no vanilla_requires PZ install)")
    end
    local sq = makeSquare()
    local inv = makeInventory()
    local cart = makeCart()
    inv:AddItem(cart)
    local chr = makeCharacter(sq, inv)

    withNetworkSpy(function()
        runHookedUnequip(chr, cart, 2)
    end)

    return Assert.equal(sq._addWorldCount, 0,
        "double complete() still spawns zero world carts on the client (got "
        .. sq._addWorldCount .. ")")
end

return tests
