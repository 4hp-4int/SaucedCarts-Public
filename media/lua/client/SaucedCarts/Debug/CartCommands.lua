-- ============================================================================
-- SaucedCarts/Debug/CartCommands.lua
-- ============================================================================
-- PURPOSE: Core cart debug commands (spawn, give, pickup, status, condition)
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"
require "SaucedCarts/CartData"
require "SaucedCarts/TimedActions/ISCartPickupAction"

local Utils = require "SaucedCarts/Debug/Utils"

local CartCommands = {}

--- Spawn a cart at the player's current position in the world
---@param cartType string|nil Cart type name (default: "ShoppingCart")
function CartCommands.spawnCart(cartType)
    cartType = cartType or "ShoppingCart"

    local player, err = Utils.getPlayer()
    if not player then
        SaucedCarts.error(err)
        return
    end

    local fullType = Utils.resolveCartType(cartType)
    if not fullType then
        SaucedCarts.error("Unknown cart type: " .. cartType)
        SaucedCarts.log("Available types: " .. Utils.getAvailableCartTypes())
        return
    end

    local square = player:getCurrentSquare()
    if not square then
        SaucedCarts.error("Player not on valid square")
        return
    end

    local item = instanceItem(fullType)
    if not item then
        SaucedCarts.error("Failed to create item: " .. fullType)
        return
    end

    -- Apply sandbox multipliers before placing in world
    SaucedCarts.applyMultipliers(item)

    -- Add to world at player position (5th param = transmit for MP sync)
    square:AddWorldInventoryItem(item, 0.5, 0.5, 0, true)
    SaucedCarts.log("Spawned " .. fullType .. " at player position")
end

