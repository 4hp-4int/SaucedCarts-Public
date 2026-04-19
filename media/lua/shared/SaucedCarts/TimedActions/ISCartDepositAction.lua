-- ============================================================================
-- SaucedCarts/TimedActions/ISCartDepositAction.lua
-- ============================================================================
-- PURPOSE: Custom transfer action for depositing items INTO a ground cart.
--
--          Works around vanilla's TransactionManager.isConsistent() check
--          (Java) which rejects transfers to non-character-parented
--          containers when the Java-internal getEffectiveCapacity is less
--          than needed. Our Lua override on getEffectiveCapacity only
--          intercepts Lua callers, so the Java-internal check in
--          TransactionManager sees 50 (the hard engine cap) regardless of
--          the sandbox multiplier — transfer gets rejected server-side,
--          the client action becomes "bugged".
--
--          This action bypasses the transaction system entirely. Client
--          just fires one SaucedCarts.Network command; server performs the
--          move via vanilla sendAddItemToContainer / sendRemoveItemFromContainer
--          (which broadcast to all clients as usual).
--
-- CONTEXT: SHARED (must be shared for MP timed action sync).
--
-- INTERCEPTION: Narrowly scoped. Only used when
--   ISInventoryTransferAction.new detects destination is a SaucedCarts
--   cart AND destination's parent is NOT an IsoGameCharacter. In-hand
--   carts (dest parent IS the player) continue to use vanilla flow.
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"

ISCartDepositAction = ISBaseTimedAction:derive("ISCartDepositAction")
ISCartDepositAction.Type = "ISCartDepositAction"

function ISCartDepositAction:isValid()
    if not self.item or not self.srcContainer or not self.destContainer then
        return false
    end
    if not self.srcContainer:contains(self.item) then
        return false
    end
    -- Our hasRoomFor override returns the correct raw-capacity answer here.
    return self.destContainer:hasRoomFor(self.character, self.item)
end

function ISCartDepositAction:waitToStart()
    return self.character:shouldBeTurning()
end

function ISCartDepositAction:update()
    if self.item then self.item:setJobDelta(self:getJobDelta()) end
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISCartDepositAction:start()
    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "Low")
    if self.item then
        self.item:setJobType(getText("ContextMenu_Grab"))
        self.item:setJobDelta(0.0)
    end
end

function ISCartDepositAction:stop()
    if self.item then self.item:setJobDelta(0.0) end
    ISBaseTimedAction.stop(self)
end

function ISCartDepositAction:perform()
    if self.item then self.item:setJobDelta(0.0) end

    local cartItem = self.destContainer and self.destContainer.getContainingItem
        and self.destContainer:getContainingItem()

    if self.item and cartItem then
        if isClient() then
            -- MP client: ask the server to perform the move authoritatively.
            -- Server bypasses TransactionManager (which would reject because
            -- of the Java-internal 50-cap check) and uses vanilla sendAdd /
            -- sendRemove to broadcast the state change to every client.
            SaucedCarts.Network.sendToServer(self.character, "depositToGroundCart", {
                itemId = self.item:getID(),
                cartId = cartItem:getID(),
            })
        else
            -- SP or dedicated server context: do the move locally via the
            -- shared helper (SaucedCarts.performCartDeposit).
            if SaucedCarts.performCartDeposit then
                SaucedCarts.performCartDeposit(self.character, self.item, cartItem)
            end
        end
    end

    ISBaseTimedAction.perform(self)
end

function ISCartDepositAction:getDuration()
    if self.character and self.character:isTimedActionInstant() then
        return 1
    end
    return 10
end

--- Primitives-only constructor so the action syncs cleanly across the
--- MP timed-action system. All runtime lookups happen in perform() via
--- the containers and item passed in.
---@param character IsoPlayer
---@param item InventoryItem  item to move into the cart
---@param srcContainer ItemContainer  current container
---@param destContainer ItemContainer  cart's inner container (dest)
---@param time number|nil  action time, default 10
function ISCartDepositAction:new(character, item, srcContainer, destContainer, time)
    local o = ISBaseTimedAction.new(self, character)
    o.character    = character
    o.item         = item
    o.srcContainer = srcContainer
    o.destContainer = destContainer
    o.maxTime      = time or 10
    o.stopOnWalk   = true
    o.stopOnRun    = true
    o.stopOnAim    = true
    o.forceProgressBar = true
    return o
end

return ISCartDepositAction
