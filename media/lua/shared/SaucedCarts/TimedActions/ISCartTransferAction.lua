-- ============================================================================
-- SaucedCarts/TimedActions/ISCartTransferAction.lua
-- ============================================================================
-- PURPOSE: Custom transfer action for ANY transfer involving a SaucedCarts
--          cart container — whether the cart is the source or the destination,
--          and whether it's on the ground or held in-hand.
--
--          Works around vanilla's TransactionManager.isConsistent() check
--          which rejects cart-involved transfers on dedicated MP. Our Lua
--          capacity override is bypassed by Java-internal calls inside
--          TransactionManager, so from the server's point of view the cart's
--          capacity is always the hardcoded 50-cap — and every transfer over
--          that limit (or to/from a non-character-parented container) gets
--          silently rejected mid-action. User sees "progress bar completes,
--          item stays in place".
--
--          This action bypasses the transaction system entirely. Client fires
--          one SaucedCarts.Network command; server performs the move via
--          vanilla ISTransferAction:transferItem (handles unequip, worn-item
--          removal, OnClothingUpdated, candle/lantern swaps) and manually
--          broadcasts the ADD via sendAddItemToContainer.
--
-- CONTEXT: SHARED (MP timed action sync requires shared load).
--
-- DIRECTION:
--   "in"   -> item moves INTO the cart (player inv -> cart)
--   "out"  -> item moves OUT of the cart (cart -> player inv or nearby)
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"

ISCartTransferAction = ISBaseTimedAction:derive("ISCartTransferAction")
ISCartTransferAction.Type = "ISCartTransferAction"

function ISCartTransferAction:isValid()
    if not self.item or not self.srcContainer or not self.destContainer then
        return false
    end
    if not self.srcContainer:contains(self.item) then
        return false
    end
    -- Floor destinations: skip hasRoomFor. PZ's floor container enforces
    -- a per-tile weight cap in vanilla's hasRoomFor, but we're going out
    -- to the world via IsoGridSquare:AddWorldInventoryItem, which doesn't
    -- share that cap. The UX weight cap is why cart→floor kept bugging
    -- on dedi — the floor tile was "full" by vanilla's accounting but the
    -- actual world drop would have worked fine.
    if self.destContainer.getType and self.destContainer:getType() == "floor" then
        return true
    end
    return self.destContainer:hasRoomFor(self.character, self.item)
end

function ISCartTransferAction:waitToStart()
    return self.character:shouldBeTurning()
end

function ISCartTransferAction:update()
    if self.item then self.item:setJobDelta(self:getJobDelta()) end
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISCartTransferAction:start()
    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "Low")
    if self.item then
        self.item:setJobType(getText("ContextMenu_Grab"))
        self.item:setJobDelta(0.0)
    end
end

function ISCartTransferAction:stop()
    if self.item then self.item:setJobDelta(0.0) end
    ISBaseTimedAction.stop(self)
end

