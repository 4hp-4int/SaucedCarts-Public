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
    if destContainer.hasRoomFor and not destContainer:hasRoomFor(player, item) then
        SaucedCarts.debug("performCartTransfer: dest has no room")
        return false
    end

    ISTransferAction:transferItem(player, item, srcContainer, destContainer, nil)

    if isServer() and type(sendAddItemToContainer) == "function" then
        sendAddItemToContainer(destContainer, item)
    end

    -- Mark both containers dirty so the inventory panel repaints on its
    -- next tick. Without this, SP (and client-authoritative MP) transfers
    -- to an equipped cart leave the UI showing stale item lists + weight
    -- until the panel is closed/reopened. Vanilla ISInventoryTransfer
    -- relies on internal dirty flags set inside TransactionManager which
    -- we deliberately skip, so we do it manually here.
    if srcContainer.setDrawDirty  then srcContainer:setDrawDirty(true)  end
    if destContainer.setDrawDirty then destContainer:setDrawDirty(true) end

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
                                -- Recurse into any cart's inner container.
                                if SaucedCarts.safeIsCart(groundItem) and groundItem.getItemContainer then
                                    local innerCont = groundItem:getItemContainer()
                                    if innerCont then
                                        local inside = innerCont.getItemById and innerCont:getItemById(itemId)
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

    return nil
end

-- ============================================================================
-- SERVER HANDLER
-- ============================================================================

local function handleCartTransfer(player, args)
    if not player then return end
    if not args or not args.itemId or not args.cartId then
        SaucedCarts.debug("cartTransfer: invalid args (missing itemId or cartId)")
        return
    end

    -- NOTE: bail-path logs below use .debug() so they don't spam dedi
    -- logs in normal play. Promote to .log() temporarily when chasing
    -- a "transfer animates but item doesn't move" report — the per-bail
    -- diagnostics (player position, vehicle state, srcKind/destKind,
    -- container resolution) pin which path is failing in ~one repro.
    local cart = findCartNearPlayer(player, args.cartId)
    if not cart then
        SaucedCarts.debug(function()
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

    local item = findItemNearPlayer(player, args.itemId)
    if not item then
        SaucedCarts.debug(function() return string.format(
            "cartTransfer: item %s NOT FOUND for player (cart=%s direction=%s srcKind=%s destKind=%s)",
            tostring(args.itemId), tostring(args.cartId),
            tostring(args.direction), tostring(args.srcKind), tostring(args.destKind))
        end)
        return
    end

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
            local bagItem = findInventoryItemRecursive(player:getInventory(), cartId)
            if bagItem and bagItem.getItemContainer then
                local c = bagItem:getItemContainer()
                if c then return c, nil end
            end
            SaucedCarts.debug(function() return string.format(
                "resolveSide: bag item %s NOT FOUND in player inv (recursive); falling back to playerInv",
                tostring(cartId)) end)
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
    if args.direction == "out" then
        srcContainer = cartContainer
        destContainer, dropSquare = resolveSide(
            args.destKind, args.destCartId,
            args.destSqX, args.destSqY, args.destSqZ,
            args.destContType, false, args.destObjIdx, args.destContIdx
        )
    else
        srcContainer, srcSquare = resolveSide(
            args.srcKind, args.srcCartId,
            args.srcSqX, args.srcSqY, args.srcSqZ,
            args.srcContType, true, args.srcObjIdx, args.srcContIdx
        )
        destContainer = cartContainer
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
    if args.direction ~= "out" and srcContainer and item.getContainer then
        local realSrc = item:getContainer()
        if realSrc and realSrc == destContainer then
            SaucedCarts.debug(function() return string.format(
                "cartTransfer: item %s already in destination cart; no-op (duplicate send)",
                tostring(args.itemId)) end)
            return
        end
        if realSrc and realSrc ~= srcContainer then
            SaucedCarts.debug(function() return string.format(
                "cartTransfer: client claimed srcKind=%s (%s), but item lives in %s — using real container",
                tostring(args.srcKind), tostring(srcContainer:getType()),
                tostring(realSrc.getType and realSrc:getType() or "?"))
            end)
            srcContainer = realSrc
        end
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
                local extra = findItemNearPlayer(player, id)
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
end

if SaucedCarts.Network and SaucedCarts.Network.registerServerHandler then
    SaucedCarts.Network.registerServerHandler("cartTransfer", handleCartTransfer)
    -- Keep the old command name alive so connected clients that were loaded
    -- before the update don't break mid-session.
    SaucedCarts.Network.registerServerHandler("depositToGroundCart", handleCartTransfer)
end

-- ============================================================================
-- INTERCEPTION HOOK
-- ============================================================================

local interceptionInstalled = false

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
                direction, cart, time or 10
            )
        end
        return originalNew(self, character, item, srcContainer, destContainer, time, fast, allowMissingItems)
    end

    SaucedCarts.log("CartTransferInterceptor: hooked ISInventoryTransferAction.new (src-or-dest cart matching)")
end

if ISInventoryTransferAction and ISInventoryTransferAction.new then
    local ok, err = pcall(installInterception)
    if not ok then
        SaucedCarts.error("CartTransferInterceptor: load-time install FAILED: " .. tostring(err))
    end
end

if Events.OnServerStarted and Events.OnServerStarted.Add then
    Events.OnServerStarted.Add(installInterception)
end
if Events.OnGameStart and Events.OnGameStart.Add then
    Events.OnGameStart.Add(installInterception)
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
}

SaucedCarts.debug("CartTransferInterceptor module loaded")
