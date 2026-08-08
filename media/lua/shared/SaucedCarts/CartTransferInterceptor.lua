-- ============================================================================
-- SaucedCarts/CartTransferInterceptor.lua
-- ============================================================================
-- PURPOSE: Redirect vanilla ISInventoryTransferAction to our custom
--          ISCartTransferAction for any transfer involving a SaucedCarts cart
--          container (cart as source OR destination, in-hand OR on-ground).
--
--          Vanilla's server-side TransactionManager.isConsistent uses
--          Java-internal getEffectiveCapacity which bypasses our Lua
--          capacity override. On dedicated MP this causes the server to
--          silently reject cart-involved transfers mid-action — the client
--          plays the progress bar but the item never moves.
--
--          Our custom action skips TransactionManager and delegates to
--          vanilla ISTransferAction:transferItem, which handles unequip,
--          worn-item removal, OnClothingUpdated model refresh, radio /
--          candle / lantern item swaps — all the things the vanilla
--          transfer UX depends on — without the consistency gate.
--
-- CONTEXT: SHARED. Client installs the hook (ISInventoryTransferAction is
--          client-only). Server registers the cartTransfer command handler
--          so it can perform the move authoritatively.
--
-- SAFETY:  Interception logic runs in pcall. Any error falls through to
--          vanilla ISInventoryTransferAction — worst case, user sees the
--          pre-fix "bugged action" symptom instead of a crash.
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/TimedActions/ISCartTransferAction"
require "SaucedCarts/CorpseStorage"

-- ============================================================================
-- SHARED HELPERS
-- ============================================================================

--- Return the cart InventoryItem if `container` is a cart's inner container,
--- otherwise nil.
---@param container ItemContainer|nil
---@return InventoryItem|nil
local function containerToCart(container)
    if not container or not container.getContainingItem then return nil end
    local item = container:getContainingItem()
    if item and SaucedCarts.safeIsCart(item) then return item end
    return nil
end

--- Decide whether this transfer should be routed through our custom action.
--- Match ANY cart involvement — source cart OR destination cart, in-hand OR
--- on the ground. Vanilla's consistency check fails for all of these on dedi.
---@param srcContainer ItemContainer|nil
---@param destContainer ItemContainer|nil
---@return string|nil direction  "in" (player->cart), "out" (cart->player), or nil if no match
---@return InventoryItem|nil cart
local function classifyTransfer(srcContainer, destContainer)
    local destCart = containerToCart(destContainer)
    if destCart then
        return "in", destCart
    end
    local srcCart = containerToCart(srcContainer)
    if srcCart then
        return "out", srcCart
    end
    return nil, nil
end

-- ============================================================================
-- BROADCAST ADDRESSABILITY REPAIR (v2.1.16)
-- ============================================================================
-- We sync our server-authoritative moves with GameServer.sendAddItemToContainer
-- / sendRemoveItemFromContainer (GameServer.java:2391, :2451). Both route a
-- packet through exactly three branches and have NO else:
--
--   1. container:getCharacter() is an IsoPlayer   -> send to that player
--   2. container:getParent() ~= nil               -> sendToRelative(parent x,y)
--   3. containing item has a world item           -> sendToRelative(item x,y)
--
-- A container matching none is UNADDRESSABLE and the packet is dropped with
-- no error and no log. A bag nested inside a vehicle part or a world object
-- lands in that hole every time: its inner container is built with the no-arg
-- `new ItemContainer()` so `parent` is nil, `getCharacter()`
-- (ItemContainer.java:3314) walks up and terminates at the non-character
-- owner, and the bag has no world item because it is inside a trunk rather
-- than on the ground.
--
-- Symptom (Workshop report 2026-08-04): moving items from a bag sitting in a
-- vehicle trunk into a cart. The server performs the move correctly, but no
-- client is ever told the item left the bag, so the source pane never
-- changes — the transfer reads as "the action didn't complete". The stale
-- copy survives until the bag re-syncs, i.e. the moment it is taken out of
-- the trunk, at which point the items appear to vanish.
--
-- Repair: walk up to the nearest ADDRESSABLE ancestor container and refresh
-- the item that links the subtree to it, via sendReplaceItemInContainer.
-- That item's byte data carries its own contents, so refreshing the bag
-- sitting in the trunk rebuilds everything nested inside it. See
-- flushContainerResync for why this channel and not sendItemsInContainer.
--
-- Carts on the ground, equipped carts and bags in the player's inventory all
-- satisfy a branch already and are left entirely on the vanilla path.

--- True when vanilla's broadcast helpers can address `container`.
--- Mirrors the Java branch order exactly. Fail-safe: on any error we claim
--- addressable, so a surprise can only cost us a repair, never cause a
--- spurious flood of resync packets.
---@param container ItemContainer|nil
---@return boolean
local function isBroadcastAddressable(container)
    if not container then return true end
    local ok, addressable = pcall(function()
        local chr = container.getCharacter and container:getCharacter()
        if chr and instanceof(chr, "IsoPlayer") then return true end
        if container.getParent and container:getParent() ~= nil then return true end
        local ci = container.getContainingItem and container:getContainingItem()
        if ci and ci.getWorldItem and ci:getWorldItem() ~= nil then return true end
        return false
    end)
    if not ok then return true end
    return addressable and true or false
end

--- Walk from an unaddressable container up to the nearest ADDRESSABLE
--- ancestor container, and return that ancestor together with the item that
--- links the subtree to it.
---
--- Refreshing that one link item re-serialises everything nested inside it,
--- because an InventoryContainer's byte data carries its own contents. So a
--- bag three levels down inside a trunk is fixed by refreshing the outermost
--- bag sitting directly in the trunk.
---@param container ItemContainer
---@return ItemContainer|nil ancestor  addressable container holding `link`
---@return InventoryItem|nil link      the item to refresh inside `ancestor`
local function resolveResyncTarget(container)
    if not container then return nil, nil end
    local cur = container
    -- Bounded walk: a malformed cycle must not hang the server tick.
    for _ = 1, 16 do
        local link = cur.getContainingItem and cur:getContainingItem()
        if not link then return nil, nil end
        local up = link.getContainer and link:getContainer()
        if not up then return nil, nil end
        if isBroadcastAddressable(up) then
            return up, link
        end
        cur = up
    end
    return nil, nil
end

-- Coalescing buffer. A batched transfer (a stack of nails out of one bag)
-- calls performCartTransfer once per item; without coalescing that is one
-- refresh packet per item. Keyed by the link item so repeat marks collapse.
-- Kahlua has no `next`, so emptiness is tracked by counter.
local pendingResync = {}
local pendingResyncCount = 0
local pendingResyncPlayer = nil

--- Nearest BaseVehicle owning an ancestor of `container`, or nil.
--- Only vehicles matter here: see repairContainerUpdate for why.
---@param container ItemContainer
---@return BaseVehicle|nil
local function vehicleAncestorOf(container)
    local cur = container
    for _ = 1, 16 do
        local link = cur.getContainingItem and cur:getContainingItem()
        if not link then return nil end
        local up = link.getContainer and link:getContainer()
        if not up then return nil end
        local parent = up.getParent and up:getParent()
        if parent and instanceof and instanceof(parent, "BaseVehicle") then
            return parent
        end
        cur = up
    end
    return nil
end

--- Note that `container` needs a refresh, if it needs one at all.
--- Cheap and idempotent; the actual packets go out on flush.
---@param container ItemContainer|nil
---@param player IsoPlayer|nil  who to nudge into repainting their panels
local function markContainerForResync(container, player)
    if not isServer() then return end
    if isBroadcastAddressable(container) then return end
    pendingResyncPlayer = player or pendingResyncPlayer
    local ok, ancestor, link = pcall(resolveResyncTarget, container)
    if not ok or not ancestor or not link then
        SaucedCarts.log(function() return string.format(
            "resync: container type=%s is unaddressable and has no addressable "
            .. "ancestor — clients will not see this side of the move",
            tostring(container.getType and container:getType() or "?")) end)
        return
    end
    local key = tostring(link)
    if pendingResync[key] then return end
    pendingResync[key] = { ancestor = ancestor, link = link }
    pendingResyncCount = pendingResyncCount + 1
end

--- Push every pending refresh to clients. Safe to call when nothing is
--- pending, and safe to call late: a refresh always transmits current truth.
---
--- CHANNEL CHOICE — this is the whole reason the repair works. The obvious
--- candidate, sendItemsInContainer, is useless here: the client's handler
--- (AddInventoryItemToContainerPacket.processClient:87-90) SKIPS any item
--- whose id the destination already holds, logging "Error: Dupe item ID".
--- Resyncing a trunk that already contains the bag therefore changes nothing
--- on the client and just spams that error — the nested bag's contents are
--- never refreshed.
---
--- ReplaceInventoryItemInContainerPacket.processClient (:67-69) instead does
--- removeItemWithID(old) then addItem(new) with NO dedup guard, so replacing
--- the link item with itself rebuilds it from fresh byte data — contents and
--- all. One packet, so there is no remove-then-add ordering hazard, and it
--- needs nothing of the client beyond stock vanilla.
function SaucedCarts.flushContainerResync()
    if pendingResyncCount == 0 then return end
    local batch = pendingResync
    pendingResync, pendingResyncCount, pendingResyncPlayer = {}, 0, nil
    if type(sendReplaceItemInContainer) ~= "function" then return end
    for _, entry in pairs(batch) do
        pcall(function()
            sendReplaceItemInContainer(entry.ancestor, entry.link, entry.link)
        end)
    end

    -- The replace above is correct but REBINDS: the client's handler does
    -- removeItemWithID + addItem, so the bag becomes a NEW object. An open
    -- loot panel still points at the old bag's ItemContainer, which is now
    -- detached — right data, dead panel, and the item only appears after
    -- clicking away and back. Callers follow this with
    -- requestInventoryRefresh to repaint; keeping the refresh at the call
    -- site (rather than here) means a transfer that needed no repair still
    -- gets one, and a transfer that DID need one doesn't get two.
