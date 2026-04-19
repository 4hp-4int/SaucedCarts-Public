-- ============================================================================
-- SaucedCarts/CartVisuals.lua
-- ============================================================================
-- PURPOSE: Visual state management for carts based on fill level.
--
-- CONTEXT: SHARED (client + server)
--
-- MODEL COMBINATIONS (3 total):
--   ShoppingCartModel        (0-32% full)
--   ShoppingCartPartialModel (33-65% full)
--   ShoppingCartFullModel    (66%+ full)
--
-- MP SYNC: Uses syncItemFields and syncItemModData to sync state changes
-- ============================================================================

require "SaucedCarts/Core"

-- =============================================================================
-- Configuration
-- =============================================================================

-- Fill state thresholds (percentage of capacity)
local FILL_PARTIAL_THRESHOLD = SaucedCarts.Config.FILL_PARTIAL_THRESHOLD
local FILL_FULL_THRESHOLD = SaucedCarts.Config.FILL_FULL_THRESHOLD

-- Track which cart types have been warned about fallback models (one warning per type per session)
local warnedFallback = {}

-- =============================================================================
-- Model Name Builder
-- =============================================================================

--- Get visual models for a cart type
--- Returns upgrade-specific models if cart is upgraded, otherwise standard models
--- Falls back to convention-based naming if no models registered
---@param cart InventoryItem The cart item
---@return VisualModels|nil The visual model names, or nil if can't determine
local function getVisualModels(cart)
    local cartData = SaucedCarts.getCartData(cart)
    -- Cache debug state once for this function (avoids multiple getDebug() calls)
    local isDebug = getDebug()

    -- Check for upgrade-specific models first
    if cartData and cartData.upgradeModels then
        -- Get upgrade key from Upgrades module
        local upgradeKey = nil
        if SaucedCarts.Upgrades and SaucedCarts.Upgrades.getUpgradeKey then
            upgradeKey = SaucedCarts.Upgrades.getUpgradeKey(cart)
        end

        if upgradeKey and cartData.upgradeModels[upgradeKey] then
            if isDebug then
                local fullType = cart and cart:getFullType() or "nil"
                SaucedCarts.debug(function() return "getVisualModels: using upgradeModels." .. upgradeKey .. " for " .. fullType end)
            end
            return cartData.upgradeModels[upgradeKey]
        end
    end

    -- Standard visual models from registration
    if cartData and cartData.visualModels then
        return cartData.visualModels
    end

    -- Fallback: convention-based naming from item's SCRIPT-DEFINED StaticModel
    -- IMPORTANT: Use getScriptItem():getStaticModel() to get the ORIGINAL model,
    -- not cart:getStaticModel() which returns the runtime value from ModData.
    -- After we call setStaticModel(), the runtime value is overwritten and we'd
    -- incorrectly derive models from the already-switched model name.
    local scriptItem = cart:getScriptItem()
    local originalModel = scriptItem and scriptItem:getStaticModel() or nil
    if originalModel and type(originalModel) == "string" then
        -- Try to extract base name (strip "Model" suffix if present)
        local baseName = originalModel:match("^(.+)Model$")
        if baseName then
            -- Safety: strip fill state suffixes in case script defines StaticModel as partial/full variant
            baseName = baseName:gsub("Partial$", ""):gsub("Full$", "")
            return {
                empty = baseName .. "Model",
                partial = baseName .. "PartialModel",
                full = baseName .. "FullModel",
            }
        end
    end

    -- Last resort: use ShoppingCart models (original hardcoded behavior)
    -- Log a notice (not debug) so addon developers know their cart is using fallback models
    local fullType = cart and cart:getFullType() or "nil"
    if fullType and fullType ~= "nil" and not warnedFallback[fullType] then
        SaucedCarts.debug("NOTICE: Cart '" .. fullType ..
            "' using ShoppingCart visual models. Consider adding visualModels to registration.")
        warnedFallback[fullType] = true
    end
    return {
        empty = "ShoppingCartModel",
        partial = "ShoppingCartPartialModel",
        full = "ShoppingCartFullModel",
    }
end

