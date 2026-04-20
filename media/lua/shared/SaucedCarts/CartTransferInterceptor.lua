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
        if destContainer.setDrawDirty then destContainer:setDrawDirty(true) end
        destContainer:AddItem(item)
        if isServer() and type(sendAddItemToContainer) == "function" then
            sendAddItemToContainer(destContainer, item)
        end
        SaucedCarts.debug(function() return string.format(
            "performCartTransfer: picked up item %d from ground into container type=%s",
            item:getID(), tostring(destContainer:getType())
        ) end)
        return true
    end

    -- === DEST = ground (cart → floor) ===
    -- Drop item onto the world square. Mirrors vanilla's floor-drop branch.
    if dropSquare then
        if srcContainer and srcContainer.DoRemoveItem then
            srcContainer:DoRemoveItem(item)
            if isServer() and type(sendRemoveItemFromContainer) == "function" then
                sendRemoveItemFromContainer(srcContainer, item)
            end
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

--- Find a cart InventoryItem by ID — searches the player's own inventory
--- first (in-hand case), then does a bounded ground sweep around the player
--- (ground case). Tight radius prevents a server-side world walk on
--- hostile input.
---@param player IsoPlayer
---@param cartId number
---@param radius number|nil  default 3
---@return InventoryItem|nil
local function findCartNearPlayer(player, cartId, radius)
    radius = radius or 3
    if not player then return nil end

    local inv = player:getInventory()
    if inv and inv.getItemById then
        local it = inv:getItemById(cartId)
        if it and SaucedCarts.safeIsCart(it) then return it end
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

    local inv = player:getInventory()
    if inv and inv.getItemById then
        local it = inv:getItemById(itemId)
        if it then return it end
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

    -- Also check in-hand carts' inner containers for the item (direction=out).
    if inv then
        local allItems = inv:getItems()
        if allItems then
            for i = 0, allItems:size() - 1 do
                local it = allItems:get(i)
                if it and SaucedCarts.safeIsCart(it) and it.getItemContainer then
                    local innerCont = it:getItemContainer()
                    if innerCont and innerCont.getItemById then
                        local inside = innerCont:getItemById(itemId)
                        if inside then return inside end
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
        SaucedCarts.debug("cartTransfer: invalid args")
        return
    end

    local cart = findCartNearPlayer(player, args.cartId)
    if not cart then
        SaucedCarts.debug(function() return "cartTransfer: cart " .. tostring(args.cartId) .. " not found near player" end)
        return
    end

    local item = findItemNearPlayer(player, args.itemId)
    if not item then
        SaucedCarts.debug(function() return "cartTransfer: item " .. tostring(args.itemId) .. " not found near player" end)
        return
    end

    local cartContainer = cart.getItemContainer and cart:getItemContainer()
    local playerInv = player:getInventory()
    if not cartContainer or not playerInv then return end

    -- Resolve a side of the transfer (src or dest) based on the client's
    -- classification. Returns (container, square-or-nil). For the floor
    -- case, the container is the floor ItemContainer on the player's
    -- square and the square is what vanilla ISTransferAction needs to
    -- do a proper world drop / world pickup.
    local function resolveSide(kind, cartId, sqX, sqY, sqZ, isSrc)
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
        return playerInv, nil
    end

    -- Plug in the cart reference (the "main" cart for this transfer) on
    -- whichever side has direction set to it.
    local srcContainer, destContainer, srcSquare, dropSquare
    if args.direction == "out" then
        srcContainer = cartContainer
        destContainer, dropSquare = resolveSide(
            args.destKind, args.destCartId, args.destSqX, args.destSqY, args.destSqZ, false
        )
    else
        srcContainer, srcSquare = resolveSide(
            args.srcKind, args.srcCartId, args.srcSqX, args.srcSqY, args.srcSqZ, true
        )
        destContainer = cartContainer
    end

    SaucedCarts.performCartTransfer(
        player, item, srcContainer, destContainer, dropSquare, srcSquare
    )
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
    isInstalled = function() return interceptionInstalled end,
}

SaucedCarts.debug("CartTransferInterceptor module loaded")