end

--- Rebuild the initiator's inventory panels from current container truth.
---
--- WHY EVERY CART TRANSFER NEEDS THIS, not just the rebinding repair above.
--- A panel only re-reads its container when that container is drawDirty
--- (ISInventoryPane.lua:2201), and performCartTransfer dirties the REAL src
--- and dest. That is enough for vanilla panels, because the container the
--- user is looking at IS the one we moved out of.
---
--- It is NOT enough for an aggregated panel. Better Containers' proximity
--- view (and Proximity Inventory before it) is backed by a synthetic
--- ItemContainer.new("proximityInv", nil, nil) holding REFERENCES to items
--- owned by the real nearby containers, refilled by clear() + addAll() only
--- inside refreshBackpacks. Vanilla always hands a transfer
--- item:getContainer() — the real shelf — so nothing ever dirties the
--- snapshot the user is actually viewing, and the moved item stays listed
--- until something forces a rebuild. Vanilla's own floor container is the
--- same shape.
---
--- Commands.ui.DirtyUI (client ServerCommands.lua:138-140) runs
--- ISInventoryPage.dirtyUI() -> refreshBackpacks(), which is exactly that
--- rebuild. Stock vanilla client code, so it works against unmodified and
--- not-yet-updated clients. Targeted at the initiator via the 4-arg form:
--- they are the one with the panel open, and refreshing every player on
--- every cart transfer would be a needless broadcast.
---@param player IsoPlayer|nil  the initiator; required server-side
function SaucedCarts.requestInventoryRefresh(player)
    if isServer() then
        if player and type(sendServerCommand) == "function" then
            pcall(function() sendServerCommand(player, "ui", "DirtyUI", {}) end)
        end
        return
    end
    -- SP: the move already happened synchronously in perform, so refreshing
    -- now reads post-move truth.
    if ISInventoryPage and ISInventoryPage.dirtyUI then
        pcall(function() ISInventoryPage.dirtyUI() end)
    end
end

--- Re-send one add/remove that vanilla's dispatch silently dropped.
--- Call AFTER vanilla has had its go: when the container is addressable this
--- is a no-op, because vanilla already delivered.
---
--- TWO CHANNELS, because vanilla's own addressing is uneven:
---
--- 1. PRECISE (vehicles). ContainerID.set builds a proper nested id for a
---    container inside a vehicle — ObjectInVehicle, carrying (vehicleId,
---    partIndex, containingItemId) — and the client resolves it straight to
---    `inventoryContainer.getItemContainer()` (ContainerID.java:461-480),
---    i.e. its LIVE bag container. Nothing is rebound, so an open loot panel
---    keeps working and vanilla's own dirtying applies.
---    The only thing missing is dispatch: GameServer picks broadcast coords
---    from `container.getParent()`, which is nil for a bag's inner
---    container. So we lend it the vehicle as a parent for the duration of
---    the call. That does NOT affect the id — ContainerID.set derives it
---    from the true outermost container, not from our loan.
---
--- 2. FALLBACK (everything else, e.g. a bag on a shelf). Vanilla has no
---    nested id for these: setObject computes containerIndex via
---    `o.getContainerIndex(container)`, which is -1 for a container the
---    object does not directly own. So there is no packet that can name the
---    bag, and we fall back to refreshing the whole link item — which
---    rebinds, hence the DirtyUI nudge in flushContainerResync.
---@param send function  sendAddItemToContainer or sendRemoveItemFromContainer
local function repairContainerUpdate(send, container, item, player)
    if not isServer() or not container or not item then return end
    if type(send) ~= "function" then return end
    -- Vanilla could reach it: it has already sent the real packet.
    if isBroadcastAddressable(container) then return end

    local veh = vehicleAncestorOf(container)
    if veh and container.setParent then
        local original = container.getParent and container:getParent()
        local sent = false
        pcall(function()
            container:setParent(veh)
            send(container, item)
            sent = true
        end)
        -- Restore unconditionally: leaving a borrowed parent behind would
        -- make this container look addressable (and mis-owned) forever.
        pcall(function() container:setParent(original) end)
        if sent then return end
        SaucedCarts.log("repairContainerUpdate: precise send failed, falling back to refresh")
    end

    markContainerForResync(container, player)
end

-- ============================================================================
-- ACTUAL MOVE (SP + SERVER-AUTHORITATIVE)
-- ============================================================================

