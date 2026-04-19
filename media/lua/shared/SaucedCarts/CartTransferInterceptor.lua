-- ============================================================================
-- SaucedCarts/CartTransferInterceptor.lua
-- ============================================================================
-- PURPOSE: Narrowly redirect vanilla ISInventoryTransferAction to our
--          custom ISCartDepositAction ONLY when the destination is a
--          SaucedCarts cart whose inner container is not owned by an
--          IsoGameCharacter. This is the exact scenario where vanilla's
--          server-side TransactionManager.isConsistent check (Java) rejects
--          the transfer because Java-internal getEffectiveCapacity sees
--          the hard 50-cap instead of our raw capacity.
--
--          Every other transfer (player-to-player, cart-to-inventory,
--          inventory-to-bag, in-hand-cart-deposit, etc.) falls through
--          to vanilla unchanged.
--
-- CONTEXT: SHARED. Client needs the hook so it queues our action. Server
--          needs the command handler so it can perform the move.
--
-- SAFETY:  All interception logic runs in pcall. On any error, falls back
--          to vanilla ISInventoryTransferAction behaviour — worst case
--          the user sees the original "bugged action" symptom instead of
--          a crash.
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/TimedActions/ISCartDepositAction"

-- ============================================================================
-- SHARED HELPERS
-- ============================================================================

--- Resolve whether an ItemContainer is the inner container of a SaucedCarts
--- cart. Returns the cart InventoryItem on hit, nil otherwise.
---@param container ItemContainer|nil
---@return InventoryItem|nil
local function getCartFromDestContainer(container)
    if not container or not container.getContainingItem then return nil end
    local item = container:getContainingItem()
    if item and SaucedCarts.safeIsCart(item) then return item end
    return nil
end

--- Check whether the interception condition matches for this transfer.
---@param destContainer ItemContainer|nil
---@return boolean
local function shouldInterceptTransfer(destContainer)
    local cart = getCartFromDestContainer(destContainer)
    if not cart then return false end

    -- Only redirect when vanilla's Transaction check would fail: cart's
    -- inner container parent is NOT a character (ground cart, vehicle-
    -- container cart). In-hand cart's inner container parent IS the
    -- player — vanilla accepts that and our override handles capacity.
    local parent = destContainer.getParent and destContainer:getParent()
    if instanceof(parent, "IsoGameCharacter") then return false end

    return true
end

-- ============================================================================
-- ACTUAL MOVE (SP + SERVER-AUTHORITATIVE)
-- ============================================================================

--- Perform the item → cart move. Delegates to vanilla
--- `ISTransferAction:transferItem` so all the edge cases handled by
--- vanilla (unequip from hands, remove worn clothing, trigger
--- `OnClothingUpdated` for model refresh, radio device data, lit
--- candle/lantern item swaps) still fire.
---
--- We only add the server-side sendAddItemToContainer call because
--- vanilla's transferItem does the REMOVE sync but leaves the ADD
--- sync to TransactionManager — which we're bypassing. Calling
--- sendAddItemToContainer on the server broadcasts the add to every
--- client exactly like a normal transfer.
---
--- Safe to call from SP (isClient=false, isServer=false) — the sendX
--- functions in that context just mutate local state. On a dedicated
--- server (isClient=false, isServer=true) they broadcast.
---
---@param player IsoPlayer  initiating player (for capacity/range checks)
---@param item InventoryItem  item to move
---@param cartItem InventoryItem  destination cart (the InventoryContainer)
---@return boolean success
function SaucedCarts.performCartDeposit(player, item, cartItem)
    if not player or not item or not cartItem then return false end

    local cartContainer = cartItem.getItemContainer and cartItem:getItemContainer()
    if not cartContainer then
        SaucedCarts.debug("performCartDeposit: cart has no item container")
        return false
    end

    local srcContainer = item.getContainer and item:getContainer()
    if not srcContainer then
        SaucedCarts.debug("performCartDeposit: item has no source container")
        return false
    end

    -- Capacity re-check using our override (authoritative).
    if not cartContainer:hasRoomFor(player, item) then
        SaucedCarts.debug("performCartDeposit: cart has no room")
        return false
    end

    -- Delegate to vanilla. Handles unequip, worn-item removal,
    -- OnClothingUpdated model refresh, special-item swaps
    -- (Radio / CandleLit / HurricaneLit), and the srcContainer remove +
    -- server-side remove sync. dropSquare=nil because dest isn't a floor
    -- container.
    --
    -- ISTransferAction is in shared/ so it's loaded in every context —
    -- client, dedicated server, SP, and the pz-test-kit offline harness
    -- (which mocks the same surface). No fallback needed.
    ISTransferAction:transferItem(player, item, srcContainer, cartContainer, nil)

    -- Broadcast the add to all clients. Vanilla transferItem leaves this to
    -- TransactionManager; we're bypassing it, so we do it ourselves.
    if isServer() and type(sendAddItemToContainer) == "function" then
        sendAddItemToContainer(cartContainer, item)
    end

    SaucedCarts.debug(function() return string.format(
        "performCartDeposit: moved item %d into cart %d",
        item:getID(), cartItem:getID()
    ) end)
    return true
