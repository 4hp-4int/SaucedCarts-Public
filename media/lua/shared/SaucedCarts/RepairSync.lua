-- ============================================================================
-- SaucedCarts/RepairSync.lua
-- ============================================================================
-- PURPOSE: Network sync for ground cart repairs in MP.
--          Server broadcasts repair completion to all clients so condition
--          updates immediately without waiting for world state sync.
--
-- CONTEXT: SHARED (client + server)
--          Server broadcasts via onCartRepair event (in UpgradeSync.lua)
--          Client receives via Network.registerClientHandler()
--
-- COMMAND: repairComplete (Server → All Clients, via broadcast)
--   Args: { squareX, squareY, squareZ, cartId, newCondition }
--
-- NOTE: The notifyClient() function is deprecated - use event-driven sync.
--       It remains for backwards compatibility.
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/Network"

SaucedCarts.RepairSync = {}

-- =============================================================================
-- CLIENT HANDLER: Receive repair completion from server
-- =============================================================================

SaucedCarts.Network.registerClientHandler("repairComplete", function(args)
    -- Validate args
    if not args or not args.squareX or not args.cartId or not args.newCondition then
        SaucedCarts.error("RepairSync: invalid repairComplete args")
        return
    end

    -- Find the cart using standard helper
    local cart = SaucedCarts.Network.findGroundCart(
        args.squareX, args.squareY, args.squareZ, args.cartId)

    if not cart then
        SaucedCarts.debug(function() return "RepairSync: cart " .. args.cartId .. " not found on square" end)
        return
    end

    -- Update client's local copy with server's condition
    cart:setCondition(args.newCondition)
    SaucedCarts.debug(function() return "RepairSync: updated cart " .. args.cartId .. " condition to " .. args.newCondition end)

    -- Refresh loot panel if viewing this area
    if getPlayerData then
        local pdata = getPlayerData(0)  -- Local player (playerNum 0)
        if pdata and pdata.lootInventory then
            pdata.lootInventory:refreshBackpacks()
        end
    end
end)

-- =============================================================================
-- SERVER API: Send repair completion to client
-- =============================================================================

--- Notify a client that a ground cart repair completed
---@param player IsoPlayer The player who repaired the cart
---@param squareX number X coordinate of the cart's square
---@param squareY number Y coordinate of the cart's square
---@param squareZ number Z coordinate of the cart's square
---@param cartId number The cart's item ID
---@param newCondition number The new condition value
function SaucedCarts.RepairSync.notifyClient(player, squareX, squareY, squareZ, cartId, newCondition)
    SaucedCarts.Network.sendToClient(player, "repairComplete", {
        squareX = squareX,
        squareY = squareY,
        squareZ = squareZ,
        cartId = cartId,
        newCondition = newCondition,
    })
end

SaucedCarts.debug("RepairSync module loaded")