--- Perform an item move between two containers where at least one side is a
--- cart. Direction-neutral — just hands off to vanilla ISTransferAction.
--- Vanilla transferItem does the srcContainer:DoRemoveItem + server-side
--- sendRemoveItemFromContainer + destContainer:AddItem, and handles the
--- unequip / worn-item / clothing-refresh / radio / candle edge cases. We
--- additionally fire sendAddItemToContainer on the server because vanilla
--- defers that to TransactionManager, which we're deliberately skipping.
---
---@param player IsoPlayer
---@param item InventoryItem
---@param srcContainer ItemContainer|nil  nil when the source is a world square
---@param destContainer ItemContainer|nil  nil when the destination is a world
---        square (dropSquare is used instead)
---@param dropSquare IsoGridSquare|nil  set when dropping to ground
---@param srcSquare  IsoGridSquare|nil  set when picking up from ground
---@return boolean success
function SaucedCarts.performCartTransfer(player, item, srcContainer, destContainer, dropSquare, srcSquare)
    if not player or not item then return false end

    -- === SOURCE = ground (floor → cart) ===
    -- Item was on the world square; pick it up into destContainer. Mirrors
    -- vanilla ISTransferAction's floor branch: remove the world object from
    -- the square + broadcast the removal, then add the inventory item to
    -- the destination. We do it explicitly (rather than delegating to
    -- ISTransferAction) because the server doesn't have the client's floor
    -- ItemContainer, and passing a wrong srcContainer to vanilla
    -- transferItem was causing duplicate-AddItem errors ("container already
    -- has id") when the server's floor-branch didn't match.
    if srcSquare and not srcContainer then
        if not destContainer then return false end
        if destContainer.hasRoomFor and not destContainer:hasRoomFor(player, item) then
            SaucedCarts.debug("performCartTransfer: pickup dest has no room")
            return false
        end

        local worldItem = item.getWorldItem and item:getWorldItem()
        if worldItem then
            local sq = worldItem.getSquare and worldItem:getSquare() or srcSquare
            if sq and sq.transmitRemoveItemFromSquare then
                sq:transmitRemoveItemFromSquare(worldItem)
            end
            if worldItem.removeFromWorld  then worldItem:removeFromWorld()  end
            if worldItem.removeFromSquare then worldItem:removeFromSquare() end
            if worldItem.setSquare        then worldItem:setSquare(nil)     end
            if item.setWorldItem          then item:setWorldItem(nil)       end
        end
        if item.setJobDelta then item:setJobDelta(0.0) end
        destContainer:AddItem(item)
        if isServer() and type(sendAddItemToContainer) == "function" then
            sendAddItemToContainer(destContainer, item)
        end
        repairContainerUpdate(sendAddItemToContainer, destContainer, item, player)
        -- Mark dirty AFTER the mutation so the inventory panel repaints.
        if destContainer.setDrawDirty then destContainer:setDrawDirty(true) end
        SaucedCarts.debug(function() return string.format(
            "performCartTransfer: picked up item %d from ground into container type=%s",
            item:getID(), tostring(destContainer:getType())
        ) end)
        return true
    end

    -- === DEST = ground (cart → floor) ===
    -- Drop item onto the world square. Mirrors vanilla's floor-drop branch.
    if dropSquare then
        -- Idempotence guard (MP double-perform protection).
        -- ISCartTransferAction is a shared timed action: the dedi runs
        -- performCartTransfer twice per cart→floor drop — once via its own
        -- :perform else-branch, once via the cartTransfer network command.
        -- handleCartTransfer's existing idempotence check (destContainer +
        -- item.getContainer() == destContainer) is SKIPPED for floor drops
        -- because destContainer is nil. Without this guard, corpse items
        -- would call loadCorpseFromByteData + sendCorpse twice → V11 dupe
        -- (two IsoDeadBody materialized, two AddCorpseToMapPackets).
        if srcContainer and srcContainer.contains
            and not srcContainer:contains(item) then
            SaucedCarts.debug(function()
                return "performCartTransfer: item " .. tostring(item:getID())
                    .. " already moved from src, no-op (idempotent)"
            end)
            return true
        end

        if srcContainer and srcContainer.DoRemoveItem then
            srcContainer:DoRemoveItem(item)
            if isServer() and type(sendRemoveItemFromContainer) == "function" then
                sendRemoveItemFromContainer(srcContainer, item)
            end
            repairContainerUpdate(sendRemoveItemFromContainer, srcContainer, item, player)
            -- Inventory panel refresh on the source side.
            if srcContainer.setDrawDirty then srcContainer:setDrawDirty(true) end
        end

        -- Special case: corpse items (Base.CorpseMale/Female/Animal) carry a
        -- full IsoDeadBody state in their byteData buffer. Dropping them as
        -- a plain world inventory item leaves them un-grabbable (no
        -- IsoDeadBody exists on the square). Materialize via vanilla's
        -- loadCorpseFromByteData and register via addCorpse — same path the
        -- AddCorpseToMapPacket uses on receive.
        -- Sandbox-gated: when CorpseStorage is off the item drops as a
        -- regular world inventory item (vanilla behavior).
        local corpseFeatureOn = SaucedCarts.CorpseStorage
            and SaucedCarts.CorpseStorage.isEnabled
            and SaucedCarts.CorpseStorage.isEnabled()
        if corpseFeatureOn
            and SaucedCarts.CorpseStorage.isCorpseItem
            and SaucedCarts.CorpseStorage.isCorpseItem(item)
            and item.loadCorpseFromByteData then
            -- Rot short-circuit: silent-drop past vanilla's despawn threshold.
            -- Vanilla's `IsoDeadBody.updateBodies` (IsoDeadBody.java:1534)
            -- despawns non-skeleton zombie corpses at `age >= hoursForCorpse-
            -- Removal` (= our `skeletonAt`), NOT at `removalAt`. Materializing
            -- a body in the 24-32h window means it appears for one frame and
            -- vanilla's next tick removes it — user sees "corpse instantly
            -- disappears, no halo." We can't `setSkeleton(true)` on the
            -- rematerialized body to push it into the 24-32h survival window
            -- because the setter isn't exposed to Lua. So: match vanilla's
            -- effective despawn boundary at `skeletonAt`.
            local skeletonAt, removalAt
            if SaucedCarts.CorpseStorage._getRotThresholds then
                skeletonAt, removalAt = SaucedCarts.CorpseStorage._getRotThresholds()
            end
            local age = SaucedCarts.CorpseStorage.effectiveAge
                and SaucedCarts.CorpseStorage.effectiveAge(item) or 0
            SaucedCarts.log(function() return string.format(
                "performCartTransfer/corpse-unload: itemId=%s age=%.2fh skeletonAt=%s removalAt=%s",
                tostring(item:getID()), age,
                tostring(skeletonAt), tostring(removalAt)
            ) end)
            if skeletonAt and age >= skeletonAt then
                local srcCart = containerToCart(srcContainer)
                if srcCart and SaucedCarts.CorpseStorage.reconcile then
                    pcall(function()
                        SaucedCarts.CorpseStorage.reconcile(srcCart,
                            SaucedCarts.CorpseStorage.cartTargetSquare(srcCart, player))
                    end)
                end
                if not isServer() and HaloTextHelper and player then
                    pcall(function()
                        HaloTextHelper.addBadText(player,
                            getText("UI_SaucedCarts_CorpseDecomposed"))
                    end)
                end
                SaucedCarts.log(function() return string.format(
                    "performCartTransfer: corpse age=%.1fh past skeletonAt=%.1fh — silent drop (vanilla despawn boundary)",
                    age, skeletonAt
                ) end)
                return true
            end
            local t0 = getTimestampMs and getTimestampMs() or 0
            local okLoad, body = pcall(function()
                return item:loadCorpseFromByteData(dropSquare)
            end)
            local t1 = getTimestampMs and getTimestampMs() or 0
            if okLoad and body and dropSquare.addCorpse then
                -- Restore vanilla's rot clock from stamped deathTime so
                -- updateBodies resumes at the correct rot stage rather than
                -- treating the rematerialized body as freshly-dead.
                if SaucedCarts.CorpseStorage.restoreDeathTime then
                    SaucedCarts.CorpseStorage.restoreDeathTime(item, body)
                end
                pcall(function() dropSquare:addCorpse(body, false) end)
                -- H1 reconcile: the cart just lost a corpse. Cart may
                -- still be equipped / grounded elsewhere; resolve its
                -- current square and apply the delta. The body we just
                -- materialized is already on the tile via addCorpse, so
                -- that tile's CorpseCount is already correctly updated
                -- by vanilla.
                local srcCart = containerToCart(srcContainer)
                if srcCart and SaucedCarts.CorpseStorage
                    and SaucedCarts.CorpseStorage.reconcile then
                    pcall(function()
                        SaucedCarts.CorpseStorage.reconcile(srcCart,
                            SaucedCarts.CorpseStorage.cartTargetSquare(srcCart, player))
                    end)
                end
                -- MP: addCorpse alone doesn't broadcast to remote clients —
                -- IsoDeadBody.addToWorld only updates local CorpseCount +
                -- ObjectIDManager. Vanilla relies on sendCorpse (Lua-
                -- exposed wrapper around GameServer.sendCorpse, see
                -- LuaManager.java:3381) to fire AddCorpseToMapPacket to
                -- all clients. Without this call, dedi unload leaves
                -- other clients with no visible body. Safe in SP — the
                -- Lua wrapper early-returns when GameServer.server is
                -- false, so no-op in SP / client-only contexts.
                if isServer() and type(sendCorpse) == "function" then
                    pcall(function() sendCorpse(body) end)
                end
                local t2 = getTimestampMs and getTimestampMs() or 0
                SaucedCarts.log(function() return string.format(
                    "performCartTransfer: materialized corpse at (%d,%d,%d) " ..
                    "loadBytes=%dms addCorpse=%dms total=%dms",
                    dropSquare:getX(), dropSquare:getY(), dropSquare:getZ(),
                    t1 - t0, t2 - t1, t2 - t0
                ) end)
                return true
            end
            -- H2 (2026-04-24): primary materialization failed (corrupted
            -- byteData, Java-internal exception). Try vanilla's secondary
            -- fallback: createAndStoreDefaultDeadBody synthesizes a random
            -- default body via the standard IsoDeadBody constructor path.
            -- User loses the original body's clothing/inventory but gets a
            -- grabbable corpse instead of a soft-bricked CorpseMale item.
            if item.createAndStoreDefaultDeadBody then
                local okFallback, fallbackBody = pcall(function()
                    return item:createAndStoreDefaultDeadBody(dropSquare)
                end)
                if okFallback and fallbackBody and dropSquare.addCorpse then
                    pcall(function() dropSquare:addCorpse(fallbackBody, false) end)
                    if isServer() and type(sendCorpse) == "function" then
                        pcall(function() sendCorpse(fallbackBody) end)
                    end
                    local srcCart = containerToCart(srcContainer)
                    if srcCart and SaucedCarts.CorpseStorage
                        and SaucedCarts.CorpseStorage.reconcile then
                        pcall(function()
                            SaucedCarts.CorpseStorage.reconcile(srcCart,
                                SaucedCarts.CorpseStorage.cartTargetSquare(srcCart, player))
                        end)
                    end
                    SaucedCarts.log("performCartTransfer: corpse byteData was bad; spawned default fallback body")
                    return true
                end
            end

            -- Both primary and fallback failed. Put the item BACK in the
            -- cart so the player doesn't lose it to a void or end up with
            -- a soft-bricked corpse item on the ground. Halo-text the user
            -- so the failure is visible (server-side handler doesn't have
            -- HaloTextHelper, so we only halo on client).
            SaucedCarts.error("performCartTransfer: corpse materialization failed in BOTH paths; returning item to cart")
            if srcContainer and srcContainer.AddItem then
                pcall(function() srcContainer:AddItem(item) end)
                if srcContainer.setDrawDirty then srcContainer:setDrawDirty(true) end
            end
            if isClient() and HaloTextHelper and player and HaloTextHelper.addBadText then
                pcall(function()
                    HaloTextHelper.addBadText(player,
                        getText("UI_SaucedCarts_CorpseDataCorrupted") or "Corpse data corrupted; returned to cart")
                end)
            end
            return false
        end

        local dx, dy, dz = 0.5, 0.5, 0.0
        if ISTransferAction.GetDropItemOffset then
            dx, dy, dz = ISTransferAction.GetDropItemOffset(player, dropSquare, item)
        end
        -- IMPORTANT: 4-arg AddWorldInventoryItem(item, x, y, h) routes to
        -- the overload that defaults `transmit=true`, which internally
        -- broadcasts transmitCompleteItemToClients. Call the 5-arg form
        -- with transmit=false and do the transmit manually — otherwise the
        -- world item gets broadcast TWICE per drop, producing ghost copies
        -- on every client (including the initiator) and causing rolling
        -- "Error, container already has id" spam as the engine tries to
        -- re-add the same id to the floor panel each cycle.
        -- Vanilla ISDropWorldItemAction:complete uses this same pattern.
        local worldItem = dropSquare:AddWorldInventoryItem(item, dx, dy, dz, false)
        if worldItem and worldItem.getWorldItem and worldItem:getWorldItem() then
            worldItem:getWorldItem():setIgnoreRemoveSandbox(true)
            if worldItem:getWorldItem().transmitCompleteItemToClients then
                worldItem:getWorldItem():transmitCompleteItemToClients()
            end
        end
        SaucedCarts.debug(function() return string.format(
            "performCartTransfer: dropped item %d onto square (%d,%d,%d)",
            item:getID(), dropSquare:getX(), dropSquare:getY(), dropSquare:getZ()
        ) end)
        return true
    end

    -- === Container → container (cart ↔ inv, cart ↔ cart) ===
    if not srcContainer or not destContainer then return false end
    -- v2.1.14 vanilla parity: vanilla's server-side consistency check
    -- (TransactionManager.isConsistent:264) EXEMPTS destinations parented
    -- to a BaseVehicle from capacity rejection — the client's own check is
    -- the only vanilla gate for vehicle containers. Being stricter than
    -- vanilla broke transfers into modded vehicles whose authoritative
    -- capacity is item-backed/runtime-set (KI5: script says 75, installed
    -- damnCraft.Trunk item says 25, uninstalled racks say 0).
    local destParent = destContainer.getParent and destContainer:getParent()
    local destIsVehicle = destParent and instanceof and instanceof(destParent, "BaseVehicle")
    if not destIsVehicle
        and destContainer.hasRoomFor and not destContainer:hasRoomFor(player, item) then
        -- .log not .debug: a silent capacity refusal on a dedi is
        -- indistinguishable from "the mod is broken" (this exact bail hid
        -- the equipParent gate for an entire report cycle).
        SaucedCarts.log(function() return string.format(
            "performCartTransfer: dest type=%s has no room for item %s "
            .. "(capacityWeight=%.2f)",
            tostring(destContainer.getType and destContainer:getType() or "?"),
            tostring(item.getID and item:getID() or "?"),
            (destContainer.getCapacityWeight and destContainer:getCapacityWeight()) or -1)
        end)
        return false
    end

    ISTransferAction:transferItem(player, item, srcContainer, destContainer, nil)

    if isServer() and type(sendAddItemToContainer) == "function" then
        sendAddItemToContainer(destContainer, item)
    end

    -- Repair either side that vanilla's helpers could not address. The
    -- source side is the reported case: a bag nested in a vehicle trunk
    -- gets its removal packet silently dropped, leaving every client
    -- showing an item the server has already moved.
    -- vanilla's transferItem already broadcast the remove, and we sent the
    -- add above; both drop silently for a container vanilla cannot address.
    repairContainerUpdate(sendRemoveItemFromContainer, srcContainer, item, player)
    repairContainerUpdate(sendAddItemToContainer, destContainer, item, player)

    -- Mark both containers dirty so the inventory panel repaints on its
    -- next tick. Without this, SP (and client-authoritative MP) transfers
    -- to an equipped cart leave the UI showing stale item lists + weight
    -- until the panel is closed/reopened. Vanilla ISInventoryTransfer
    -- relies on internal dirty flags set inside TransactionManager which
    -- we deliberately skip, so we do it manually here.
    if srcContainer.setDrawDirty  then srcContainer:setDrawDirty(true)  end
    if destContainer.setDrawDirty then destContainer:setDrawDirty(true) end

    -- Restore loot-respawn eligibility on the SOURCE container. B42's
    -- LootRespawn only refills a world container when BOTH `explored` AND
    -- `hasBeenLooted` are set (LootRespawn.java:142 —
    -- `container.explored && container.isHasBeenLooted()`). Vanilla sets
    -- `hasBeenLooted=true` only in RemoveInventoryItemFromContainerPacket.
    -- processServer (:110) and Transaction (:153) — BOTH of which we route
    -- around: our removal goes through ISTransferAction:transferItem ->
    -- ItemContainer.DoRemoveItem (touches neither flag) + GameServer.send-
    -- RemoveItemFromContainer (a pure outbound broadcast, never runs
    -- processServer). So looting straight into a cart leaves the source at
    -- hasBeenLooted=false forever and that container silently stops
    -- respawning loot. Mirror vanilla's processServer here. Server/SP only:
    -- LootRespawn.update is gated on !GameClient.client, and the flag isn't
    -- meaningful on a remote client's local container copy. Harmless on
    -- non-world sources (player inv / cart / bag) — the respawn loop only
    -- scans containers attached to world IsoObjects, exactly as vanilla
    -- sets these flags unconditionally on any transfer source.
    if not isClient() and srcContainer.setHasBeenLooted then
        srcContainer:setExplored(true)
        srcContainer:setHasBeenLooted(true)
    end

    -- Refresh content-display furniture sprites (bookcase showing books,
    -- fridge/freezer, stacked crates). Vanilla ISInventoryTransferAction:
    -- transferItem does this via ItemPicker.updateOverlaySprite on the
    -- containers' parent IsoObjects (ISInventoryTransferAction.lua:661-668,
    -- server/SP only). We bypass that action entirely, so without this the
    -- shelf/fridge/box sprite never updates after a cart transfer.
    -- setDrawDirty above only repaints the inventory panel, not the world
    -- object's overlay sprite.
    if not isClient() and ItemPicker and ItemPicker.updateOverlaySprite then
        local sp = srcContainer.getParent and srcContainer:getParent()
        if sp and sp.getOverlaySprite and sp:getOverlaySprite() then
            ItemPicker.updateOverlaySprite(sp)
        end
        local dp = destContainer.getParent and destContainer:getParent()
        if dp then
            ItemPicker.updateOverlaySprite(dp)
        end
    end

    SaucedCarts.debug(function() return string.format(
        "performCartTransfer: moved item %d from container type=%s -> type=%s",
        item:getID(),
        tostring(srcContainer:getType()),
        tostring(destContainer:getType())
    ) end)
    return true
