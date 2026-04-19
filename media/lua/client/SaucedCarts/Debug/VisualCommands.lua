-- ============================================================================
-- SaucedCarts/Debug/VisualCommands.lua
-- ============================================================================
-- PURPOSE: Fill state and visual model testing debug commands
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"
require "SaucedCarts/CartVisuals"

local Utils = require "SaucedCarts/Debug/Utils"

local VisualCommands = {}

-- Debug flag: when true, self-correction is paused for testing
-- Reset automatically after a few seconds
SaucedCarts._debugPauseSelfCorrection = false
SaucedCarts._debugPauseExpiry = 0

--- Set the fill state visual of the cart (pauses self-correction for 5 seconds)
---@param fillState string "empty", "partial", or "full"
function VisualCommands.setFillState(fillState)
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    -- Validate fill state
    if fillState ~= "empty" and fillState ~= "partial" and fillState ~= "full" then
        print("[SaucedCarts] ERROR: Invalid fill state '" .. tostring(fillState) .. "'. Use: empty, partial, full")
        return
    end

    -- Pause self-correction for 5 seconds so we can see the debug state
    SaucedCarts._debugPauseSelfCorrection = true
    SaucedCarts._debugPauseExpiry = getTimestampMs() + 5000

    -- Use the registered visualModels (supports addon carts)
    local modelName = SaucedCarts.buildCartModelName(cart, fillState)

    -- Apply model
    cart:setStaticModel(modelName)
    cart:setWorldStaticModel(modelName)

    local worldItem = cart:getWorldItem()
    if worldItem then
        worldItem:updateSprite()
    end

    if player:getPrimaryHandItem() == cart then
        player:resetEquippedHandsModels()
    end

    -- Store state
    local modData = cart:getModData()
    modData.SaucedCarts_fillState = fillState

    -- Sync in MP
    if isClient() then
        syncItemFields(player, cart)
        syncItemModData(player, cart)
    end

    print("[SaucedCarts] DEBUG: Set fill state to '" .. fillState .. "' (model: " .. modelName .. ") - self-correction paused for 5s")
end

--- Cycle through fill states: empty -> partial -> full -> empty
function VisualCommands.cycleFillState()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    local modData = cart:getModData()
    local currentFill = modData.SaucedCarts_fillState or "empty"

    -- Cycle to next state
    local nextFill
    if currentFill == "empty" then
        nextFill = "partial"
    elseif currentFill == "partial" then
        nextFill = "full"
    else
        nextFill = "empty"
    end

    VisualCommands.setFillState(nextFill)
end

--- Force update the visual state of held cart based on current contents
--- Use this to test the dynamic model switching while equipped
function VisualCommands.forceVisualUpdate()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    require "SaucedCarts/CartVisuals"

    -- Get current state before update
    local modData = cart:getModData()
    local oldFillState = modData.SaucedCarts_fillState or "empty"
    local oldModel = cart:getStaticModel()

    -- Force update
    local changed = SaucedCarts.updateCartVisual(cart, player)

    -- Get new state after update
    local newFillState = modData.SaucedCarts_fillState or "empty"
    local newModel = cart:getStaticModel()

    print("=== Force Visual Update ===")
    print("  Changed: " .. tostring(changed))
    print("  Fill State: " .. oldFillState .. " -> " .. newFillState)
    print("  Model: " .. tostring(oldModel) .. " -> " .. tostring(newModel))

    local container = cart:getItemContainer()
    if container then
        local fillPercent = SaucedCarts.getFillPercent(cart)
        print("  Current Fill: " .. fillPercent .. "% (" ..
            math.floor(container:getCapacityWeight()) .. "/" .. container:getCapacity() .. ")")
    end
    print("===========================")
end

--- Show visual status of the currently equipped cart
function VisualCommands.showVisualStatus()
    local player, err = Utils.getPlayer()
    if not player then
        print(err)
        return
    end

    local cart
    cart, err = Utils.getHeldCart(player)
    if not cart then
        print(err)
        return
    end

    local modData = cart:getModData()
    local storedFillState = modData.SaucedCarts_fillState or "empty"
    local calculatedFillState = SaucedCarts.calculateFillState(cart)
    local staticModel = cart:getStaticModel()
    local worldStaticModel = cart:getWorldStaticModel()

    -- Use proper API for expected model
    local expectedModel = SaucedCarts.buildCartModelName(cart, storedFillState)
    local calculatedModel = SaucedCarts.buildCartModelName(cart, calculatedFillState)

    -- Get visual models config
    local visualModels = SaucedCarts.getVisualModels(cart)

    print("=== Cart Visual Status ===")
    print("  Cart Type: " .. tostring(cart:getFullType()))
    print("  Stored Fill State: " .. storedFillState)
    print("  Calculated Fill State: " .. calculatedFillState)
    print("  Expected Model (stored): " .. expectedModel)
    print("  Expected Model (calculated): " .. calculatedModel)
    print("  Actual Static Model: " .. tostring(staticModel))
    print("  Actual World Model: " .. tostring(worldStaticModel))
    if visualModels then
        print("  Visual Models Config:")
        print("    empty: " .. tostring(visualModels.empty))
        print("    partial: " .. tostring(visualModels.partial))
        print("    full: " .. tostring(visualModels.full))
    else
        print("  Visual Models: (using fallback)")
    end
    if staticModel ~= expectedModel then
        print("  WARNING: Model mismatch with stored state!")
    end
    if storedFillState ~= calculatedFillState then
        print("  NOTE: Stored state differs from calculated (self-correction pending)")
    end
    local pauseActive = SaucedCarts._debugPauseSelfCorrection and getTimestampMs() < SaucedCarts._debugPauseExpiry
    print("  Self-correction paused: " .. tostring(pauseActive))
    print("==========================")
end

return VisualCommands
