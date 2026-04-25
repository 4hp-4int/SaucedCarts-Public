-- ============================================================================
-- SaucedCarts/GrabCorpseInterceptor.lua
-- ============================================================================
-- PURPOSE: Wrap vanilla `ISGrabCorpseItem:complete` so right-click "Grab"
--          on a corpse INSIDE A SAUCEDCART silent-drops the item when its
--          effective age is past the rot-removal threshold. Without this
--          hook, the unload path our `CartTransferInterceptor` knows
--          about (drag-to-ground via `ISInventoryTransferAction`) is
--          bypassed entirely, and vanilla's `pickUpCorpseItem` happily
--          rematerializes a fully-rotted body.
--
--          Only intercepts when:
--            (a) sandbox feature is enabled
--            (b) the source container's owner is one of our carts
--            (c) the corpse item's effective age is >= sandbox removalAt
--          For non-cart corpses, falls through to vanilla — we don't
--          touch crate/dumpster/coffin grab semantics.
--
-- WHY NOT JUST EXTEND CartTransferInterceptor:
--   The interceptor wraps `ISInventoryTransferAction.new`. `ISGrabCorpseItem`
--   is a separate vanilla action class with its own constructor that the
--   right-click "Grab" flow uses directly. Different action class, different
--   wrap.
--
-- CONTEXT: SHARED. ISGrabCorpseItem runs on both client and server VMs in
--          MP, so the hook needs to install on both.
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/CorpseStorage"
-- Vanilla action class. pcall the require because the offline test
-- harness's module index doesn't include vanilla TimedActions; in
-- production PZ has loaded this before Core.lua runs anyway.
pcall(require, "TimedActions/ISGrabCorpseItem")

if not ISGrabCorpseItem then
    -- Class not present (test env / future vanilla rename) — skip hook.
    SaucedCarts.debug("GrabCorpseInterceptor: ISGrabCorpseItem not present — skip")
    return
end
if ISGrabCorpseItem._SaucedCarts_grabHookInstalled then
    return
end
ISGrabCorpseItem._SaucedCarts_grabHookInstalled = true

local origComplete = ISGrabCorpseItem.complete

--- Resolve the cart that owns a given inner container, or nil if the
--- container isn't part of a SaucedCart.
local function containerToCart(container)
    if not container or not container.getContainingItem then return nil end
    local item = container:getContainingItem()
    if item and SaucedCarts.safeIsCart(item) then return item end
    return nil
end

function ISGrabCorpseItem:complete()
    -- Sandbox + module guards: bail to vanilla if anything's missing.
    if not (SaucedCarts.CorpseStorage
        and SaucedCarts.CorpseStorage.isEnabled
        and SaucedCarts.CorpseStorage.isEnabled()) then
        return origComplete(self)
    end

    local item = self.item
    if not item then return origComplete(self) end

    local srcContainer = item.getContainer and item:getContainer()
    if not srcContainer then return origComplete(self) end

    -- Only intercept cart-owned corpses. Crate/dumpster/coffin etc. keep
    -- vanilla behavior.
    local srcCart = containerToCart(srcContainer)
    if not srcCart then return origComplete(self) end

    -- Effective-age check. Sandbox "never decay" returns nil thresholds
    -- and we fall through to vanilla.
    local _, removalAt
    if SaucedCarts.CorpseStorage._getRotThresholds then
        _, removalAt = SaucedCarts.CorpseStorage._getRotThresholds()
    end
    if not removalAt then return origComplete(self) end

    local age = SaucedCarts.CorpseStorage.effectiveAge
        and SaucedCarts.CorpseStorage.effectiveAge(item) or 0

    SaucedCarts.log(function() return string.format(
        "ISGrabCorpseItem.complete: cart=%s itemId=%s age=%.2fh removalAt=%.2fh",
        tostring(srcCart.getID and srcCart:getID() or "?"),
        tostring(item:getID()), age, removalAt
    ) end)

    if age < removalAt then
        return origComplete(self)
    end

    -- Past removal threshold: silent drop. Remove from cart container,
    -- skip vanilla's pickUpCorpseItem materialization.
    if srcContainer.DoRemoveItem then
        srcContainer:DoRemoveItem(item)
        if isServer() and type(sendRemoveItemFromContainer) == "function" then
            sendRemoveItemFromContainer(srcContainer, item)
        end
    end
    if srcContainer.setDrawDirty then srcContainer:setDrawDirty(true) end

    -- Halo so the player understands why nothing came out of the cart.
    -- addBadText is the colored "bad news" variant that works without
    -- needing a separator arg (vs addText with ColorRGB which requires one).
    if not isServer() and HaloTextHelper and self.character then
        pcall(function()
            HaloTextHelper.addBadText(self.character,
                getText("UI_SaucedCarts_CorpseDecomposed"))
        end)
    end

    -- Reconcile the cart's per-cart bookkeeping + propagate stink update.
    pcall(function()
        SaucedCarts.CorpseStorage.reconcile(srcCart,
            SaucedCarts.CorpseStorage.cartTargetSquare(srcCart, self.character))
        if SaucedCarts.CorpseStorage.publishCartStink then
            SaucedCarts.CorpseStorage.publishCartStink(srcCart, self.character)
        end
    end)

    SaucedCarts.log(function() return string.format(
        "ISGrabCorpseItem.complete: cart-corpse age=%.2fh past removalAt=%.2fh — silent drop (no body materialized)",
        age, removalAt
    ) end)

    -- Match vanilla's :complete signature.
    return true
end

SaucedCarts.debug("GrabCorpseInterceptor module loaded")
