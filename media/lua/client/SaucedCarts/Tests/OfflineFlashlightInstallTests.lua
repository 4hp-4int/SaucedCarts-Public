--[[
    SaucedCarts — Flashlight install/uninstall tests
    ================================================

    Two regressions live here.

    1. "Install Flashlight" ate a player's M1911.

       The candidate filter accepted anything where getLightDistance() > 0 or
       isTorchCone(). HandWeapon delegates BOTH getters to its mounted part:

         isTorchCone()     -> activeLight.isTorchCone() || super   (HandWeapon.java:2600)
         getLightDistance()-> activeLight.getLightDistance()       (HandWeapon.java:2610)

       Base.GunLight is a WeaponPart with LightDistance = 15, so a pistol
       wearing one looked exactly like a flashlight. The install path then
       DoRemoveItem'd the whole gun. These tests pin the discriminator.

    2. There was no way back out. Upgrades.removeFlashlight now tears the
       upgrade down and reports what to hand back, so an accidental install
       is recoverable.
]]

if isServer() and not isClient() then return end

if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/CartData"
require "SaucedCarts/Upgrades"

-- ============================================================================
-- INSTANCEOF SHIM
-- ============================================================================
-- Mocks declare their Java class in _class / _classes. Anything unrecognized
-- falls through to a pre-existing instanceof so other suites keep working.

local function withInstanceof(fn)
    local orig = _G.instanceof
    _G.instanceof = function(obj, class)
        if type(obj) == "table" then
            if obj._class == class then return true end
            if obj._classes and obj._classes[class] then return true end
            if obj._class ~= nil or obj._classes ~= nil then return false end
        end
        if orig then return orig(obj, class) end
        return false
    end
    local ok, err = pcall(fn)
    _G.instanceof = orig
    if not ok then error(err) end
end

-- ============================================================================
-- ITEM MOCKS
-- ============================================================================

local nextId = 9000
local function takeId()
    nextId = nextId + 1
    return nextId
end

--- A plain handheld light (Base.Torch shape).
local function makeLight(opts)
    opts = opts or {}
    local tags = opts.tags or {}
    return {
        _class = opts.class or "DrainableComboItem",
        _id = takeId(),
        _tags = tags,
        getFullType        = function(self) return opts.fullType or "Base.Torch" end,
        getDisplayName     = function(self) return opts.name or "Flashlight" end,
        getID              = function(self) return self._id end,
        getTexture         = function(self) return nil end,
        hasTag             = function(self, t) return self._tags[t] == true end,
        getDisplayCategory = function(self) return opts.category end,
        isTorchCone        = function(self) return opts.torchCone == true end,
        getLightDistance   = function(self) return opts.lightDistance or 0 end,
        getLightStrength   = function(self) return opts.lightStrength or 2.0 end,
        getTorchDot        = function(self) return opts.torchDot or 0.66 end,
        getCurrentUsesFloat= function(self) return opts.charge or 0 end,
    }
end

--- A HandWeapon. `mountedLight` mimics an attached Base.GunLight: every light
--- getter delegates to it, exactly as the Java does.
local function makeWeapon(opts)
    opts = opts or {}
    local light = opts.mountedLight
    return {
        _class = "HandWeapon",
        _classes = { HandWeapon = true, InventoryItem = true },
        _id = takeId(),
        _tags = opts.tags or {},
        getFullType        = function(self) return opts.fullType or "Base.M1911" end,
        getDisplayName     = function(self) return opts.name or "M1911" end,
        getID              = function(self) return self._id end,
        getTexture         = function(self) return nil end,
        hasTag             = function(self, t) return self._tags[t] == true end,
        getDisplayCategory = function(self) return opts.category or "Weapon" end,
        getActiveLight     = function(self) return light end,
        -- Delegating getters, mirroring HandWeapon.java:2600/2610
        isTorchCone        = function(self) return light ~= nil or opts.torchCone == true end,
        getLightDistance   = function(self)
            if light then return light.lightDistance end
            return opts.lightDistance or 0
        end,
    }
end

