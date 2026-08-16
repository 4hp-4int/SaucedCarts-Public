-- ============================================================================
-- SaucedCarts/ConsumeWithCart.lua
-- ============================================================================
-- PURPOSE: Keep the cart visible (and in hand) while eating, drinking or
--          smoking during a push.
--
-- CONTEXT: CLIENT ONLY (hand-model overrides are pure presentation; the
--          owning client is the only VM that renders them)
--
-- MECHANISM: Vanilla's consume actions (ISEatFoodAction, ISDrinkFluidAction,
--   ISDrinkFromBottle) never equip the consumable — they are already
--   cart-compatible mechanically (no equip, stopOnWalk=false, :complete()
--   defined so MP replicates). Their one cart problem is visual: start()
--   calls self:setOverrideHandModels(<utensil-or-nil>, item), and while an
--   action override is active ModelManager renders ONLY the override items
--   (ModelManager.java:671-688) — a nil primary means an EMPTY primary hand,
--   so the equipped cart's model vanishes for the whole action.
--
--   Fix: after the vanilla start() has set its override, re-assert the
--   equipped cart as the PRIMARY override item. addEquippedModelInstance
--   consults the item's ReplaceInPrimaryHand data (ModelManager.java:701),
--   so the cart model and the holdingcartright hand-mask layer both keep
--   working; the consumable stays in the SECONDARY slot, which is where the
--   Eat/Drink/Smoke action overlays expect it (they mask the left arm +
--   Bip01_Prop2 — see AnimSets/player/actions/DrinkBottle.xml, Smoke.xml).
--
--   Known cosmetic edge: eat-types that put the food in the PRIMARY slot
--   (Pot / PotForged two-hand bowls, utensil eating) get the cart re-imposed
--   over their primary override, so the pot/spoon model is not shown while
--   pushing. The action itself still works; the cart staying visible wins.
-- ============================================================================

if isServer() then return end

require "SaucedCarts/Core"

---@class SaucedCartsConsumeWithCart
local ConsumeWithCart = {}

--- Wrap one vanilla consume action class's start() so the equipped cart is
--- re-asserted as the primary hand-model override. Idempotent per class.
---@param actionClass table The vanilla action class (e.g. ISEatFoodAction)
---@param className string For logging
---@return boolean wrapped
local function wrapStart(actionClass, className)
    if not actionClass or type(actionClass.start) ~= "function" then
        SaucedCarts.debug("ConsumeWithCart: " .. className .. " not present, skipping")
        return false
    end
    if actionClass._saucedCartsConsumeWrapped then return true end
    actionClass._saucedCartsConsumeWrapped = true

    local originalStart = actionClass.start
    actionClass.start = function(self, ...)
        local result = originalStart(self, ...)
        -- pcall'd: a failure here may cost the cart model for one action,
        -- never the action itself.
        pcall(function()
            local chr = self.character
            local cart = chr and chr.getPrimaryHandItem and chr:getPrimaryHandItem()
            if cart and SaucedCarts.safeIsCart(cart) and self.setOverrideHandModels then
                self:setOverrideHandModels(cart, self.item)
            end
        end)
        return result
    end

    SaucedCarts.debug("ConsumeWithCart: wrapped " .. className .. ".start")
    return true
end

--- Install the wrappers. Safe to call repeatedly.
function ConsumeWithCart.install()
    wrapStart(ISEatFoodAction, "ISEatFoodAction")       -- food AND cigarettes (FoodType=cigarettes)
    wrapStart(ISDrinkFluidAction, "ISDrinkFluidAction") -- fluid-container drinking
    wrapStart(ISDrinkFromBottle, "ISDrinkFromBottle")   -- drink-for-thirst path
end

Events.OnGameStart.Add(ConsumeWithCart.install)

SaucedCarts.ConsumeWithCart = ConsumeWithCart

-- Test hook
ConsumeWithCart._wrapStart = wrapStart

SaucedCarts.debug("ConsumeWithCart module loaded")

return ConsumeWithCart