end

-- ============================================================================
-- VISUAL REFRESH CHOKEPOINT (v2.1.14)
-- ============================================================================
-- performCartTransfer is the single funnel every cart move goes through:
-- SP local perform, dedi handleCartTransfer, and the dedi's double-perform
-- else-branch. The event that used to drive visual updates
-- (onCartContentsChanged, fired from a hook on vanilla
-- ISInventoryTransferAction.perform in VisualUpdateQueue) went dead when the
-- interceptor became universal in v2.1.4 — cart transfers never run the
-- vanilla action, so ground carts only repainted once the pushing
-- reconciler in CartStateHandler caught the drift. Refreshing here is
-- server-authoritative: fill state is computed from post-move state, and
-- updateCartVisual's own no-change short-circuit makes the dedi
-- double-perform and per-batch-item repeats free.
do
    local coreTransfer = SaucedCarts.performCartTransfer
    SaucedCarts.performCartTransfer = function(player, item, srcContainer, destContainer, dropSquare, srcSquare)
        local ok = coreTransfer(player, item, srcContainer, destContainer, dropSquare, srcSquare)
        if ok then
            pcall(function()
                local srcCart  = containerToCart(srcContainer)
                local destCart = containerToCart(destContainer)
                if srcCart and SaucedCarts.updateCartVisual then
                    SaucedCarts.updateCartVisual(srcCart, player)
                end
                if destCart and destCart ~= srcCart and SaucedCarts.updateCartVisual then
                    SaucedCarts.updateCartVisual(destCart, player)
                end
            end)
        end
        return ok
    end
end

-- Backwards-compat alias for anything still calling performCartDeposit.
SaucedCarts.performCartDeposit = function(player, item, cartItem)
    if not player or not item or not cartItem then return false end
    local srcContainer = item.getContainer and item:getContainer()
    local destContainer = cartItem.getItemContainer and cartItem:getItemContainer()
    if not srcContainer or not destContainer then return false end
    return SaucedCarts.performCartTransfer(player, item, srcContainer, destContainer)
end

-- ============================================================================
-- CART / ITEM LOOKUP (SERVER SIDE)
-- ============================================================================

