-- ============================================================================
-- SaucedCarts/CartState/HighlightDisable.lua
-- ============================================================================
-- PURPOSE: Disable world item highlight outline for carts on the ground.
--          Carts should not show the highlight outline when hovered in
--          inventory UI, but can still show the regular highlight.
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() and not isClient() then return end

require "SaucedCarts/Core"

---@class SaucedCartsHighlightDisable
local HighlightDisable = {}

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

--- Check if an IsoObject is a cart's world item
---@param obj IsoObject
---@return boolean
local function isCartWorldObject(obj)
    if not obj or not instanceof(obj, "IsoWorldInventoryObject") then
        return false
    end
    local item = obj:getItem()
    return item and SaucedCarts.isCart(item)
end

--- Clear outline (but keep highlight) for a cart world object
---@param obj IsoWorldInventoryObject
---@param playerNum number
local function clearCartOutline(obj, playerNum)
    obj:setOutlineHighlight(playerNum, false)
    obj:setOutlineHlAttached(playerNum, false)
end

-- =============================================================================
-- HOOK INSTALLATION
-- =============================================================================

local hooksInstalled = false

--- Install hooks to disable cart highlighting in inventory UI
local function installHooks()
    if hooksInstalled then return end

    -- Hook ISInventoryPane:doWorldObjectHighlight - highlights items when hovering in inventory
    if ISInventoryPane then
        local originalDoWorldObjectHighlight = ISInventoryPane.doWorldObjectHighlight

        ISInventoryPane.doWorldObjectHighlight = function(self, _item)
            -- Let original run first
            local result = originalDoWorldObjectHighlight(self, _item)

            -- If it was a cart, clear the outline (keep highlight)
            if instanceof(_item, "InventoryItem") and SaucedCarts.isCart(_item) then
                local worldItem = _item:getWorldItem()
                if worldItem then
                    clearCartOutline(worldItem, self.player)
                end
            end

            return result
        end

        SaucedCarts.debug("HighlightDisable: Hooked ISInventoryPane:doWorldObjectHighlight()")
    end

    -- Hook ISInventoryPage:updateContainerHighlight - highlights containers when viewing inventory
    if ISInventoryPage then
        local originalUpdateContainerHighlight = ISInventoryPage.updateContainerHighlight

        ISInventoryPage.updateContainerHighlight = function(self)
            -- Call original first
            originalUpdateContainerHighlight(self)

            -- If current inventory is a cart, clear its outline
            local coloredObj = self:getContainerParent(self.inventory)
            if isCartWorldObject(coloredObj) then
                clearCartOutline(coloredObj, self.player)
            end
        end

        SaucedCarts.debug("HighlightDisable: Hooked ISInventoryPage:updateContainerHighlight()")
    end

    hooksInstalled = true
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

--- Initialize the highlight disable hooks
--- Called automatically on require, but can be called again if needed
function HighlightDisable.init()
    if not hooksInstalled then
        Events.OnGameStart.Add(installHooks)
    end
end

--- Check if hooks are installed
---@return boolean
function HighlightDisable.isInstalled()
    return hooksInstalled
end

-- =============================================================================
-- AUTO-INITIALIZATION
-- =============================================================================

HighlightDisable.init()

SaucedCarts.debug("HighlightDisable module loaded")

return HighlightDisable