--- Cart mock: enough surface for install -> remove round trips.
local function makeCart()
    local modData = {}
    return {
        _class = "InventoryContainer",
        _id = takeId(),
        _activated = false,
        _lightStrength = 0,
        _lightDistance = 0,
        _torchCone = false,
        _canBeActivated = false,
        getFullType     = function(self) return "SaucedCarts.ShoppingCart" end,
        getDisplayName  = function(self) return "Shopping Cart" end,
        getID           = function(self) return self._id end,
        getModData      = function(self) return modData end,
        setActivated    = function(self, v) self._activated = v end,
        setLightStrength= function(self, v) self._lightStrength = v end,
        setLightDistance= function(self, v) self._lightDistance = v end,
        setTorchCone    = function(self, v) self._torchCone = v end,
        setCanBeActivated = function(self, v) self._canBeActivated = v end,
    }
end

-- Loading the menu pulls in the client context-menu module; the predicate we
-- want is re-exported from it.
local FlashlightMenu = require "SaucedCarts/ContextMenu/FlashlightMenu"
local isInstallable = FlashlightMenu.isInstallableFlashlight

-- The production tag check passes a resolved ItemTag OBJECT to hasTag —
-- never a string; hasTag(String) has no Java implementation and the Kahlua
-- dispatch error escapes pcall (the 2026-08-07 IDcard crash). Offline there
-- are no ItemTag/ResourceLocation globals, so inject a non-string sentinel
-- and key mock _tags tables off it.
local FLASH_TAG = { id = "base:flashlight (test sentinel)" }
FlashlightMenu._setFlashlightTag(FLASH_TAG)

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

-- ---------------------------------------------------------------------------
-- The reported bug
-- ---------------------------------------------------------------------------

tests["pistol_with_mounted_gunlight_is_not_a_flashlight"] = function()
    local result
    withInstanceof(function()
        local gun = makeWeapon({
            fullType = "Base.M1911",
            name = "M1911",
            mountedLight = { lightDistance = 15 },  -- Base.GunLight
        })
        -- Sanity: the gun really does look like a light through the getters
        -- the old filter used. If this stops being true the test is vacuous.
        Assert.isTrue(gun:isTorchCone(), "mounted light makes isTorchCone true")
        Assert.isTrue(gun:getLightDistance() > 0, "mounted light makes getLightDistance > 0")
        result = isInstallable(gun)
    end)
    return Assert.isFalse(result, "pistol with mounted GunLight is rejected")
end

tests["bare_weapon_is_not_a_flashlight"] = function()
    local result
    withInstanceof(function()
        result = isInstallable(makeWeapon({ fullType = "Base.Axe", name = "Axe" }))
    end)
    return Assert.isFalse(result, "weapon with no light is rejected")
end

tests["weapon_without_getActiveLight_is_rejected"] = function()
    -- Build where HandWeapon.getActiveLight isn't exposed: we can't tell a
    -- light-carrying weapon from a plain one, and the item gets destroyed on
    -- install, so the safe answer is no.
    local result
    withInstanceof(function()
        local gun = makeWeapon({ mountedLight = { lightDistance = 15 } })
        gun.getActiveLight = nil
        result = isInstallable(gun)
    end)
    return Assert.isFalse(result, "weapon is rejected when getActiveLight is unavailable")
end

-- ---------------------------------------------------------------------------
-- Real flashlights still pass
-- ---------------------------------------------------------------------------

tests["vanilla_torch_is_installable"] = function()
    local result
    withInstanceof(function()
        result = isInstallable(makeLight({
            fullType = "Base.Torch", category = "LightSource",
            torchCone = true, lightDistance = 25,
            tags = { [FLASH_TAG] = true },
        }))
    end)
    return Assert.isTrue(result, "Base.Torch is installable")
end

tests["penlight_is_installable"] = function()
    local result
    withInstanceof(function()
        result = isInstallable(makeLight({ fullType = "Base.PenLight" }))
    end)
    return Assert.isTrue(result, "Base.PenLight matches by explicit type")
end

tests["modded_light_matches_by_flashlight_tag"] = function()
    -- No known type, no LightSource category, no cone/distance getters worth
    -- anything — the base:flashlight tag alone has to carry it.
    local result
    withInstanceof(function()
        result = isInstallable(makeLight({
            fullType = "SomeMod.TacticalLamp",
            category = "Misc",
            tags = { [FLASH_TAG] = true },
        }))
    end)
    return Assert.isTrue(result, "tagged modded light is installable")
end

