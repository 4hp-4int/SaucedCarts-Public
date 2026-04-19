--[[
    SaucedCarts Test Helpers
    PURPOSE: Cart counting, setup helpers, and pass/fail logging for tests
    CONTEXT: client
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"
require "SaucedCarts/Tests/TestFileOutput"

SaucedCarts.TestHelpers = {}
local TestHelpers = SaucedCarts.TestHelpers

-- ==========================================
-- CART COUNTING (for duplication detection)
-- ==========================================

--- Count carts in a player's inventory
---@param player IsoPlayer
---@return number
function TestHelpers.countCartsInInventory(player)
    if not player then return 0 end

    local count = 0
    local inv = player:getInventory()
    if not inv then return 0 end

    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if SaucedCarts.isCart(item) then
            count = count + 1
        end
    end
    return count
end

--- Count carts on the ground within a radius of a square
---@param centerSquare IsoGridSquare
---@param radius number
---@return number
function TestHelpers.countCartsOnGround(centerSquare, radius)
    if not centerSquare then return 0 end

    local count = 0
    local cx, cy, cz = centerSquare:getX(), centerSquare:getY(), centerSquare:getZ()

    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = getCell():getGridSquare(cx + dx, cy + dy, cz)
            if square then
                local worldObjects = square:getWorldObjects()
                if worldObjects then
                    for i = 0, worldObjects:size() - 1 do
                        local obj = worldObjects:get(i)
                        if instanceof(obj, "IsoWorldInventoryObject") then
                            local item = obj:getItem()
                            if item and SaucedCarts.isCart(item) then
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return count
end

--- Count total carts (inventory + ground within radius)
---@param player IsoPlayer
---@param radius number
---@return number
function TestHelpers.countCartsTotal(player, radius)
    if not player then return 0 end

    local invCount = TestHelpers.countCartsInInventory(player)
    local groundCount = TestHelpers.countCartsOnGround(player:getCurrentSquare(), radius or 10)
    return invCount + groundCount
end

--- Find a cart by item ID (searches inventory and nearby ground)
---@param player IsoPlayer
---@param cartId number
---@param radius number
---@return InventoryItem|nil
function TestHelpers.findCartById(player, cartId, radius)
    if not player or not cartId then return nil end

    -- Check inventory
    local inv = player:getInventory()
    if inv then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:getID() == cartId then
                return item
            end
        end
    end

    -- Check ground
    local square = player:getCurrentSquare()
    if not square then return nil end

    local cx, cy, cz = square:getX(), square:getY(), square:getZ()
    radius = radius or 10

    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = getCell():getGridSquare(cx + dx, cy + dy, cz)
            if sq then
                local worldObjects = sq:getWorldObjects()
                if worldObjects then
                    for i = 0, worldObjects:size() - 1 do
                        local obj = worldObjects:get(i)
                        if instanceof(obj, "IsoWorldInventoryObject") then
                            local item = obj:getItem()
                            if item and item:getID() == cartId then
                                return item
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- ==========================================
-- LOGGING HELPERS
-- ==========================================

--- Log a test pass
---@param fmt string Format string
---@vararg any Format arguments
---@return boolean Always returns true
function TestHelpers.pass(fmt, ...)
    local msg = string.format("[PASS] " .. fmt, ...)
    SaucedCarts.TestFileOutput.write(msg)
    return true
end

--- Log a test failure
---@param fmt string Format string
---@vararg any Format arguments
---@return boolean Always returns false
function TestHelpers.fail(fmt, ...)
    local msg = string.format("[FAIL] " .. fmt, ...)
    SaucedCarts.TestFileOutput.write(msg)
    return false
end

--- Log a test skip (not a failure, just not applicable in current context)
---@param fmt string Format string
---@vararg any Format arguments
---@return boolean Always returns true (skip is not failure)
function TestHelpers.skip(fmt, ...)
    local msg = string.format("[SKIP] " .. fmt, ...)
    SaucedCarts.TestFileOutput.write(msg)
    return true
end

--- Log test info
---@param fmt string Format string
---@vararg any Format arguments
function TestHelpers.info(fmt, ...)
    local msg = string.format("[INFO] " .. fmt, ...)
    SaucedCarts.TestFileOutput.write(msg)
end

-- ==========================================
-- SETUP HELPERS
-- ==========================================

--- Remove all objects from a square except the floor
---@param square IsoGridSquare
function TestHelpers.removeAllButFloor(square)
    if not square then return end

    -- Remove world objects
    local objects = square:getObjects()
    if objects then
        for i = objects:size(), 2, -1 do
            local obj = objects:get(i - 1)
            square:transmitRemoveItemFromSquare(obj)
        end
    end

    -- Remove static moving objects (corpses, world items)
    local staticMoving = square:getStaticMovingObjects()
    if staticMoving then
        for i = staticMoving:size(), 1, -1 do
            local obj = staticMoving:get(i - 1)
            obj:removeFromWorld()
            obj:removeFromSquare()
        end
    end
end

--- Get a clean square at offset from player
---@param dx number X offset from player
---@param dy number Y offset from player
---@param dz number Z offset from player
---@return IsoGridSquare|nil, number, number, number
function TestHelpers.getCleanSquare(dx, dy, dz)
    local player = getSpecificPlayer(0)
    if not player then return nil end

    -- Use floor to get integer grid coordinates
    local px = math.floor(player:getX())
    local py = math.floor(player:getY())
    local pz = math.floor(player:getZ())

    local sx, sy, sz = px + dx, py + dy, pz + (dz or 0)
    local square = getCell():getGridSquare(sx, sy, sz)

    if square then
        TestHelpers.removeAllButFloor(square)
    end

    return square, sx, sy, sz
end

--- Spawn a cart on a square
---@param square IsoGridSquare
---@param fullType string Cart type (e.g., "SaucedCarts.ShoppingCart")
---@return InventoryItem
function TestHelpers.spawnCart(square, fullType)
    local item = instanceItem(fullType)
    square:AddWorldInventoryItem(item, 0.5, 0.5, 0, true)
    return item
end

--- Give a cart directly to player's inventory and equip it
---@param player IsoPlayer
---@param fullType string Cart type
---@return InventoryItem
function TestHelpers.giveCart(player, fullType)
    local cart = instanceItem(fullType)
    player:getInventory():AddItem(cart)
    player:setPrimaryHandItem(cart)
    player:setSecondaryHandItem(cart)
    return cart
end

--- Give a cart to player's inventory but don't equip it
---@param player IsoPlayer
---@param fullType string Cart type
---@return InventoryItem
function TestHelpers.giveCartUnequipped(player, fullType)
    local cart = instanceItem(fullType)
    player:getInventory():AddItem(cart)
    return cart
end

--- Give an item to player's inventory
---@param player IsoPlayer
---@param fullType string Item type
---@return InventoryItem
function TestHelpers.giveItem(player, fullType)
    local item = instanceItem(fullType)
    player:getInventory():AddItem(item)
    return item
end

--- Clear player inventory and unequip hands
---@param player IsoPlayer
function TestHelpers.clearPlayer(player)
    if not player then return end

    player:getInventory():removeAllItems()
    player:clearWornItems()
    player:setPrimaryHandItem(nil)
    player:setSecondaryHandItem(nil)
end

--- Restore player to full health
---@param player IsoPlayer
function TestHelpers.restoreHealth(player)
    if not player then return end
    player:getBodyDamage():RestoreToFullHealth()
end

--- Remove all carts from ground near player
---@param player IsoPlayer
---@param radius number
function TestHelpers.cleanupGroundCarts(player, radius)
    if not player then return end

    local square = player:getCurrentSquare()
    if not square then return end

    local cx, cy, cz = square:getX(), square:getY(), square:getZ()
    radius = radius or 10

    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = getCell():getGridSquare(cx + dx, cy + dy, cz)
            if sq then
                local worldObjects = sq:getWorldObjects()
                if worldObjects then
                    -- Iterate backwards to safely remove
                    for i = worldObjects:size() - 1, 0, -1 do
                        local obj = worldObjects:get(i)
                        if instanceof(obj, "IsoWorldInventoryObject") then
                            local item = obj:getItem()
                            if item and SaucedCarts.isCart(item) then
                                sq:transmitRemoveItemFromSquare(obj)
                                sq:removeWorldObject(obj)
                                item:setWorldItem(nil)
                            end
                        end
                    end
                end
            end
        end
    end
end

--- Full test cleanup - clears player and removes ground carts
---@param player IsoPlayer
function TestHelpers.fullCleanup(player)
    if not player then return end
    TestHelpers.clearPlayer(player)
    TestHelpers.cleanupGroundCarts(player, 15)
    TestHelpers.restoreHealth(player)
end

--- Find a ground cart by ID on a specific square
---@param squareX number
---@param squareY number
---@param squareZ number
---@param cartId number
---@return InventoryItem|nil cart, IsoWorldInventoryObject|nil worldItem
function TestHelpers.findGroundCartOnSquare(squareX, squareY, squareZ, cartId)
    local square = getCell():getGridSquare(squareX, squareY, squareZ)
    if not square then return nil, nil end

    local worldObjects = square:getWorldObjects()
    if not worldObjects then return nil, nil end

    for i = 0, worldObjects:size() - 1 do
        local obj = worldObjects:get(i)
        if instanceof(obj, "IsoWorldInventoryObject") then
            local item = obj:getItem()
            if item and item:getID() == cartId then
                return item, obj
            end
        end
    end

    return nil, nil
end

return SaucedCarts.TestHelpers
