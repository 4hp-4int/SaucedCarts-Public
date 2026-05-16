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

-- We derive from ISBaseTimedAction (NOT ISInventoryTransferAction) for
-- two reasons:
--   1. Boot-order in the offline test env: preload triggers our action
--      file load BEFORE vanilla_requires fires, so ISInventoryTransferAction
--      isn't in scope yet. A failed derive would silently fall back to
--      ISBaseTimedAction and the contract test would (correctly) flag a
--      broken prototype chain.
--   2. Vanilla's :start in 42.17 calls createItemTransaction; vanilla's
--      :update polls isItemTransactionDone; vanilla's :perform iterates
--      a queueList. None of those work for our pipeline. Inheriting them
--      and then having to override every lifecycle method is fragile —
--      a future vanilla patch could add a NEW lifecycle method we'd
--      silently inherit.
--
-- Trade-off: vanilla auxiliary methods (setOnComplete, setAllowMissing-
-- Items, etc.) need explicit stubs below. The contract test in
-- OfflineApiContractTests.lua catches any missing stub before players hit
-- the crash, so this trade is well-policed.
ISCartTransferAction = ISBaseTimedAction:derive("ISCartTransferAction")

-- ============================================================================
-- classifySide: serialise one side of a cart transfer for the server
-- ============================================================================
-- Pulled out of :perform() so offline tests can cover it directly without
-- constructing a full timed action + stage. Returns six values:
--   (kind, cartId, sqX, sqY, sqZ, containerType)
-- where kind is one of:
--   "floor"  — world square (needs coords)
--   "cart"   — cart's inner container (needs cartId)
--   "world"  — a non-cart world container bound to an IsoObject on a tile
--              (needs coords + containerType so the server can locate the
--              right container among the multiple objects on that tile)
--   "bag"    — inner container of a non-cart InventoryItem (equipped
--              backpack, satchel, holster, etc.). Serialized as the
--              containing item's ID in the cartId slot; server looks up
--              the item recursively in the player's inventory.
--   "inv"    — player's main inventory (the default catchall; server uses
--              this as a fallback but will also apply the defensive
--              item:getContainer() check for pre-v2.1.5 clients)
function ISCartTransferAction.classifySide(container, fallbackCartItem)
    if not container or not container.getType then
        return "inv", nil, nil, nil, nil, nil
    end
    local dtype = container:getType()
    if dtype == "floor" then
        local sqX, sqY, sqZ
        local sq = container.getParent and container:getParent()
        if sq and sq.getX then sqX, sqY, sqZ = sq:getX(), sq:getY(), sq:getZ() end
        return "floor", nil, sqX, sqY, sqZ, nil
    end
    local ci = container.getContainingItem and container:getContainingItem()
    if ci then
        if SaucedCarts.safeIsCart(ci) then
            return "cart", ci:getID(), nil, nil, nil, nil
        end
        -- Non-cart InventoryItem parent: equipped bag / satchel / holster /
        -- backpack-in-backpack. Pre-bag-fix these fell through to "inv",
        -- making the server resolve the player's main inventory — so a
        -- transfer from a ground cart into an equipped bag would deposit
        -- into main inv instead of the bag.
        return "bag", ci:getID(), nil, nil, nil, nil
    end
    -- World container — bound to an IsoObject on a specific square. Before
    -- v2.1.5, world containers collapsed to "inv" and the server resolveSide
    -- returned the player's inventory instead — so a transfer between a
    -- cart and a shelf silently used the player's main inventory as the
    -- non-cart endpoint, producing dupes and "container already has id"
    -- errors downstream.
    local sg = container.getSourceGrid and container:getSourceGrid()
    if sg and sg.getX then
        -- Disambiguate WHICH object/container on the tile. Two stacked
        -- crates (or a fridge's fridge+freezer) share (square, type); only
        -- the parent object's index + the container's index within that
        -- object tell them apart. Mirrors vanilla ISInventoryPage.lua:
        -- 1405-1410. Without these the server resolves first-by-type and
        -- the item lands in the wrong box.
        local objIdx, contIdx
        local parent = container.getParent and container:getParent()
        if parent and parent.getObjectIndex then
            objIdx = parent:getObjectIndex()
            if parent.getContainerCount and parent.getContainerByIndex then
                for i = 0, parent:getContainerCount() - 1 do
                    if parent:getContainerByIndex(i) == container then
                        contIdx = i
                        break
                    end
                end
            end
        end
        return "world", nil, sg:getX(), sg:getY(), sg:getZ(), dtype, objIdx, contIdx
    end
    return "inv", nil, nil, nil, nil, nil
end
ISCartTransferAction.Type = "ISCartTransferAction"

function ISCartTransferAction:isValid()
    if not self.item or not self.srcContainer or not self.destContainer then
        return false
    end
    -- Vanilla compat: ISCraftingUI.ReturnItemToContainer (and a few other
    -- crafting-cleanup paths) set allowMissingItems=true so the action
    -- still completes when the item was destroyed mid-craft. Mirror
    -- vanilla ISInventoryTransferAction:isValid (line 67) — flag dontAdd
    -- and let perform skip the move while still firing onCompleteFunc.
    if self.allowMissingItems and not self.srcContainer:contains(self.item) then
        self.dontAdd = true
        return true
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

-- ============================================================================
-- VANILLA-API SHIMS
-- ============================================================================
-- Methods vanilla code calls externally on action instances. Our
-- interceptor substitutes ISCartTransferAction for vanilla's class; if
-- we don't expose these, downstream calls (e.g. ISCraftingUI.Return-
-- ItemToContainer's `action:setAllowMissingItems(true)`) crash with
-- "Object tried to call nil". OfflineApiContractTests.lua enforces
-- presence so future vanilla additions get caught before players hit
-- the crash.
-- ============================================================================

--- Mirror of ISInventoryTransferAction:setAllowMissingItems (vanilla
--- ISInventoryTransferAction.lua:735). Crafting cleanup paths set this
--- to keep the action alive when ingredients were destroyed mid-recipe.
function ISCartTransferAction:setAllowMissingItems(allow)
    self.allowMissingItems = allow
end

--- Mirror of ISInventoryTransferAction:setOnComplete (vanilla
--- ISInventoryTransferAction.lua:680). Used by crafting / map / alarm
--- / inspect-clothing flows. Our :perform fires onCompleteFunc after
--- the move (with the args this captured).
function ISCartTransferAction:setOnComplete(func, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
    self.onCompleteFunc = func
    self.onCompleteArgs = { arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8 }
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

-- ============================================================================
-- BULK COALESCING (vanilla checkQueueList / canMergeAction parity)
-- ============================================================================
-- ISInventoryPane:transferItemsByWeight queues one transfer action per item.
-- Vanilla's ISInventoryTransferAction absorbs a contiguous run of same-
-- src/dest actions so a stack moves in one batched action. We derive from
-- ISBaseTimedAction (not ISInventoryTransferAction) so we must reimplement
-- this or every queued ISCartTransferAction runs full-duration in series —
-- the reported "nails transfer one at a time with carts".

ISCartTransferAction.MERGE_CAP = 50

--- True if `other` is a queued cart-transfer that can be folded into this
--- one (same endpoints + direction + cart, no per-action callbacks). Mirrors
--- vanilla ISInventoryTransferAction:canMergeAction.
function ISCartTransferAction:canMergeAction(other)
    if not other then return false end
    if other.Type ~= self.Type then return false end
    if other.srcContainer ~= self.srcContainer then return false end
    if other.destContainer ~= self.destContainer then return false end
    if (other.direction or "in") ~= (self.direction or "in") then return false end
    if other.cartItem ~= self.cartItem then return false end
    if self.onCompleteFunc or other.onCompleteFunc then return false end
    if self.allowMissingItems ~= other.allowMissingItems then return false end
    return true
end

--- Pure: given this action and the list of actions queued AFTER it (in
--- order), return (items, mergedCount) where `items` is { self.item, ... }
--- for the contiguous mergeable prefix and `mergedCount` is how many
--- following actions were absorbed. Stops at the first non-mergeable action
--- and is capped at MERGE_CAP. Side-effect free so it's unit-testable
--- without a live ISTimedActionQueue.
function ISCartTransferAction.collectBatch(self, following)
    local items = { self.item }
    local merged = 0
    if following then
        for i = 1, #following do
            if #items >= ISCartTransferAction.MERGE_CAP then break end
            local a = following[i]
            if a and a.item and self:canMergeAction(a) then
                items[#items + 1] = a.item
                merged = merged + 1
            else
                break
            end
        end
    end
    return items, merged
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

    local srcKind, srcCartId, srcSqX, srcSqY, srcSqZ, srcContType, srcObjIdx, srcContIdx =
        ISCartTransferAction.classifySide(self.srcContainer, cartItem)
    local destKind, destCartId, destSqX, destSqY, destSqZ, destContType, destObjIdx, destContIdx =
        ISCartTransferAction.classifySide(self.destContainer, cartItem)

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

    -- dontAdd is set by :isValid when allowMissingItems=true and the item
    -- was destroyed mid-craft. Skip the move but still fire onComplete.
    if self.dontAdd then
        if self.onCompleteFunc then
            local a = self.onCompleteArgs or {}
            pcall(self.onCompleteFunc, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8])
        end
        ISBaseTimedAction.perform(self)
        return
    end

    -- Coalesce the contiguous run of mergeable transfer actions queued
    -- behind us into one batch, and pull them out of the action queue so
    -- they don't each run their own full-duration timed action.
    local batchItems = { self.item }
    do
        local q = ISTimedActionQueue and ISTimedActionQueue.getTimedActionQueue
            and ISTimedActionQueue.getTimedActionQueue(self.character)
        local arr = q and q.queue
        if arr then
            local idx
            for i = 1, #arr do if arr[i] == self then idx = i; break end end
            if idx then
                local following = {}
                for i = idx + 1, #arr do following[#following + 1] = arr[i] end
                local items, merged = ISCartTransferAction.collectBatch(self, following)
                batchItems = items
                for _ = 1, merged do
                    local removed = table.remove(arr, idx + 1)
                    if removed and table.wipe then pcall(table.wipe, removed) end
                end
            end
        end
    end
    local itemIds = {}
    for i = 1, #batchItems do itemIds[i] = batchItems[i]:getID() end

    if self.item and cartItem then
        if isClient() then
            SaucedCarts.Network.sendToServer(self.character, "cartTransfer", {
                itemId = self.item:getID(),
                itemIds = itemIds,               -- v2.1.7: batched bulk transfer
                cartId = cartItem:getID(),
                direction = self.direction or "in",
                srcKind = srcKind,
                srcCartId = srcCartId,
                srcSqX = srcSqX, srcSqY = srcSqY, srcSqZ = srcSqZ,
                srcContType = srcContType,       -- v2.1.5: world-container type
                srcObjIdx = srcObjIdx,           -- v2.1.7: stacked-container disambiguation
                srcContIdx = srcContIdx,
                destKind = destKind,
                destCartId = destCartId,
                destSqX = destSqX, destSqY = destSqY, destSqZ = destSqZ,
                destContType = destContType,     -- v2.1.5: world-container type
                destObjIdx = destObjIdx,         -- v2.1.7: stacked-container disambiguation
                destContIdx = destContIdx,
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
                for i = 1, #batchItems do
                    SaucedCarts.performCartTransfer(
                        self.character, batchItems[i],
                        self.srcContainer, self.destContainer, dropSquare, srcSquare
                    )
                end
            end
        end
    end

    -- Vanilla compat: fire onCompleteFunc after the move (mirrors
    -- ISInventoryTransferAction:perform line 508-511). Crafting / map /
    -- alarm callers register a callback here; if we don't fire it the
    -- post-craft cleanup or follow-up UI never triggers.
    if self.onCompleteFunc then
        local a = self.onCompleteArgs or {}
        pcall(self.onCompleteFunc, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8])
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
    -- Initialize the dontAdd flag for the allowMissingItems flow:
    -- :isValid sets it to true when the item disappeared mid-craft,
    -- :perform reads it to skip the move while still firing onComplete.
    o.dontAdd      = false
    o.forceProgressBar = true
    return o
end

-- Backwards-compat alias: the old ISCartDepositAction name still works for
-- any code that references it directly. The Type string matches so MP
-- serialization stays consistent for in-flight actions across the upgrade.
ISCartDepositAction = ISCartTransferAction

return ISCartTransferAction