tests["tag_check_never_passes_a_string"] = function()
    -- Regression: the 2026-08-07 crash. hasTag(String) does not exist in
    -- Java; Kahlua's missing-overload RuntimeException escapes pcall and
    -- killed the context menu on a Base.IDcard mid-sweep. This mock throws
    -- on a string argument the way the real dispatch does — the sweep must
    -- neither crash nor match.
    local sawString = false
    local item = makeLight({ fullType = "Base.IDcard", category = "Item" })
    item.hasTag = function(self, t)
        if type(t) == "string" then
            sawString = true
            error("No implementation found for function: hasTag(String)")
        end
        return false
    end
    local result
    withInstanceof(function() result = isInstallable(item) end)
    if not Assert.isFalse(sawString,
        "production code must never pass a string to hasTag") then
        return false
    end
    return Assert.isFalse(result, "untagged Literature-shaped item rejected")
end

tests["modded_light_matches_by_LightSource_category"] = function()
    local result
    withInstanceof(function()
        result = isInstallable(makeLight({
            fullType = "SomeMod.Lantern", category = "LightSource",
        }))
    end)
    return Assert.isTrue(result, "LightSource category is installable")
end

tests["untagged_light_falls_back_to_cone_plus_distance"] = function()
    local result
    withInstanceof(function()
        result = isInstallable(makeLight({
            fullType = "SomeMod.OldLamp", category = "Misc",
            torchCone = true, lightDistance = 12,
        }))
    end)
    return Assert.isTrue(result, "cone + distance fallback still works")
end

-- ---------------------------------------------------------------------------
-- Things that emit light but aren't flashlights
-- ---------------------------------------------------------------------------

tests["lighter_is_not_a_flashlight"] = function()
    -- Base.Lighter: LightDistance = 5 but TorchCone = false. The old filter
    -- accepted it on distance alone; requiring both keeps it out.
    local result
    withInstanceof(function()
        result = isInstallable(makeLight({
            fullType = "Base.Lighter", category = "Misc",
            torchCone = false, lightDistance = 5,
        }))
    end)
    return Assert.isFalse(result, "lighter is rejected")
end

tests["cart_is_not_a_flashlight"] = function()
    -- A cart with the flashlight upgrade emits light and would otherwise
    -- qualify to be installed into another cart.
    local result
    withInstanceof(function()
        local cart = makeCart()
        cart.isTorchCone = function() return true end
        cart.getLightDistance = function() return 15 end
        cart.hasTag = function() return false end
        result = isInstallable(cart)
    end)
    return Assert.isFalse(result, "InventoryContainer is rejected")
end

tests["nil_item_is_not_a_flashlight"] = function()
    local result
    withInstanceof(function() result = isInstallable(nil) end)
    return Assert.isFalse(result, "nil is rejected")
end

-- ---------------------------------------------------------------------------
-- Install -> remove round trip
-- ---------------------------------------------------------------------------

tests["remove_returns_original_type_and_charge"] = function()
    local cart = makeCart()
    local torch = makeLight({
        fullType = "Base.Torch", name = "Flashlight",
        torchCone = true, lightDistance = 25, lightStrength = 2.0,
        charge = 0.42,
    })

    if not Assert.isTrue(SaucedCarts.Upgrades.installFlashlight(cart, torch), "install succeeds") then
        return false
    end
    if not Assert.isTrue(SaucedCarts.Upgrades.hasFlashlight(cart), "cart reports flashlight") then
        return false
    end

    local data, charge = SaucedCarts.Upgrades.removeFlashlight(cart)
    if not Assert.isTrue(data ~= nil, "remove reports the stored data") then return false end
    if not Assert.equal("Base.Torch", data.originalType, "original type is returned") then return false end
    if not Assert.equal(0.42, charge, "battery charge is returned") then return false end
    return Assert.isFalse(SaucedCarts.Upgrades.hasFlashlight(cart), "upgrade is gone")
end