--- Set the condition of the currently equipped cart
---@param condition number Condition percentage (0-100, will be converted to actual value)
function CartCommands.setCondition(condition)
    local player, err = Utils.getPlayer()
    if not player then
        SaucedCarts.error(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        SaucedCarts.error(err)
        return
    end

    local maxCondition = cart:getConditionMax()
    local newCondition = math.floor((condition / 100) * maxCondition)
    newCondition = math.max(0, math.min(maxCondition, newCondition))

    cart:setCondition(newCondition)
    SaucedCarts.log("Set cart condition to " .. newCondition .. "/" .. maxCondition)
end

--- Show detailed status of the currently equipped cart
--- Prints type, name, condition, item count, and capacity to console
function CartCommands.showStatus()
    local player, err = Utils.getPlayer()
    if not player then
        SaucedCarts.error(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        SaucedCarts.log("Not holding a cart")
        return
    end

    local cartData = SaucedCarts.getCartData(cart)
    local container = cart:getItemContainer()

    SaucedCarts.log("=== SaucedCarts Status ===")
    SaucedCarts.log("  Type: " .. cart:getFullType())
    SaucedCarts.log("  Name: " .. (cartData and cartData.name or "Unknown"))
    SaucedCarts.log("  Condition: " .. cart:getCondition() .. "/" .. cart:getConditionMax())

    if container then
        SaucedCarts.log("  Items: " .. container:getItems():size())
        SaucedCarts.log("  Capacity: " .. SaucedCarts.getFillPercent(cart) .. "% (" ..
            math.floor(container:getCapacityWeight()) .. "/" .. container:getCapacity() .. ")")
    end
    SaucedCarts.log("========================")
end

--- Give a cart directly to the player, equipped in both hands
--- Heavy items like carts should never sit in inventory - always ground or hands
---@param cartType string|nil Cart type name (default: "ShoppingCart")
function CartCommands.giveCart(cartType)
    cartType = cartType or "ShoppingCart"

    local player, err = Utils.getPlayer()
    if not player then
        SaucedCarts.error(err)
        return
    end

    local fullType = Utils.resolveCartType(cartType)
    if not fullType then
        SaucedCarts.error("Unknown cart type: " .. cartType)
        SaucedCarts.log("Available types: " .. Utils.getAvailableCartTypes())
        return
    end

    local item = instanceItem(fullType)
    if not item then
        SaucedCarts.error("Failed to create item: " .. fullType)
        return
    end

    -- Apply sandbox multipliers before equipping
    SaucedCarts.applyMultipliers(item)

    -- Heavy items go directly to hands, not inventory
    -- First drop any existing heavy items
    forceDropHeavyItems(player)

    -- Add to inventory and immediately equip (with MP sync)
    player:getInventory():AddItem(item)
    sendAddItemToContainer(player:getInventory(), item)

    player:setPrimaryHandItem(item)
    player:setSecondaryHandItem(item)

    if isClient() then
        -- Local player, sync equip to server
        sendEquip(player)
    end

    SaucedCarts.log("Equipped " .. fullType .. " in both hands")
end

--- Pick up a world item cart (uses timed action with MP sync)
---@param worldItemIndex number|nil Optional: which world item to pick up (default 1 = first)
function CartCommands.pickupWorldCart(worldItemIndex)
    worldItemIndex = worldItemIndex or 1

    local player, err = Utils.getPlayer()
    if not player then
        SaucedCarts.error(err)
        return
    end

    local playerSquare = player:getCurrentSquare()
    if not playerSquare then
        SaucedCarts.error("Player not on valid square")
        return
    end

    -- Check adjacent squares too
    local squares = { playerSquare }
    local directions = { IsoDirections.N, IsoDirections.S, IsoDirections.E, IsoDirections.W }
    for _, dir in ipairs(directions) do
        local adj = playerSquare:getAdjacentSquare(dir)
        if adj then table.insert(squares, adj) end
    end

    local cartCount = 0
    local targetWorldItem = nil

    for _, sq in ipairs(squares) do
        local objects = sq:getWorldObjects()
        if objects then
            for i = 0, objects:size() - 1 do
                local worldItem = objects:get(i)
                if instanceof(worldItem, "IsoWorldInventoryObject") then
                    local item = worldItem:getItem()
                    if item and SaucedCarts.isCart(item) then
                        cartCount = cartCount + 1
                        if cartCount == worldItemIndex then
                            targetWorldItem = worldItem
                        end
                        SaucedCarts.log("Found cart #" .. cartCount .. ": " .. item:getFullType() .. " on square " .. tostring(sq:getX()) .. "," .. tostring(sq:getY()))
                    end
                end
            end
        end
    end

    if cartCount == 0 then
        SaucedCarts.log("No carts found on ground near player")
        return
    end

    if not targetWorldItem then
        SaucedCarts.log("Cart #" .. worldItemIndex .. " not found, only " .. cartCount .. " carts available")
        return
    end

    -- Queue timed action (MP-safe) - use FromWorldItem to extract serializable data
    ISTimedActionQueue.add(ISCartPickupAction.FromWorldItem(player, targetWorldItem))
    SaucedCarts.log("Queued pickup for cart #" .. worldItemIndex)
end

--- Dump animator state for debugging animation issues
--- Shows current state, movement state, equipped items, and animation variables
--- Note: AdvancedAnimator methods are NOT Lua-accessible in Build 42, so we use IsoGameCharacter methods
function CartCommands.dumpAnimState()
    local player, err = Utils.getPlayer()
    if not player then
        SaucedCarts.error(err)
        return
    end

    SaucedCarts.log("=== ANIMATOR STATE ===")

    -- Get state name from player (IsoGameCharacter.getCurrentStateName works)
    SaucedCarts.log("Current state: " .. tostring(player:getCurrentStateName()))

    -- Movement state from game logic
    SaucedCarts.log("--- Movement State ---")
    SaucedCarts.log("  isMoving (not Idle): " .. tostring(player:isCurrentState(IdleState.instance()) == false))
    SaucedCarts.log("  isSprinting: " .. tostring(player:isSprinting()))
    SaucedCarts.log("  isRunning: " .. tostring(player:isRunning()))
    SaucedCarts.log("  isSneaking: " .. tostring(player:isSneaking()))
    SaucedCarts.log("  isAiming: " .. tostring(player:isAiming()))

    -- Check what's in hands
    local primary = player:getPrimaryHandItem()
    local secondary = player:getSecondaryHandItem()
    SaucedCarts.log("--- Equipped ---")
    SaucedCarts.log("  Primary: " .. (primary and primary:getFullType() or "none"))
    SaucedCarts.log("  Secondary: " .. (secondary and secondary:getFullType() or "none"))

    -- Animation variables we set (getVariableString is on IsoGameCharacter)
    SaucedCarts.log("--- Cart Anim Variables ---")
    local weapon = player:getVariableString("Weapon")
    local rightMask = player:getVariableString("RightHandMask")
    local leftMask = player:getVariableString("LeftHandMask")
    SaucedCarts.log("  Weapon: " .. (weapon ~= "" and weapon or "(empty)"))
    SaucedCarts.log("  RightHandMask: " .. (rightMask ~= "" and rightMask or "(empty)"))
    SaucedCarts.log("  LeftHandMask: " .. (leftMask ~= "" and leftMask or "(empty)"))

    -- Check if cart variables are set correctly
    if primary and SaucedCarts.isCart(primary) then
        if weapon ~= "cart" then
            SaucedCarts.log("  WARNING: Holding cart but Weapon != 'cart'!")
        end
    end

    -- Common vanilla animation variables
    SaucedCarts.log("--- Movement Anim Variables ---")
    SaucedCarts.log("  isMoving: " .. tostring(player:getVariableString("isMoving")))
    SaucedCarts.log("  isSprinting: " .. tostring(player:getVariableString("isSprinting")))
    SaucedCarts.log("  isTurningAround: " .. tostring(player:getVariableString("isTurningAround")))
    SaucedCarts.log("  DeltaX: " .. tostring(player:getVariableString("DeltaX")))
    SaucedCarts.log("  DeltaY: " .. tostring(player:getVariableString("DeltaY")))

    SaucedCarts.log("======================")
end

--- Alias for dumpAnimState (simpler name)
function CartCommands.animState()
    CartCommands.dumpAnimState()
end

--- List known animation variables for cart system
function CartCommands.listAnimVariables()
    SaucedCarts.log("=== CART ANIMATION VARIABLES ===")
    SaucedCarts.log("Body animations (set by CartStateHandler):")
    SaucedCarts.log("  Weapon = 'cart'  -> triggers IdleCart, walkCart, runCart, sprintCart")
    SaucedCarts.log("")
    SaucedCarts.log("Masking animations (set by item script ReplaceInPrimaryHand):")
    SaucedCarts.log("  RightHandMask = 'holdingcartright'")
    SaucedCarts.log("  LeftHandMask = 'holdingcartleft'")
    SaucedCarts.log("")
    SaucedCarts.log("Vanilla movement variables (read-only, set by engine):")
    SaucedCarts.log("  isMoving, isSprinting, isTurningAround, DeltaX, DeltaY")
    SaucedCarts.log("=================================")
end

--- Give repair materials for testing the repair system
---@param count number|nil Number of items to give (default: 5)
---@param itemType string|nil Item type to give (default: Base.ScrapMetal)
function CartCommands.giveRepairMaterial(count, itemType)
    count = count or 5
    itemType = itemType or "Base.ScrapMetal"

    local player, err = Utils.getPlayer()
    if not player then
        SaucedCarts.error(err)
        return
    end

    local inv = player:getInventory()
    for i = 1, count do
        local item = instanceItem(itemType)
        if item then
            inv:AddItem(item)
            sendAddItemToContainer(inv, item)
        else
            SaucedCarts.error("Failed to create item: " .. itemType)
            return
        end
    end

    SaucedCarts.log("Added " .. count .. "x " .. itemType .. " to inventory")
end

--- Repair the currently held cart (bypass timed action, for testing)
function CartCommands.repairCart()
    local player, err = Utils.getPlayer()
    if not player then
        SaucedCarts.error(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        SaucedCarts.error(err)
        return
    end

    local cartData = SaucedCarts.getCartData(cart)
    local repairAmount = (cartData and cartData.repairAmount) or 10

    local currentCondition = cart:getCondition()
    local maxCondition = cart:getConditionMax()
    local newCondition = math.min(maxCondition, currentCondition + repairAmount)

    cart:setCondition(newCondition)
    cart:setHaveBeenRepaired(cart:getHaveBeenRepaired() + 1)

    SaucedCarts.log("Repaired cart: " .. currentCondition .. " -> " .. newCondition ..
        " (+" .. (newCondition - currentCondition) .. ")")
end

-- ============================================================================
-- WORLD SPAWNING DEBUG COMMANDS
-- ============================================================================
-- These require WorldSpawning module (server-side, available in SP)

--- Show world spawning status
function CartCommands.showSpawnStatus()
    if not SaucedCarts.WorldSpawning then
        SaucedCarts.log("WorldSpawning not available (server-side module)")
        return
    end
    SaucedCarts.WorldSpawning.showStatus()
end

--- List all tracked buildings that have spawned carts
function CartCommands.listSpawnedBuildings()
    if not SaucedCarts.WorldSpawning then
        SaucedCarts.log("WorldSpawning not available (server-side module)")
        return
    end
    SaucedCarts.WorldSpawning.listTrackedBuildings()
end

--- Check if current building has spawned carts
function CartCommands.checkBuildingSpawn()
    if not SaucedCarts.WorldSpawning then
        SaucedCarts.log("WorldSpawning not available (server-side module)")
        return
    end
    SaucedCarts.WorldSpawning.checkCurrentBuilding()
end

--- Clear spawn tracking (allows carts to respawn in all buildings)
function CartCommands.clearSpawnTracking()
    if not SaucedCarts.WorldSpawning then
        SaucedCarts.log("WorldSpawning not available (server-side module)")
        return
    end
    SaucedCarts.WorldSpawning.clearSpawnTracking()
end

--- Dump raw ModData for debugging
function CartCommands.dumpModData()
    if not SaucedCarts.WorldSpawning then
        SaucedCarts.log("WorldSpawning not available (server-side module)")
        return
    end
    SaucedCarts.WorldSpawning.dumpModData()
end

return CartCommands