--- Build model name from fill state for a specific cart
---@param cart InventoryItem The cart item
---@param fillState string "empty", "partial", or "full"
---@return string modelName The model name
local function buildModelName(cart, fillState)
    local visualModels = getVisualModels(cart)
    if not visualModels then
        -- Shouldn't happen, but safety fallback
        return "ShoppingCartModel"
    end
    return visualModels[fillState] or visualModels.empty
end

-- =============================================================================
-- State Calculation
-- =============================================================================

--- Calculate fill state based on container capacity usage
--- When player is provided, accounts for Organized/Disorganized trait bonuses
---@param cart InventoryItem The cart item
---@param player IsoPlayer|nil Optional player for trait-aware capacity
---@return string fillState "empty", "partial", or "full"
local function calculateFillState(cart, player)
    local container = cart:getItemContainer()
    if not container then
        return "empty"
    end

    local capacity
    if player then
        capacity = container:getEffectiveCapacity(player)
    else
        capacity = container:getCapacity()
    end
    if capacity <= 0 then
        return "empty"
    end

    local usedWeight = container:getCapacityWeight()
    local fillPercent = usedWeight / capacity

    if fillPercent >= FILL_FULL_THRESHOLD then
        return "full"
    elseif fillPercent >= FILL_PARTIAL_THRESHOLD then
        return "partial"
    else
        return "empty"
    end
end

-- =============================================================================
-- Model Application
-- =============================================================================