function ISCartTransferAction:perform()
    if self.item then self.item:setJobDelta(0.0) end

    local cartItem = self.cartItem
    if not cartItem then
        -- Fallback: pull cart from whichever container has a containing item.
        -- One of (src, dest) is the cart's inner container.
        local srcItem = self.srcContainer and self.srcContainer.getContainingItem
            and self.srcContainer:getContainingItem()
        local destItem = self.destContainer and self.destContainer.getContainingItem
            and self.destContainer:getContainingItem()
        if srcItem and SaucedCarts.safeIsCart(srcItem) then
            cartItem = srcItem
        elseif destItem and SaucedCarts.safeIsCart(destItem) then
            cartItem = destItem
        end
    end

    -- Classify both sides of the transfer so the server can rebuild the
    -- correct ItemContainer references. On server side we can't re-use
    -- the client's ItemContainer refs (especially for the floor ItemContainer,
    -- which is a per-player Lua-side object the server has never seen).
    --
    -- "floor" — square-backed, needs coords
    -- "cart"  — cart's inner container, needs the cart item ID
    -- "inv"   — player's main inventory (default)
    local function classifySide(container, fallbackCartItem)
        if not container or not container.getType then
            return "inv", nil, nil, nil, nil
        end
        local dtype = container:getType()
        if dtype == "floor" then
            local sqX, sqY, sqZ
            local sq = container.getParent and container:getParent()
            if sq and sq.getX then sqX, sqY, sqZ = sq:getX(), sq:getY(), sq:getZ() end
            return "floor", nil, sqX, sqY, sqZ
        end
        local ci = container.getContainingItem and container:getContainingItem()
        if ci and SaucedCarts.safeIsCart(ci) then
            return "cart", ci:getID(), nil, nil, nil
        end
        return "inv", nil, nil, nil, nil
    end

    local srcKind, srcCartId, srcSqX, srcSqY, srcSqZ = classifySide(self.srcContainer, cartItem)
    local destKind, destCartId, destSqX, destSqY, destSqZ = classifySide(self.destContainer, cartItem)

    -- Fill in player's current square when either side is a floor with no
    -- direct square reference (defensive — should rarely trigger).
    local function fillSq(sqX, sqY, sqZ)
        if sqX and sqY and sqZ then return sqX, sqY, sqZ end
        if self.character then
            local csq = self.character:getCurrentSquare()
            if csq then return csq:getX(), csq:getY(), csq:getZ() end
        end
        return sqX, sqY, sqZ
    end
    if srcKind == "floor"  then srcSqX,  srcSqY,  srcSqZ  = fillSq(srcSqX,  srcSqY,  srcSqZ)  end
    if destKind == "floor" then destSqX, destSqY, destSqZ = fillSq(destSqX, destSqY, destSqZ) end

    if self.item and cartItem then
        if isClient() then
            SaucedCarts.Network.sendToServer(self.character, "cartTransfer", {
                itemId = self.item:getID(),
                cartId = cartItem:getID(),
                direction = self.direction or "in",
                srcKind = srcKind,
                srcCartId = srcCartId,
                srcSqX = srcSqX, srcSqY = srcSqY, srcSqZ = srcSqZ,
                destKind = destKind,
                destCartId = destCartId,
                destSqX = destSqX, destSqY = destSqY, destSqZ = destSqZ,
            })
        else
            if SaucedCarts.performCartTransfer then
                -- SP / dedi-server path: reconstruct drop/pickup squares
                -- locally so performCartTransfer's floor branches fire.
                local function squareFromKind(kind, container)
                    if kind ~= "floor" then return nil end
                    if container and container.getParent then
                        local maybeSq = container:getParent()
                        if maybeSq and maybeSq.getX and maybeSq.AddWorldInventoryItem then
                            return maybeSq
                        end
                    end
                    if self.character then return self.character:getCurrentSquare() end
                    return nil
                end
                local dropSquare = squareFromKind(destKind, self.destContainer)
                local srcSquare  = squareFromKind(srcKind,  self.srcContainer)
                SaucedCarts.performCartTransfer(
                    self.character, self.item,
                    self.srcContainer, self.destContainer, dropSquare, srcSquare
                )
            end
        end
    end

    ISBaseTimedAction.perform(self)
end

function ISCartTransferAction:getDuration()
    if self.character and self.character:isTimedActionInstant() then
        return 1
    end
    return self.maxTime or 10
end

---@param character IsoPlayer
---@param item InventoryItem  item to move
---@param srcContainer ItemContainer
---@param destContainer ItemContainer
---@param direction string  "in" (player->cart) or "out" (cart->player)
---@param cartItem InventoryItem  the cart (for server-side command routing)
---@param time number|nil
function ISCartTransferAction:new(character, item, srcContainer, destContainer, direction, cartItem, time)
    local o = ISBaseTimedAction.new(self, character)
    o.character    = character
    o.item         = item
    o.srcContainer = srcContainer
    o.destContainer = destContainer
    o.direction    = direction or "in"
    o.cartItem     = cartItem
    o.maxTime      = time or 10
    o.stopOnWalk   = true
    o.stopOnRun    = true
    o.stopOnAim    = true
    o.forceProgressBar = true
    return o
end

-- Backwards-compat alias: the old ISCartDepositAction name still works for
-- any code that references it directly. The Type string matches so MP
-- serialization stays consistent for in-flight actions across the upgrade.
ISCartDepositAction = ISCartTransferAction

return ISCartTransferAction