tests["remove_clears_all_flashlight_moddata"] = function()
    local cart = makeCart()
    SaucedCarts.Upgrades.installFlashlight(cart, makeLight({ torchCone = true, lightDistance = 25, charge = 1.0 }))
    SaucedCarts.Upgrades.setLightActive(cart, true)

    SaucedCarts.Upgrades.removeFlashlight(cart)

    local md = cart:getModData()
    if not Assert.isTrue(md.SaucedCarts_hasFlashlight == nil, "hasFlashlight cleared") then return false end
    if not Assert.isTrue(md.SaucedCarts_flashlightData == nil, "flashlightData cleared") then return false end
    if not Assert.isTrue(md.SaucedCarts_batteryCharge == nil, "batteryCharge cleared") then return false end
    if not Assert.isTrue(md.SaucedCarts_isLightActive == nil, "isLightActive cleared") then return false end
    -- upgradeKey must be nil so updateCartVisual sees a change and drops back
    -- to the base model instead of keeping the flashlight mesh.
    return Assert.isTrue(md.SaucedCarts_upgradeKey == nil, "upgradeKey cleared")
end

tests["remove_stops_light_emission"] = function()
    local cart = makeCart()
    SaucedCarts.Upgrades.installFlashlight(cart, makeLight({ torchCone = true, lightDistance = 25, charge = 1.0 }))
    SaucedCarts.Upgrades.enableCartLight(cart)
    if not Assert.isTrue(cart._activated, "light is on before removal") then return false end

    SaucedCarts.Upgrades.removeFlashlight(cart)

    if not Assert.isFalse(cart._activated, "cart deactivated") then return false end
    if not Assert.equal(0, cart._lightDistance, "light distance zeroed") then return false end
    return Assert.isFalse(cart._canBeActivated, "activation disabled")
end

tests["remove_on_cart_without_flashlight_is_a_noop"] = function()
    local cart = makeCart()
    local data, charge = SaucedCarts.Upgrades.removeFlashlight(cart)
    if not Assert.isTrue(data == nil, "no data returned") then return false end
    return Assert.equal(0, charge, "no charge returned")
end

tests["remove_is_idempotent"] = function()
    -- Double-perform safety: the MP client and server VMs both reach perform(),
    -- and a stale action can re-enter. The second call must not report another
    -- item to hand back or the player gets two flashlights.
    local cart = makeCart()
    SaucedCarts.Upgrades.installFlashlight(cart, makeLight({ torchCone = true, lightDistance = 25, charge = 0.5 }))

    local data1 = SaucedCarts.Upgrades.removeFlashlight(cart)
    local data2, charge2 = SaucedCarts.Upgrades.removeFlashlight(cart)

    if not Assert.isTrue(data1 ~= nil, "first removal yields data") then return false end
    if not Assert.isTrue(data2 == nil, "second removal yields nothing") then return false end
    return Assert.equal(0, charge2, "second removal yields no charge")
end

tests["canRemoveFlashlight_tracks_install_state"] = function()
    local cart = makeCart()
    if not Assert.isFalse(SaucedCarts.Upgrades.canRemoveFlashlight(cart), "cannot remove when none installed") then
        return false
    end
    SaucedCarts.Upgrades.installFlashlight(cart, makeLight({ torchCone = true, lightDistance = 25 }))
    if not Assert.isTrue(SaucedCarts.Upgrades.canRemoveFlashlight(cart), "can remove once installed") then
        return false
    end
    SaucedCarts.Upgrades.removeFlashlight(cart)
    return Assert.isFalse(SaucedCarts.Upgrades.canRemoveFlashlight(cart), "cannot remove again")
end

tests["reinstall_after_remove_is_allowed"] = function()
    -- canInstallFlashlight gates on hasFlashlight; if removal left any residue
    -- the cart would be permanently un-upgradeable.
    local cart = makeCart()
    SaucedCarts.Upgrades.installFlashlight(cart, makeLight({ torchCone = true, lightDistance = 25 }))
    SaucedCarts.Upgrades.removeFlashlight(cart)

    if not Assert.isTrue(SaucedCarts.Upgrades.canInstallFlashlight(cart), "cart accepts a new flashlight") then
        return false
    end
    local second = makeLight({ fullType = "Base.HandTorch", name = "Small Flashlight", lightDistance = 15 })
    if not Assert.isTrue(SaucedCarts.Upgrades.installFlashlight(cart, second), "reinstall succeeds") then
        return false
    end
    local data = SaucedCarts.Upgrades.getFlashlightData(cart)
    return Assert.equal("Base.HandTorch", data.originalType, "second install overwrote the stored type")
end

return tests