end

-- ============================================================================
-- CART LOOKUP (SERVER SIDE)
-- ============================================================================

--- Find a cart InventoryItem by ID. Searches player proximity first (cheap)
--- then falls back to a bounded grid sweep around the player. Tight radius
--- so server doesn't walk the whole world on bogus input.
---@param player IsoPlayer
---@param cartId number
---@param radius number|nil  default 3
---@return InventoryItem|nil
local function findGroundCartNearPlayer(player, cartId, radius)
    radius = radius or 3
    local psq = player and player:getCurrentSquare()
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

--- Find an item by ID starting from the player's reachable surfaces —
--- their inventory first (common case), then nearby floor squares. Tight
--- radius to prevent a server-side world walk on hostile input.
---@param player IsoPlayer
---@param itemId number
---@param radius number|nil  default 3
---@return InventoryItem|nil
local function findItemNearPlayer(player, itemId, radius)
    radius = radius or 3
    if not player then return nil end

    local inv = player:getInventory()
    if inv then
        local it = inv.getItemById and inv:getItemById(itemId)
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
                            local it = o:getItem()
                            if it and it:getID() == itemId then return it end
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

local lastDepositTime = {}  -- onlineId -> ms  (rate limit)
local DEPOSIT_RATE_LIMIT_MS = 100

local function rateLimitOk(player)
    if not player or not player.getOnlineID then return true end
    local id = player:getOnlineID()
    if not id then return true end
    local now = getTimestampMs and getTimestampMs() or 0
    local last = lastDepositTime[id] or 0
    if now - last < DEPOSIT_RATE_LIMIT_MS then return false end
    lastDepositTime[id] = now
    return true
end

if SaucedCarts.Network and SaucedCarts.Network.registerServerHandler then
    SaucedCarts.Network.registerServerHandler("depositToGroundCart", function(player, args)
        if not player then return end
        if not args or not args.itemId or not args.cartId then
            SaucedCarts.debug("depositToGroundCart: invalid args")
            return
        end
        if not rateLimitOk(player) then
            SaucedCarts.debug("depositToGroundCart: rate limited")
            return
        end

        local cart = findGroundCartNearPlayer(player, args.cartId)
        if not cart then
            SaucedCarts.debug(function() return "depositToGroundCart: cart " .. tostring(args.cartId) .. " not found near player" end)
            return
        end

        local item = findItemNearPlayer(player, args.itemId)
        if not item then
            SaucedCarts.debug(function() return "depositToGroundCart: item " .. tostring(args.itemId) .. " not found near player" end)
            return
        end

        SaucedCarts.performCartDeposit(player, item, cart)
    end)
end

-- ============================================================================
-- INTERCEPTION HOOK
-- ============================================================================

local interceptionInstalled = false

local function installInterception()
    if interceptionInstalled then return end
    if not ISInventoryTransferAction or not ISInventoryTransferAction.new then
        -- Dedicated server path. ISInventoryTransferAction is a client-only
        -- file, so the server never has it. Interception is a client-side
        -- concern — the server's role is just to handle the
        -- depositToGroundCart command (registered outside this function).
        SaucedCarts.debug("CartTransferInterceptor: ISInventoryTransferAction not present (expected on dedicated server)")
        return
    end
    interceptionInstalled = true

    local originalNew = ISInventoryTransferAction.new
    ISInventoryTransferAction.new = function(self, character, item, srcContainer, destContainer, time, fast, allowMissingItems)
        local redirect = false
        local ok, _ = pcall(function()
            redirect = shouldInterceptTransfer(destContainer)
        end)
        if ok and redirect then
            return ISCartDepositAction:new(character, item, srcContainer, destContainer, time or 10)
        end
        return originalNew(self, character, item, srcContainer, destContainer, time, fast, allowMissingItems)
    end

    SaucedCarts.log("CartTransferInterceptor: hooked ISInventoryTransferAction.new")
end

-- Try load-time install (most reliable on dedicated server where
-- OnGameStart doesn't fire for mod Lua). Also register OnServerStarted
-- and OnGameStart as belt-and-braces. Idempotent — double install is a no-op.
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
    shouldInterceptTransfer = shouldInterceptTransfer,
    findGroundCartNearPlayer = findGroundCartNearPlayer,
    findItemNearPlayer = findItemNearPlayer,
    isInstalled = function() return interceptionInstalled end,
}

SaucedCarts.debug("CartTransferInterceptor module loaded")