--- Apply model to cart (both static and world models)
---@param cart InventoryItem The cart item
---@param modelName string The model name to apply
---@param player IsoPlayer|nil The player (for model refresh)
local function applyModel(cart, modelName, player)
    -- Update inventory/equipped model
    cart:setStaticModel(modelName)

    -- ALWAYS update world static model (so it's correct when dropped)
    cart:setWorldStaticModel(modelName)

    -- If currently on ground, invalidate atlas cache to force 3D model refresh
    -- The atlas cache checks worldScale in isStillValid() - changing it invalidates the cache
    -- We toggle between two imperceptibly different values (1.0 and 1.0001)
    -- NOTE: Do NOT call softReset() - on IsoWorldInventoryObject it REMOVES the item!
    local worldItem = cart:getWorldItem()
    if worldItem then
        -- Toggle worldScale to invalidate atlas cache
        -- Note: cart.worldScale field access may not work from Lua, so we track in ModData
        local modData = cart:getModData()
        local lastScale = modData.SaucedCarts_lastWorldScale or 1.0
        local newScale = (lastScale < 1.0001) and 1.0001 or 1.0
        cart:setWorldScale(newScale)
        modData.SaucedCarts_lastWorldScale = newScale

        -- Call updateSprite to refresh the 2D texture/icon
        worldItem:updateSprite()

        -- Invalidate render chunk to force chunk texture re-render
        -- Flag 256 = DIRTY_OBJECT_MODIFY (from FBORenderChunk.java)
        local square = worldItem:getSquare()
        if square then
            pcall(function()
                square:invalidateRenderChunkLevel(256)
            end)
        end
    end

    -- Force refresh if equipped
    if player and player:getPrimaryHandItem() == cart then
        player:resetEquippedHandsModels()
    end
end

-- =============================================================================
-- Visual Update
-- =============================================================================

--- Update cart visual based on current fill state and upgrade state
--- Call this whenever container contents change or upgrades are installed
---@param cart InventoryItem The cart item to update
---@param player IsoPlayer|nil The player who owns the cart (for MP sync)
---@return boolean changed Whether the visual state changed
local function updateCartVisual(cart, player)
    if not cart then return false end
    if not SaucedCarts.isCart(cart) then return false end

    local modData = cart:getModData()

    -- Calculate current state (player param enables trait-aware capacity)
    local fillState = calculateFillState(cart, player)

    -- Get current upgrade key (nil if no upgrades)
    local upgradeKey = nil
    if SaucedCarts.Upgrades and SaucedCarts.Upgrades.getUpgradeKey then
        upgradeKey = SaucedCarts.Upgrades.getUpgradeKey(cart)
    end

    -- Get previous states
    local prevFillState = modData.SaucedCarts_fillState or "empty"
    local prevUpgradeKey = modData.SaucedCarts_upgradeKey  -- nil if never set

    -- Check if anything changed (fill state OR upgrade state)
    if fillState == prevFillState and upgradeKey == prevUpgradeKey then
        return false  -- No change needed
    end

    -- Build and apply new model (uses cart-specific visualModels if registered)
    local modelName = buildModelName(cart, fillState)
    applyModel(cart, modelName, player)

    -- Store new state
    modData.SaucedCarts_fillState = fillState
    modData.SaucedCarts_upgradeKey = upgradeKey

    -- MP sync: Server-authoritative - only server triggers sync to clients
    -- Clients update locally for responsiveness, server corrects on next sync point
    -- Note: syncItemModData fails for world items (container not replicated to clients)
    -- Ground carts sync via onCartVisualUpdate event → syncGroundCartVisual broadcast
    if isServer() and player and not cart:getWorldItem() then
        syncItemModData(player, cart)
        syncItemFields(player, cart)
    end

    -- Debug logging (guarded to avoid string concat when debug off)
    if getDebug() then
        local upgradeStr = upgradeKey or "none"
        SaucedCarts.debug(function() return "Cart visual updated: fill " .. prevFillState .. " -> " .. fillState .. ", upgrade=" .. upgradeStr .. " (model: " .. modelName .. ")" end)
    end

    return true
end

-- =============================================================================
-- Exports
-- =============================================================================

SaucedCarts.updateCartVisual = updateCartVisual
SaucedCarts.calculateFillState = calculateFillState
SaucedCarts.getVisualModels = getVisualModels
SaucedCarts.buildCartModelName = buildModelName  -- Note: now takes (cart, fillState)

-- Alias for backwards compatibility
SaucedCarts.refreshCartVisual = updateCartVisual

-- =============================================================================
-- Model Preloading
-- =============================================================================
-- Models are loaded on-demand during first render. If a model isn't loaded when
-- we switch to it, the chunk renders with NoModel, gets marked clean, and the
-- model loads too late to trigger a redraw. Preloading ensures all models are
-- ready before any visual switching occurs.

--- Preload all cart visual models to prevent async loading issues
--- Called on OnGameStart to ensure models are ready before any visual switching
local function preloadCartVisualModels()
    -- Collect all model names from all registered cart types
    local modelsToLoad = {}
    local seen = {}

    local function addModel(modelName)
        if modelName and not seen[modelName] then
            seen[modelName] = true
            table.insert(modelsToLoad, modelName)
        end
    end

    -- Add default ShoppingCart models (always needed)
    addModel("ShoppingCartModel")
    addModel("ShoppingCartPartialModel")
    addModel("ShoppingCartFullModel")

    -- Add models from all registered cart types (addon support)
    for fullType, cartData in pairs(SaucedCarts.CartTypes) do
        if cartData.visualModels then
            addModel(cartData.visualModels.empty)
            addModel(cartData.visualModels.partial)
            addModel(cartData.visualModels.full)
        end
        -- Add upgrade-specific models if defined
        if cartData.upgradeModels then
            for upgradeKey, models in pairs(cartData.upgradeModels) do
                addModel(models.empty)
                addModel(models.partial)
                addModel(models.full)
            end
        end
    end

    SaucedCarts.debug(function() return "Preloading " .. #modelsToLoad .. " cart visual models..." end)

    -- Preload each model using the Lua global loadZomboidModel
    for _, modelName in ipairs(modelsToLoad) do
        local modelScript = getScriptManager():getModelScript(modelName)
        if modelScript then
            if not modelScript.loadedModel then
                local mesh = modelScript:getMeshName()
                local tex = modelScript:getTextureName()
                local shader = modelScript:getShaderName() or "basicEffect"
                local isStatic = modelScript:isStatic()

                -- loadZomboidModel triggers synchronous load
                loadZomboidModel(modelName, mesh, tex, shader, isStatic)
                SaucedCarts.debug(function() return "Preloaded model: " .. modelName end)
            else
                SaucedCarts.debug(function() return "Model already loaded: " .. modelName end)
            end
        else
            SaucedCarts.debug("WARNING: ModelScript not found for: " .. modelName)
        end
    end

    SaucedCarts.debug("Cart visual models preloaded")
end

Events.OnGameStart.Add(preloadCartVisualModels)

SaucedCarts.debug("CartVisuals loaded")