--- Find a cart InventoryItem by ID. Mirrors vanilla's `ContainerID.findObject`
--- resolution paths (ContainerID.java:370-488). Tries, in order:
---   1. `inv:getItemWithIDRecursiv(cartId)` — vanilla's recursive walk of the
---      player's inventory tree. Handles equipped + nested cases in one Java
---      call (vanilla uses this exact method for InventoryContainer kind).
---   2. Vehicle scan — when the player is sitting in a vehicle, iterate part
---      containers (mirrors vanilla's ObjectInVehicle path). Covers carts
---      stowed in a trunk while the player is in the cab.
---   3. Bounded ground sweep — `IsoWorldInventoryObject` on tiles around the
---      player. Vanilla doesn't do this because its ContainerID carries the
---      exact tile coords; we still sweep because our payload only carries
---      `cartId` (a bare number). Kept tight to bound a server-side walk on
---      hostile input.
---
---@param player IsoPlayer
---@param cartId number
---@param radius number|nil  default 4 (slightly wider than the loot pane's
---                          ~2-tile reach so a player who walked a step or
---                          two from a dropped cart can still transfer)
---@return InventoryItem|nil
local function findCartNearPlayer(player, cartId, radius)
    radius = radius or 4
    if not player then return nil end

    -- (1) Recursive inv lookup — same primitive vanilla uses for
    -- InventoryContainer kind.
    local inv = player:getInventory()
    if inv and inv.getItemWithIDRecursiv then
        local it = inv:getItemWithIDRecursiv(cartId)
        if it and SaucedCarts.safeIsCart(it) then return it end
    end
    -- Fallback for older PZ builds where getItemWithIDRecursiv may not
    -- exist — keep the v2.1.5 non-recursive path so we never regress.
    if inv and inv.getItemById then
        local it = inv:getItemById(cartId)
        if it and SaucedCarts.safeIsCart(it) then return it end
    end

    -- (2) Vehicle parts — when the player is in a vehicle, scan its part
    -- containers for a cart with this id (e.g. cart stowed in trunk).
    -- Mirrors vanilla's ObjectInVehicle resolution path.
    if player.getVehicle then
        local veh = player:getVehicle()
        if veh and veh.getPartCount then
            local n = veh:getPartCount()
            for i = 0, n - 1 do
                local part = veh:getPartByIndex(i)
                local pc = part and part.getItemContainer and part:getItemContainer()
                if pc and pc.getItemWithIDRecursiv then
                    local it = pc:getItemWithIDRecursiv(cartId)
                    if it and SaucedCarts.safeIsCart(it) then return it end
                end
            end
        end
    end

    -- (3) Ground sweep around the player.
    local psq = player:getCurrentSquare()
    if not psq then return nil end
    for dy = -radius, radius do
        for dx = -radius, radius do
            local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
            if sq then
                local objs = sq:getWorldObjects()
                if objs then
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if instanceof(o, "IsoWorldInventoryObject") then
                            local it = o:getItem()
                            if it and it:getID() == cartId and SaucedCarts.safeIsCart(it) then
                                return it
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- Find an InventoryItem by ID in a container, recursing into any nested
--- inner containers (e.g., a backpack inside a backpack). Used to resolve a
--- bag the client references by ID when it could be at any depth in the
--- player's inventory tree.
---@param container ItemContainer|nil
---@param itemId number
---@return InventoryItem|nil
local function findInventoryItemRecursive(container, itemId)
    if not container then return nil end
    local direct = container.getItemById and container:getItemById(itemId)
    if direct then return direct end
    local items = container.getItems and container:getItems()
    if items then
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it and it.getItemContainer then
                local inner = it:getItemContainer()
                if inner then
                    local found = findInventoryItemRecursive(inner, itemId)
                    if found then return found end
                end
            end
        end
    end
    return nil
end

--- Find any item by ID starting from the player's reachable surfaces — their
--- own inventory first, then nearby floor squares, then nearby carts' inner
--- containers (needed for `direction="out"` where the item lives inside a
--- cart, not in the player's inventory or on the ground).
---@param player IsoPlayer
---@param itemId number
---@param radius number|nil  default 3
---@return InventoryItem|nil
local function findItemNearPlayer(player, itemId, radius)
    radius = radius or 3
    if not player then return nil end

    -- Recurse through the player's inventory tree — covers main inv + any
    -- nested bags (equipped backpack, satchel, bag-in-bag). Pre-fix this was
    -- a flat getItemById which missed items inside bags.
    local inv = player:getInventory()
    local it = findInventoryItemRecursive(inv, itemId)
    if it then return it end

    -- Check in-hand carts explicitly — the recursive helper above traverses
    -- every item in inv and its nested containers, which technically also
    -- covers carts-in-inv. Keeping this branch here for readability and to
    -- match the ground-cart symmetry below.
    if inv then
        local allItems = inv:getItems()
        if allItems then
            for i = 0, allItems:size() - 1 do
                local itIn = allItems:get(i)
                if itIn and SaucedCarts.safeIsCart(itIn) and itIn.getItemContainer then
                    local innerCont = itIn:getItemContainer()
                    if innerCont and innerCont.getItemById then
                        local inside = innerCont:getItemById(itemId)
                        if inside then return inside end
                    end
                end
            end
        end
    end

    local psq = player:getCurrentSquare()
    if not psq then return nil end
    for dy = -radius, radius do
        for dx = -radius, radius do
            local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
            if sq then
                local objs = sq:getWorldObjects()
                if objs then
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if instanceof(o, "IsoWorldInventoryObject") then
                            local groundItem = o:getItem()
                            if groundItem then
                                if groundItem:getID() == itemId then return groundItem end
                                -- Descend into ANY dropped container item's
                                -- inner container — cart, backpack, duffel,
                                -- crate, etc. Pre-fix this was gated to carts
                                -- (safeIsCart), so an item inside a BAG lying on
                                -- the ground was never located by id → the MP
                                -- server reconstruction bailed at "item NOT
                                -- FOUND" and the transfer silently no-op'd. (SP
                                -- uses the live container ref in :perform's
                                -- else-branch and was never affected.)
                                if groundItem.getItemContainer then
                                    local innerCont = groundItem:getItemContainer()
                                    if innerCont and innerCont.getItemById then
                                        local inside = innerCont:getItemById(itemId)
                                        if inside then return inside end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- v2.1.7: scan vehicle part containers — when the player is in / next
    -- to a vehicle and the item lives in the trunk, glovebox, seats, or
    -- trailer bed. Symmetric counterpart to findCartNearPlayer's vehicle
    -- scan. Without this, trunk → cart silently bails at the item lookup
    -- (item not findable in player inv / ground / world containers), the
    -- "not found" log is .debug() → suppressed on dedi → invisible. Mirrors
    -- vanilla ContainerID.ObjectInVehicle resolution.
    if player.getVehicle then
        local veh = player:getVehicle()
        if veh and veh.getPartCount and veh.getPartByIndex then
            for i = 0, veh:getPartCount() - 1 do
                local part = veh:getPartByIndex(i)
                if part and part.getItemContainer then
                    local pc = part:getItemContainer()
                    if pc and pc.getItemById then
                        local inside = pc:getItemById(itemId)
                        if inside then return inside end
                    end
                end
            end
        end
    end
    -- Also scan vehicles intersecting nearby tiles (player adjacent to a
    -- vehicle but not seated — opens trunk from outside). Use vanilla's
    -- per-square `getVehicleContainer()` which returns the BaseVehicle
    -- whose body intersects that square (IsoGridSquare.java:10420). Avoid
    -- `IsoCell.getVehicles()` because it returns a Java Set without
    -- indexed access — `:get(i)` throws RuntimeException.
    local seenVehicles = {}
    for dy = -radius, radius do
        for dx = -radius, radius do
            local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
            if sq and sq.getVehicleContainer then
                local veh = sq:getVehicleContainer()
                if veh and not seenVehicles[veh] and veh.getPartCount and veh.getPartByIndex then
                    seenVehicles[veh] = true
                    for j = 0, veh:getPartCount() - 1 do
                        local part = veh:getPartByIndex(j)
                        if part and part.getItemContainer then
                            local pc = part:getItemContainer()
                            if pc and pc.getItemById then
                                local inside = pc:getItemById(itemId)
                                if inside then return inside end
                            end
                        end
                    end
                end
            end
        end
    end

    -- v2.1.5: scan world containers (shelves / freezers / barbecues / etc.)
    -- on nearby squares. Required for the "container-cart" transfer case —
    -- without this, the item lookup fails before we ever reach resolveSide.
    -- getObjects() returns tile objects; getWorldObjects() above returns
    -- dropped InventoryItems — both need scanning for different reasons.
    --
    -- v2.1.6: iterate ALL containers per object via getContainerCount +
    -- getContainerByIndex. obj:getContainer() returns ONLY the first
    -- container — for multi-container tiles (fridges have fridge+freezer,
    -- some counters have multiple cells, double-door wardrobes, etc.) the
    -- item might live in container index 1+. Vanilla ContainerID.findObject
    -- uses the same pattern via ObjectContainer kind. Without this loop,
    -- freezer→cart silently fails because findItemNearPlayer only ever
    -- looks at the fridge half. Confirmed via dedi log on 2026-04-28.
    for dy = -radius, radius do
        for dx = -radius, radius do
            local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
            if sq then
                local tileObjs = sq:getObjects()
                if tileObjs then
                    for i = 0, tileObjs:size() - 1 do
                        local obj = tileObjs:get(i)
                        if obj then
                            local nContainers = obj.getContainerCount and obj:getContainerCount() or 0
                            for ci = 0, nContainers - 1 do
                                local cont = obj.getContainerByIndex and obj:getContainerByIndex(ci)
                                if cont and cont.getItemById then
                                    local inside = cont:getItemById(itemId)
                                    if inside then return inside end
                                end
                            end
                            -- Belt-and-suspenders: also try the legacy
                            -- single-container API for objects whose
                            -- getContainerCount returns 0 but whose
                            -- getContainer() does return something.
                            if nContainers == 0 and obj.getContainer then
                                local cont = obj:getContainer()
                                if cont and cont.getItemById then
                                    local inside = cont:getItemById(itemId)
                                    if inside then return inside end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- v2.1.11: scan nearby dead bodies' loot containers. Looting an item from a
    -- zombie/corpse into a held cart is an "in" transfer whose src is the
    -- corpse's ItemContainer (IsoDeadBody:getContainer()). Corpses live in
    -- sq:getDeadBodys(), NOT getObjects()/getWorldObjects(), so every scan above
    -- misses them — without this, corpse -> cart silently no-ops in MP (the
    -- server can't locate the item; the "not found" log is .debug(), suppressed
    -- on dedi). Once found, the "in" defensive fallback (item:getContainer())
    -- recovers the corpse as the real src container. SP uses the live captured
    -- ref in :perform's else-branch and was never affected.
    for dy = -radius, radius do
        for dx = -radius, radius do
            local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
            if sq and sq.getDeadBodys then
                local bodies = sq:getDeadBodys()
                if bodies then
                    for i = 0, bodies:size() - 1 do
                        local body = bodies:get(i)
                        local cont = body and body.getContainer and body:getContainer()
                        if cont and cont.getItemById then
                            local inside = cont:getItemById(itemId)
                            if inside then return inside end
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- ============================================================================
-- SERVER HANDLER
-- ============================================================================

local function handleCartTransfer(player, args)
    if not player then return end
    -- Entry trace — .debug() so it doesn't spam dedi logs in normal play.
    -- Promote to .log() when chasing the next "transfer animates but item
    -- doesn't move" report; .debug() is suppressed on dedicated servers.
    SaucedCarts.debug(function() return string.format(
        "handleCartTransfer: ENTERED direction=%s srcKind=%s destKind=%s itemId=%s cartId=%s srcCartId=%s srcObjIdx=%s",
        tostring(args and args.direction),
        tostring(args and args.srcKind),
        tostring(args and args.destKind),
        tostring(args and args.itemId),
        tostring(args and args.cartId),
        tostring(args and args.srcCartId),
        tostring(args and args.srcObjIdx)
    ) end)
    if not args or not args.itemId or not args.cartId then
        SaucedCarts.debug("cartTransfer: invalid args (missing itemId or cartId)")
        return
    end

    -- Network-boundary type validation. The nil-check above only rejects
    -- MISSING fields; a modified / buggy / pre-version client can still send
    -- a non-numeric id. getItemById / getItemWithIDRecursiv / getGridSquare
    -- are Java methods that require numeric args — passing a String throws an
    -- uncaught server-side RuntimeException that aborts the handler. Coerce
    -- every numeric field here (the one place client input enters) and reject
    -- if the two required ids aren't numbers. (Regression: probe-cart-
    -- transfer-fuzz G10 / OfflineCartDepositTests malformed gauntlet.)
    args.itemId = tonumber(args.itemId)
    args.cartId = tonumber(args.cartId)
    if not args.itemId or not args.cartId then
        SaucedCarts.debug("cartTransfer: non-numeric itemId/cartId — rejected")
        return
    end
    args.srcCartId   = tonumber(args.srcCartId)
    args.destCartId  = tonumber(args.destCartId)
    args.srcObjIdx   = tonumber(args.srcObjIdx)
    args.srcContIdx  = tonumber(args.srcContIdx)
    args.destObjIdx  = tonumber(args.destObjIdx)
    args.destContIdx = tonumber(args.destContIdx)
    args.srcSqX  = tonumber(args.srcSqX);  args.srcSqY  = tonumber(args.srcSqY);  args.srcSqZ  = tonumber(args.srcSqZ)
    args.destSqX = tonumber(args.destSqX); args.destSqY = tonumber(args.destSqY); args.destSqZ = tonumber(args.destSqZ)
    if type(args.itemIds) == "table" then
        local clean = {}
        for i = 1, #args.itemIds do
            local n = tonumber(args.itemIds[i])
            if n then clean[#clean + 1] = n end
        end
        args.itemIds = clean
    end

    -- NOTE: bail-path logs below use .debug() so they don't spam dedi
    -- logs in normal play. Promote to .log() temporarily when chasing
    -- a "transfer animates but item doesn't move" report — the per-bail
    -- diagnostics (player position, vehicle state, srcKind/destKind,
    -- container resolution) pin which path is failing in ~one repro.
    local cart = findCartNearPlayer(player, args.cartId)
    if not cart then
        SaucedCarts.log(function()
            local psq = player.getCurrentSquare and player:getCurrentSquare()
            local sqStr = psq and (psq:getX() .. "," .. psq:getY() .. "," .. psq:getZ()) or "nil"
            local invSize = (player.getInventory and player:getInventory() and player:getInventory().getItems
                and player:getInventory():getItems():size()) or -1
            local inVeh = (player.getVehicle and player:getVehicle()) and "yes" or "no"
            return string.format(
                "cartTransfer: cart %s NOT FOUND for player at (%s) invSize=%d inVehicle=%s direction=%s srcKind=%s destKind=%s",
                tostring(args.cartId), sqStr, invSize, inVeh,
                tostring(args.direction), tostring(args.srcKind), tostring(args.destKind))
        end)
        return
    end

    -- v2.1.14: item lookup moved AFTER side resolution — the client already
    -- told us which container the item is in; looking there first (instead
    -- of proximity sweeps) survives long rigs and odd positions.

    local cartContainer = cart.getItemContainer and cart:getItemContainer()
    local playerInv = player:getInventory()
    if not cartContainer or not playerInv then
        SaucedCarts.debug(function() return string.format(
            "cartTransfer: bail — cartContainer=%s playerInv=%s (cart=%s)",
            tostring(cartContainer), tostring(playerInv), tostring(args.cartId))
        end)
        return
    end

    -- Resolve a side of the transfer (src or dest) based on the client's
    -- classification. Returns (container, square-or-nil). For the floor
    -- case, the container is the floor ItemContainer on the player's
    -- square and the square is what vanilla ISTransferAction needs to
    -- do a proper world drop / world pickup.
    local function resolveSide(kind, cartId, sqX, sqY, sqZ, containerType, isSrc, objIndex, contIndex)
        if kind == "floor" then
            local sq = nil
            if sqX and sqY and sqZ then
                sq = getCell() and getCell():getGridSquare(sqX, sqY, sqZ)
            end
            if not sq then sq = player:getCurrentSquare() end
            return nil, sq
        end
        if kind == "cart" and cartId then
            local c = findCartNearPlayer(player, cartId)
            if c and c.getItemContainer then
                return c:getItemContainer(), nil
            end
        end
        -- Bag kind — inner container of a non-cart InventoryItem in the
        -- player's inventory (equipped backpack, satchel, holster, etc.).
        -- cartId is reused as the containing-item's ID. Recurse because the
        -- bag may live nested inside another bag.
        if kind == "bag" and cartId then
            -- The containing bag item — first in the player's inventory tree
            -- (worn/carried bag, possibly nested), then on nearby reachable
            -- surfaces (a bag lying on the floor). The ground fallback fixes
            -- the "out" direction (cart -> dropped bag), which — unlike "in" —
            -- has NO item:getContainer() recovery downstream, so without it the
            -- item lands in the player's main inventory instead of the bag.
            local bagItem = findInventoryItemRecursive(player:getInventory(), cartId)
                or findItemNearPlayer(player, cartId)
            if bagItem and bagItem.getItemContainer then
                local c = bagItem:getItemContainer()
                if c then return c, nil end
            end
            -- HARD FAIL (v2.1.16): same reasoning as the vehicle branch in
            -- v2.1.14. Substituting playerInv here is never right — the bag
            -- is a real container the client pointed at, and pretending it
            -- was the main inventory either misdelivers cart items into the
            -- player's pockets (direction "out") or hands performCartTransfer
            -- a source that doesn't hold the item (direction "in", the old
            -- v2.1.4 dupe shape). Refusing lets direction "in" fall back to
            -- the item's own container, which IS authoritative.
            SaucedCarts.log(function() return string.format(
                "resolveSide: bag item %s NOT FOUND in inv or nearby — refusing to substitute playerInv",
                tostring(cartId)) end)
            return nil, nil, true
        end
        -- Vehicle kind — VehiclePart container on a BaseVehicle (trunk,
        -- glovebox, seats, trailer bed). Mirrors vanilla ContainerID.find-
        -- Object's `Vehicle` branch (ContainerID.java:444-459): look up the
        -- vehicle by id, then resolve the part by index. cartId carries the
        -- vehicle id; objIndex carries the part index.
        if kind == "vehicle" and cartId and objIndex then
            -- CHANNEL 1: the id map. Try the canonical Lua global first;
            -- fall back to VehicleManager in case `getVehicleById` isn't yet
            -- defined at this point in load order on some builds.
            local veh
            if getVehicleById then veh = getVehicleById(cartId) end
            if not veh and VehicleManager and VehicleManager.instance
                and VehicleManager.instance.getVehicleByID then
                veh = VehicleManager.instance:getVehicleByID(cartId)
            end
            -- CHANNEL 2 (v2.1.14): square sweep around the client-supplied
            -- vehicle position, then around the player. Runtime-spawned
            -- vehicles (admin /addvehicle — AddVehicleCommand constructs
            -- BaseVehicle directly and never registers it; healed only by a
            -- server restart) are invisible to the id map but reachable via
            -- sq:getVehicleContainer(), which walks chunk vehicle lists.
            -- Root cause of the "cart works with the trunk but not the
            -- trailer until the server restarts" reports.
            if not veh then
                local centers = {}
                if sqX and sqY and sqZ then centers[#centers + 1] = { sqX, sqY, sqZ } end
                local psq = player:getCurrentSquare()
                if psq then centers[#centers + 1] = { psq:getX(), psq:getY(), psq:getZ() } end
                local seen = {}
                for _, ctr in ipairs(centers) do
                    for dy = -6, 6 do
                        for dx = -6, 6 do
                            local sq = getCell() and getCell():getGridSquare(ctr[1] + dx, ctr[2] + dy, ctr[3])
                            local v = sq and sq.getVehicleContainer and sq:getVehicleContainer()
                            if v and not seen[tostring(v)] then
                                seen[tostring(v)] = true
                                if v.getId and v:getId() == cartId then
                                    veh = v
                                    break
                                end
                            end
                        end
                        if veh then break end
                    end
                    if veh then break end
                end
                if veh then
                    SaucedCarts.log(function() return string.format(
                        "resolveSide: vehicle %s recovered via square sweep (not in id map — runtime-spawned?)",
                        tostring(cartId)) end)
                end
            end
            if veh and veh.getPartByIndex then
                local part = veh:getPartByIndex(objIndex)
                if part and part.getItemContainer then
                    local c = part:getItemContainer()
                    if c then return c, nil end
                end
            end
            -- HARD FAIL (v2.1.14): a vehicle side that doesn't resolve must
            -- NOT silently fall through to playerInv — for direction "out"
            -- that misdelivers cart items into the player's main inventory.
            SaucedCarts.log(function() return string.format(
                "resolveSide: vehicle %s part %s UNRESOLVED (id map + square sweep both missed)",
                tostring(cartId), tostring(objIndex)) end)
            return nil, nil, true
        end
        -- v2.1.5/2.1.6: world container — the client told us this side is a
        -- shelf / freezer / fridge / barbecue / wardrobe / etc. bound to an
        -- IsoObject on a specific tile. Iterate the square's objects and
        -- match the container by type. v2.1.5 used obj:getContainer() which
        -- is the LEGACY single-container API and only returned the FIRST
        -- container per object — multi-container objects (fridges have
        -- fridge+freezer; some counters have multiple cells; double-door
        -- wardrobes; some workbenches) silently failed to match the freezer
        -- side. v2.1.6 uses getContainerByType + iterates all containers via
        -- getContainerCount + getContainerByIndex (mirrors vanilla
        -- ContainerID.findObject's ObjectContainer path). Confirmed via dedi
        -- log on 2026-04-28: fridge→cart-on-ground was hitting the wrong
        -- side and silently failing item lookup.
        if kind == "world" and sqX and sqY and sqZ and containerType then
            local sq = getCell() and getCell():getGridSquare(sqX, sqY, sqZ)
            if sq then
                local objs = sq:getObjects()
                -- Precise path (v2.1.7): resolve the EXACT object + container
                -- the client clicked, via parent object index + container
                -- index within that object. This is what disambiguates two
                -- stacked crates / a fridge's fridge+freezer that share the
                -- same (tile, container type). Mirrors vanilla
                -- ISInventoryPage.lua:1405-1410. Falls through to the legacy
                -- type-match below when the client didn't send indices
                -- (old in-flight client) or they don't resolve.
                if objs and objIndex ~= nil then
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj and obj.getObjectIndex
                            and obj:getObjectIndex() == objIndex then
                            if contIndex ~= nil and obj.getContainerByIndex then
                                local cont = obj:getContainerByIndex(contIndex)
                                if cont then return cont, nil end
                            end
                            if obj.getContainerByType and containerType then
                                local cont = obj:getContainerByType(containerType)
                                if cont then return cont, nil end
                            end
                            break
                        end
                    end
                    SaucedCarts.debug(function() return string.format(
                        "resolveSide: indexed object/container (%s/%s) not resolved at (%s,%s,%s); falling back to type-match",
                        tostring(objIndex), tostring(contIndex),
                        tostring(sqX), tostring(sqY), tostring(sqZ)
                    ) end)
                end
                if objs then
                    -- Fast path: getContainerByType matches by type directly.
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj and obj.getContainerByType then
                            local cont = obj:getContainerByType(containerType)
                            if cont then return cont, nil end
                        end
                    end
                    -- Slow path: walk every container on every object via
                    -- getContainerCount + getContainerByIndex. Catches the
                    -- case where getContainerByType is missing or the type
                    -- string disagrees subtly (different builds / mods).
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj then
                            local n = obj.getContainerCount and obj:getContainerCount() or 0
                            for ci = 0, n - 1 do
                                local cont = obj.getContainerByIndex and obj:getContainerByIndex(ci)
                                if cont and cont.getType and cont:getType() == containerType then
                                    return cont, nil
                                end
                            end
                        end
                    end
                end
            end
            SaucedCarts.debug(function() return string.format(
                "resolveSide: world container (%s) NOT FOUND at (%s,%s,%s); falling back to playerInv",
                tostring(containerType), tostring(sqX), tostring(sqY), tostring(sqZ)
            ) end)
        end
        return playerInv, nil
    end

    -- Plug in the cart reference (the "main" cart for this transfer) on
    -- whichever side has direction set to it.
    local srcContainer, destContainer, srcSquare, dropSquare
    local srcFailed, destFailed
    if args.direction == "out" then
        srcContainer = cartContainer
        destContainer, dropSquare, destFailed = resolveSide(
            args.destKind, args.destCartId,
            args.destSqX, args.destSqY, args.destSqZ,
            args.destContType, false, args.destObjIdx, args.destContIdx
        )
    else
        srcContainer, srcSquare, srcFailed = resolveSide(
            args.srcKind, args.srcCartId,
            args.srcSqX, args.srcSqY, args.srcSqZ,
            args.srcContType, true, args.srcObjIdx, args.srcContIdx
        )
        destContainer = cartContainer
    end

    -- v2.1.14: a destination that hard-failed to resolve must not be
    -- silently replaced with the player's inventory — that MISDELIVERS
    -- cart items into main inv (the old "my stuff went to my backpack"
    -- reports). Refusing loudly is strictly better: the item stays where
    -- it was and the log names the failure.
    if args.direction == "out" and destFailed then
        SaucedCarts.log(function() return string.format(
            "cartTransfer (out): destination %s/%s UNRESOLVED — refusing (item stays in cart)",
            tostring(args.destKind), tostring(args.destCartId)) end)
        return
    end

    -- v2.1.14: client-routed item lookup FIRST — the resolved source (or
    -- the cart, for "out") is where the client says the item lives. The
    -- proximity sweep becomes the fallback instead of the only channel.
    local item
    local routedSrc = (args.direction == "out") and cartContainer or srcContainer
    if routedSrc and routedSrc.getItemById then
        item = routedSrc:getItemById(args.itemId)
    end
    item = item or findItemNearPlayer(player, args.itemId)
    if not item then
        SaucedCarts.log(function() return string.format(
            "cartTransfer: item %s NOT FOUND (cart=%s direction=%s srcKind=%s destKind=%s srcResolved=%s)",
            tostring(args.itemId), tostring(args.cartId),
            tostring(args.direction), tostring(args.srcKind), tostring(args.destKind),
            tostring(srcContainer ~= nil))
        end)
        return
    end

    -- DEFENSIVE: handle old clients (pre-v2.1.5) that classify world
    -- containers as "inv" and send srcKind=inv for an item that's actually
    -- sitting in a shelf/freezer/etc. The bad srcContainer would cause
    -- performCartTransfer to run DoRemoveItem on the player's inventory
    -- (where the item isn't), so the source item never gets removed —
    -- visible as duplication: source keeps the item AND the cart gets a
    -- copy.
    --
    -- Recover by consulting the item's actual container. If it disagrees
    -- with what the client told us, use the real one.
    --
    -- IDEMPOTENCE: "Take All" UI batches + client retries can fire the
    -- same cartTransfer multiple times for the same itemId. After the
    -- first one succeeds, the item lives in destContainer; subsequent
    -- calls would see realSrc == destContainer and run performCartTransfer
    -- with src==dest, broadcasting a spurious remove+add cycle that hits
    -- clients with "container already has id" (Java AddItem rejecting the
    -- re-add). No-op in that case.
    if args.direction ~= "out" and item.getContainer then
        local realSrc = item:getContainer()
        if realSrc and realSrc == destContainer then
            SaucedCarts.debug(function() return string.format(
                "cartTransfer: item %s already in destination cart; no-op (duplicate send)",
                tostring(args.itemId)) end)
            return
        end
        -- v2.1.14: recovery no longer requires a resolved srcContainer —
        -- when the vehicle side hard-fails (runtime-spawned vehicle not in
        -- the id map), the item's own container IS the source of truth.
        if realSrc and realSrc ~= srcContainer then
            SaucedCarts.log(function() return string.format(
                "cartTransfer: client claimed srcKind=%s (%s), but item lives in %s — using real container",
                tostring(args.srcKind),
                tostring(srcContainer and srcContainer.getType and srcContainer:getType() or "unresolved"),
                tostring(realSrc.getType and realSrc:getType() or "?"))
            end)
            srcContainer = realSrc
        end
    end
    -- v2.1.15: refuse only when BOTH container and square are unknown.
    -- resolveSide("floor") returns (nil container, source square) BY
    -- CONTRACT — performCartTransfer's floor branch works from the square's
    -- world item, so a nil srcContainer with a live srcSquare is the normal
    -- floor→cart shape, not a failure. The v2.1.14 gate checked only
    -- srcContainer and refused every MP ground→cart pickup ("source
    -- floor/nil UNRESOLVED" in server logs).
    if args.direction ~= "out" and not srcContainer and not srcSquare then
        SaucedCarts.log(function() return string.format(
            "cartTransfer: source %s/%s UNRESOLVED and item container unknown — refusing",
            tostring(args.srcKind), tostring(args.srcCartId)) end)
        return
    end
    -- Symmetric idempotence for "out": if item is already in dest (another
    -- container we unloaded to), no-op. For "out" there's no reliable
    -- src recovery path since item:getContainer() can't help us pick a
    -- destination; just bail on duplicates.
    if args.direction == "out" and destContainer and item.getContainer then
        local realCont = item:getContainer()
        if realCont and realCont == destContainer then
            SaucedCarts.debug(function() return string.format(
                "cartTransfer (out): item %s already in destination; no-op",
                tostring(args.itemId)) end)
            return
        end
    end

    SaucedCarts.performCartTransfer(
        player, item, srcContainer, destContainer, dropSquare, srcSquare
    )

    -- v2.1.7: batched bulk transfer. The client coalesced a run of same-
    -- endpoint transfers (e.g. a stack of nails) into one command so it
    -- isn't N round-trips / N full-duration timed actions. Move the rest
    -- through the SAME resolved endpoints. canMergeAction guarantees they
    -- share src/dest/direction, so re-resolving containers per item is
    -- unnecessary; we only re-find the item by id and apply the same
    -- per-item idempotence (skip if it's already in the destination).
    if type(args.itemIds) == "table" and #args.itemIds > 1 then
        for i = 1, #args.itemIds do
            local id = args.itemIds[i]
            if id ~= args.itemId then
                local extra = (srcContainer and srcContainer.getItemById
                        and srcContainer:getItemById(id))
                    or findItemNearPlayer(player, id)
                if extra then
                    local already = extra.getContainer and extra:getContainer()
                    if already ~= destContainer then
                        SaucedCarts.performCartTransfer(
                            player, extra, srcContainer, destContainer,
                            dropSquare, srcSquare
                        )
                    end
                else
                    SaucedCarts.debug(function() return string.format(
                        "cartTransfer batch: item %s not found, skipping", tostring(id)
                    ) end)
                end
            end
        end
    end

    -- One anchored resync per affected container for the WHOLE command,
    -- after the batch loop — not one per item.
    SaucedCarts.flushContainerResync()

    -- Then one panel rebuild for the whole command, ordered AFTER the
    -- add/remove broadcasts so the client refreshes against post-move truth.
    -- This is the MP half of the aggregated-panel fix; the SP half runs
    -- locally at the end of ISCartTransferAction:perform.
    SaucedCarts.requestInventoryRefresh(player)
end

if SaucedCarts.Network and SaucedCarts.Network.registerServerHandler then
    -- Event-driven visual nudge: a client saw a NON-intercepted vanilla
    -- transfer touch a cart's real container (aggregated-view transfers use
    -- synthetic source containers, so classifyTransfer never matches and the
    -- repaint funnel is bypassed). No client state is trusted -- the server
    -- just recalcs fill and repaints if drifted, slightly delayed so the
    -- vanilla transaction's move lands first.
    SaucedCarts.Network.registerServerHandler("cartVisualNudge", function(player, args)
        if not args or not args.cartId then return end
        if SaucedCarts.queueGroundCartVisualNudge then
            SaucedCarts.queueGroundCartVisualNudge(
                args.cartId, args.squareX, args.squareY, args.squareZ, player)
        end
    end)
    SaucedCarts.Network.registerServerHandler("cartTransfer", handleCartTransfer)
    -- Keep the old command name alive so connected clients that were loaded
    -- before the update don't break mid-session.
    SaucedCarts.Network.registerServerHandler("depositToGroundCart", handleCartTransfer)
end

-- ============================================================================
-- INTERCEPTION HOOK
-- ============================================================================

local interceptionInstalled = false

-- ----------------------------------------------------------------------------
-- Third-party API early warning — runtime twin of OfflineApiContractTests.
-- Mods like Inventory Tetris patch methods onto ISInventoryTransferAction at
-- OnGameBoot and then call them on whatever :new returns — including our
-- substituted ISCartTransferAction. The offline kit can never see those
-- methods (no Workshop mods loaded), so: snapshot vanilla's method set at
-- file load (before third-party boot patches), diff after boot, and log any
-- boot-time addition our class doesn't expose. Turns the next foreign-method
-- crash ("Object tried to call nil") into a greppable log line instead of a
-- player report. Baseline-diff keeps this noise-free: methods vanilla itself
-- defines are the offline contract test's jurisdiction, not this audit's.
-- ----------------------------------------------------------------------------
local actionMethodBaseline = nil

local function snapshotActionMethodBaseline()
    if not ISInventoryTransferAction then return end
    actionMethodBaseline = {}
    for k, v in pairs(ISInventoryTransferAction) do
        if type(v) == "function" then actionMethodBaseline[k] = true end
    end
end

local function auditForeignActionMethods()
    if not actionMethodBaseline then return end
    if not (ISInventoryTransferAction and ISCartTransferAction) then return end
    local missing = {}
    for k, v in pairs(ISInventoryTransferAction) do
        if type(v) == "function"
           and not actionMethodBaseline[k]
           and type(ISCartTransferAction[k]) ~= "function" then
            table.insert(missing, k)
        end
    end
    if #missing > 0 then
        table.sort(missing)
        SaucedCarts.log(
            "CartTransferInterceptor: another mod added method(s) to "
            .. "ISInventoryTransferAction that ISCartTransferAction does not "
            .. "expose: " .. table.concat(missing, ", ")
            .. " -- that mod may call these on our substituted action and "
            .. "crash. Add a shim (see VANILLA & THIRD-PARTY API SHIMS in "
            .. "ISCartTransferAction.lua).")
    end
end

local function installInterception()
    if interceptionInstalled then return end
    if not ISInventoryTransferAction or not ISInventoryTransferAction.new then
        SaucedCarts.debug("CartTransferInterceptor: ISInventoryTransferAction not present (expected on dedicated server)")
        return
    end
    interceptionInstalled = true

    local originalNew = ISInventoryTransferAction.new
    ISInventoryTransferAction.new = function(self, character, item, srcContainer, destContainer, time, fast, allowMissingItems)
        local direction, cart
        local ok = pcall(function()
            direction, cart = classifyTransfer(srcContainer, destContainer)
        end)
        if ok and direction and cart then
            return ISCartTransferAction:new(
                character, item, srcContainer, destContainer,
                direction, cart, time
            )
        end
        return originalNew(self, character, item, srcContainer, destContainer, time, fast, allowMissingItems)
    end

    SaucedCarts.log("CartTransferInterceptor: hooked ISInventoryTransferAction.new (src-or-dest cart matching)")

    -- MP clients only: watch VANILLA transfers for cart involvement that the
    -- .new hook cannot see. Aggregated views (CleanUI/Proximity loot panels,
    -- Tetris aggregate grids) pass a SYNTHETIC source container, so the
    -- substitution above never fires -- but at transferItem time the ITEM
    -- knows its real container. When a real cart container is on either
    -- side, nudge the server to recalc that cart's visual. Throttled per
    -- cart; SP and dedi are covered by the funnel and never install this.
    if isClient() and ISInventoryTransferAction.transferItem then
        local origTransferItem = ISInventoryTransferAction.transferItem
        local lastNudgeMs = {}
        local function realCartOf(container)
            if not container or not container.getContainingItem then return nil end
            local it = container:getContainingItem()
            if it and SaucedCarts.safeIsCart(it) then return it end
            return nil
        end
        local function nudge(cart)
            if not cart then return end
            local id = cart:getID()
            local now = getTimestampMs and getTimestampMs() or 0
            if lastNudgeMs[id] and (now - lastNudgeMs[id]) < 400 then return end
            lastNudgeMs[id] = now
            local wi = cart:getWorldItem()
            local sq = wi and wi:getSquare()
            local p = getSpecificPlayer(0)
            if p and SaucedCarts.Network and SaucedCarts.Network.sendToServer then
                SaucedCarts.Network.sendToServer(p, "cartVisualNudge", {
                    cartId = id,
                    squareX = sq and sq:getX() or nil,
                    squareY = sq and sq:getY() or nil,
                    squareZ = sq and sq:getZ() or nil,
                })
            end
        end
        ISInventoryTransferAction.transferItem = function(self, item, ...)
            local srcCart
            pcall(function()
                srcCart = realCartOf(item and item:getContainer())
            end)
            local result = origTransferItem(self, item, ...)
            pcall(function()
                nudge(srcCart or realCartOf(item and item:getContainer()))
            end)
            return result
        end
        SaucedCarts.log("CartTransferInterceptor: vanilla transferItem nudge armed (client)")
    end
end

if ISInventoryTransferAction and ISInventoryTransferAction.new then
    snapshotActionMethodBaseline()
    local ok, err = pcall(installInterception)
    if not ok then
        SaucedCarts.error("CartTransferInterceptor: load-time install FAILED: " .. tostring(err))
    end
end

if Events.OnServerStarted and Events.OnServerStarted.Add then
    Events.OnServerStarted.Add(installInterception)
    Events.OnServerStarted.Add(auditForeignActionMethods)
end
if Events.OnGameStart and Events.OnGameStart.Add then
    Events.OnGameStart.Add(installInterception)
    Events.OnGameStart.Add(auditForeignActionMethods)
end

-- ============================================================================
-- TEST HOOKS (exposed for pz-test-kit)
-- ============================================================================

SaucedCarts.CartTransferInterceptor = {
    classifyTransfer = classifyTransfer,
    findCartNearPlayer = findCartNearPlayer,
    findItemNearPlayer = findItemNearPlayer,
    findInventoryItemRecursive = findInventoryItemRecursive,
    handleCartTransfer = handleCartTransfer,
    isInstalled = function() return interceptionInstalled end,
    -- Broadcast repair internals. Exposed so live pz-shell probes can check
    -- them against REAL Java objects — the offline harness can prove the
    -- call shape but not that PZ's own validation accepts the pairing.
    isBroadcastAddressable = isBroadcastAddressable,
    resolveResyncTarget = resolveResyncTarget,
    vehicleAncestorOf = vehicleAncestorOf,
}

SaucedCarts.debug("CartTransferInterceptor module loaded")
