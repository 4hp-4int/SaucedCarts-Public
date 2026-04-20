-- ============================================================================
-- SaucedCarts/CapacityOverride.lua
-- ============================================================================
-- PURPOSE: Override capacity methods for cart items to bypass PZ's hardcoded
--          capacity caps. Two caps are bypassed:
--
--          1. InventoryContainer cap: (MAX_CAPACITY_BAG - actualWeight) = 42
--             Bypassed by delegating to inner ItemContainer methods.
--
--          2. ItemContainer cap: Math.min(capacity, 50)  [line 155-156]
--             Bypassed by reading the raw capacity from ModData, where
--             applyMultipliers stores it before Java caps the value.
--
--          This enables sandbox CapacityMultiplier > 100% AND correct
--          Organized/Disorganized trait bonuses at any capacity level.
--
-- CONTEXT: SHARED (client + server)
--          Metatable overrides apply to all instances of each class.
--          Only SaucedCarts items are affected (safeIsCart check).
--
-- SAFETY: All overrides use pcall wrapping. On any error, falls back to
--         original PZ methods. Non-cart items are completely unaffected.
--
-- NOTE: Java-internal calls (e.g., Java code calling this.getCapacity())
--       still use the original Java methods. Our overrides only affect
--       calls made from Lua, which covers PZ's UI and transfer code.
--       Java's AddItem() has no capacity check, so items physically fit.
--
-- IMPORTANT: PZ's Kahlua does NOT support direct Java field access from Lua.
--            Always use getter methods (e.g., self:getContainingItem() not
--            self.containingItem). Raw capacity is stored in ModData by
--            applyMultipliers (Core.lua) since Java's getCapacity() caps at 50.
--
-- LOAD ORDER: Requires Core.lua explicitly. Also loaded by Core.lua after
--             ContainerRestrictions. Lua's require caching prevents double-load.
-- ============================================================================

require "SaucedCarts/Core"

---@class SaucedCartsCapacityOverride
local CapacityOverride = {}

local overrideInitialized = false

-- Cached trait/tag references (set during init)
local TRAIT_ORGANIZED
local TRAIT_DISORGANIZED
local TAG_HEAVY_ITEM

-- ModData key for storing raw (uncapped) capacity
local RAW_CAP_KEY = "SaucedCarts_rawCapacity"

--- Compute effective capacity with trait bonuses applied to a raw capacity value.
--- Replicates ItemContainer.getEffectiveCapacity logic from Java.
---@param rawCapacity number The raw (uncapped) capacity
---@param chr IsoGameCharacter|nil The character to check traits for
---@param parent any The container's parent object
---@param containerType string The container type string
---@return number The effective capacity after trait bonuses
local function computeEffectiveCapacity(rawCapacity, chr, parent, containerType)
    if chr
        and not instanceof(parent, "IsoGameCharacter")
        and not instanceof(parent, "IsoDeadBody")
        and containerType ~= "floor"
    then
        if TRAIT_ORGANIZED and chr:hasTrait(TRAIT_ORGANIZED) then
            return math.max(math.floor(rawCapacity * 1.3), rawCapacity + 1)
        elseif TRAIT_DISORGANIZED and chr:hasTrait(TRAIT_DISORGANIZED) then
            return math.max(math.floor(rawCapacity * 0.7), 1)
        end
    end
    return rawCapacity
end

--- Floating point correction matching Java's ItemContainer.floatingPointCorrection.
--- Rounds to 2 decimal places (round-half-up). Pure Lua avoids JNI bridge overhead.
---@param val number The value to correct
---@return number The corrected value
local function floatingPointCorrection(val)
    return math.floor(val * 100 + 0.5) / 100
end

--- Get the raw (uncapped) capacity for a cart's inner ItemContainer.
--- Computes dynamically from sandbox settings so changes take effect immediately.
--- Returns nil if not a cart.
---@param container ItemContainer The inner container to check
---@return number|nil rawCapacity The raw capacity, or nil
local function getCartRawCapacity(container)
    local ci = container:getContainingItem()
    if not ci or not SaucedCarts.safeIsCart(ci) then return nil end

    -- Compute from sandbox setting dynamically (respects mid-game changes)
    local cartData = SaucedCarts.getCartData(ci)
    if not cartData then return nil end
    local capMult = SandboxVars.SaucedCarts and SandboxVars.SaucedCarts.CapacityMultiplier or 100
    return math.floor(cartData.capacity * capMult / 100)
end

local function initCapacityOverride()
    if overrideInitialized then
        SaucedCarts.debug("CapacityOverride already initialized, skipping")
        return
    end

    -- Cache trait enum references
    if CharacterTrait then
        TRAIT_ORGANIZED = CharacterTrait.ORGANIZED
        TRAIT_DISORGANIZED = CharacterTrait.DISORGANIZED
    end

    -- Cache tag reference for hasRoomFor HEAVY_ITEM check
    if ItemTag then
        TAG_HEAVY_ITEM = ItemTag.HEAVY_ITEM
    end

    -- ========================================================================
    -- ItemContainer overrides (bypass the 50 cap via ModData raw capacity)
    -- ========================================================================

    -- Resolve the ItemContainer class token. On dedicated servers, some PZ
    -- classes take longer to reach Lua or may not be exposed at all; an
    -- unguarded access raises inside the OnGameStart pcall and leaves init
    -- silently skipped. Log the specific failure so we can see it.
    if type(ItemContainer) == "nil" then
        SaucedCarts.error("CapacityOverride: ItemContainer global not available (isServer="
            .. tostring(isServer()) .. " isClient=" .. tostring(isClient()) .. ")")
        return
    end

    local okClass, itemContClass = pcall(function() return ItemContainer.class end)
    if not okClass or not itemContClass then
        SaucedCarts.error("CapacityOverride: ItemContainer.class lookup failed (" .. tostring(itemContClass) .. ")")
        return
    end

    local itemContMeta = __classmetatables and __classmetatables[itemContClass]
    if not itemContMeta then
        SaucedCarts.error("CapacityOverride: __classmetatables[ItemContainer.class] is nil — override NOT initialized")
        return
    end

    local origICGetCapacity = itemContMeta.__index.getCapacity
    local origICGetEffectiveCapacity = itemContMeta.__index.getEffectiveCapacity
    local origICHasRoomFor = itemContMeta.__index.hasRoomFor

    -- Override ItemContainer.getCapacity: return raw capacity for carts
    -- Java's getCapacity() applies Math.min(capacity, 50) for container items.
    -- We read the raw value from ModData (stored by applyMultipliers).
    itemContMeta.__index.getCapacity = function(self)
        local success, result = pcall(function()
            return getCartRawCapacity(self)
        end)

        if success and result then
            return result
        end

        return origICGetCapacity(self)
    end

    -- Override ItemContainer.getEffectiveCapacity: raw capacity + trait bonuses
    itemContMeta.__index.getEffectiveCapacity = function(self, chr)
        local success, result = pcall(function()
            local rawCap = getCartRawCapacity(self)
            if not rawCap then return nil end
            if not chr then return rawCap end
            return computeEffectiveCapacity(rawCap, chr, self:getParent(), self:getType())
        end)

        if success and result then
            return result
        end

        return origICGetEffectiveCapacity(self, chr)
    end

    -- Override ItemContainer.hasRoomFor: use raw capacity for cart weight check
    -- Only overrides when cart raw capacity > 50 (i.e., sandbox multiplier > 100%).
    -- Replicates Java's hasRoomFor checks for cart containers.
    --
    -- Java has two overloads:
    --   hasRoomFor(chr, InventoryItem) - item checks, then delegates to weight overload
    --   hasRoomFor(chr, float)         - weight-based capacity checks
    -- Lua receives both in one function via type dispatch on weightOrItem.
    itemContMeta.__index.hasRoomFor = function(self, chr, weightOrItem)
        local success, customResult = pcall(function()
            local rawCap = getCartRawCapacity(self)
            if not rawCap then return nil end

            local addWeight
            local itemRef  -- nil when called with weight overload
            if type(weightOrItem) == "number" then
                addWeight = weightOrItem
            else
                itemRef = weightOrItem
                addWeight = weightOrItem:getUnequippedWeight()
            end

            -- ============================================================
            -- ITEM-PHASE CHECKS (only when called with InventoryItem)
            -- Mirrors Java's hasRoomFor(chr, InventoryItem)
            -- ============================================================
            if itemRef then
                -- HEAVY_ITEM in vehicle: block heavy items from entering
                -- character-parented containers while character is in a vehicle
                if TAG_HEAVY_ITEM and chr and chr:getVehicle()
                    and itemRef:hasTag(TAG_HEAVY_ITEM)
                    and instanceof(self:getParent(), "IsoGameCharacter")
                then
                    return false
                end

                -- isItemAllowed: delegates to Java (includes ContainerRestrictions hook chain)
                if not self:isItemAllowed(itemRef) then
                    return false
                end

                -- equipParent capacity check: when cart is equipped, items
                -- transferred in must also fit in the parent character's inventory
                local ci = self:getContainingItem()
                if ci then
                    local equipParent = ci:getEquipParent()
                    if equipParent and equipParent:getInventory() then
                        local parentInv = equipParent:getInventory()
                        -- Only check if item is NOT already in parent inventory
                        if not parentInv:contains(itemRef) then
                            if not chr
                                or floatingPointCorrection(parentInv:getCapacityWeight())
                                    + addWeight > parentInv:getEffectiveCapacity(chr)
                            then
                                return false
                            end
                        end
                    end
                end
            end

            -- ============================================================
            -- WEIGHT-PHASE CHECKS (both overloads reach here)
            -- Mirrors Java's hasRoomFor(chr, float)
            -- ============================================================

            local ci = self:getContainingItem()

            -- MaxItemSize check
            if ci then
                local maxSize = ci:getMaxItemSize()
                if maxSize > 0 and addWeight > maxSize then
                    return false
                end
            end

            -- Ground weight limit: SKIPPED for carts.
            -- Items going into a cart are not "on the floor" — they're inside the
            -- cart's container. PZ's floor weight limit (50kg per tile) is for loose
            -- items, not for container contents. The cart itself counts toward the
            -- tile limit, but its contents (with weight reduction) should not block
            -- transfers into the cart. The cart's own capacity is the only limit.

            -- Vehicle container parent check (with floatingPointCorrection)
            if ci and ci:getContainer() then
                local vehiclePart = ci:getContainer():getVehiclePart()
                if vehiclePart then
                    local parentCap = ci:getContainer():getEffectiveCapacity(chr)
                    if floatingPointCorrection(ci:getContainer():getCapacityWeight() + addWeight) > parentCap then
                        return false
                    end
                end
            end

            -- Main capacity check (with floatingPointCorrection on current weight)
            local effectiveCap = computeEffectiveCapacity(
                rawCap, chr, self:getParent(), self:getType())
            return floatingPointCorrection(self:getCapacityWeight()) + addWeight <= effectiveCap
        end)

        if success and customResult ~= nil then
            return customResult
        end

        -- Non-cart, capacity <= 50, or error: use original
        return origICHasRoomFor(self, chr, weightOrItem)
    end

    -- ========================================================================
    -- InventoryContainer overrides (bypass the 50-weight wrapper cap)
    -- ========================================================================
    -- These delegate to inner ItemContainer methods via Lua calls, which now
    -- use the overridden ItemContainer methods above (returning raw capacity).

    if type(InventoryContainer) == "nil" then
        SaucedCarts.error("CapacityOverride: InventoryContainer global not available — ItemContainer overrides installed but outer-wrapper overrides skipped")
        overrideInitialized = true  -- partial is better than nothing
        return
    end

    local okIC, invContClass = pcall(function() return InventoryContainer.class end)
    if not okIC or not invContClass then
        SaucedCarts.error("CapacityOverride: InventoryContainer.class lookup failed (" .. tostring(invContClass) .. ")")
        overrideInitialized = true
        return
    end

    local invContMeta = __classmetatables and __classmetatables[invContClass]
    if not invContMeta then
        SaucedCarts.error("CapacityOverride: __classmetatables[InventoryContainer.class] is nil — outer-wrapper overrides skipped")
        overrideInitialized = true
        return
    end

    local originalGetCapacity = invContMeta.__index.getCapacity
    local originalGetEffectiveCapacity = invContMeta.__index.getEffectiveCapacity

    if not originalGetCapacity or not originalGetEffectiveCapacity then
        SaucedCarts.error("InventoryContainer capacity methods not found — outer-wrapper overrides skipped")
        overrideInitialized = true
        return
    end

    -- Override getCapacity: bypass (50 - weight) cap for cart items
    invContMeta.__index.getCapacity = function(self)
        local success, result = pcall(function()
            if SaucedCarts.safeIsCart(self) then
                local container = self:getItemContainer()
                if container then
                    return container:getCapacity()
                end
            end
        end)

        if success and result then
            return result
        end

        return originalGetCapacity(self)
    end

    -- Override getEffectiveCapacity: bypass (50 - weight) cap, preserve trait bonuses
    invContMeta.__index.getEffectiveCapacity = function(self, chr)
        local success, result = pcall(function()
            if SaucedCarts.safeIsCart(self) then
                local container = self:getItemContainer()
                if container then
                    return container:getEffectiveCapacity(chr)
                end
            end
        end)

        if success and result then
            return result
        end

        return originalGetEffectiveCapacity(self, chr)
    end

    overrideInitialized = true
    -- Log at info level (not debug) so the fact that override installed
    -- is visible in the dedicated server log without debug flags.
    SaucedCarts.log(string.format(
        "CapacityOverride initialized (isServer=%s isClient=%s)",
        tostring(isServer()), tostring(isClient())))
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

-- Initialize on game start (after __classmetatables is fully populated)
local function onGameStart()
    -- Check if mod is enabled
    if SandboxVars.SaucedCarts and not SandboxVars.SaucedCarts.EnableMod then
        return
    end

    -- Wrap init in pcall so OnGameStart's listener can't silently swallow
    -- errors. Any failure lands in the server DebugLog with a context tag
    -- instead of leaving `overrideInitialized = false` with no trace.
    local ok, err = pcall(initCapacityOverride)
    if not ok then
        SaucedCarts.error("CapacityOverride.onGameStart FAILED: " .. tostring(err))
    end
end

Events.OnGameStart.Add(onGameStart)

-- Dedicated server doesn't reliably fire OnGameStart for mod Lua in all
-- startup orders; wire OnServerStarted as a belt-and-braces trigger. Init
-- is idempotent (overrideInitialized flag), so double-firing is safe.
if Events.OnServerStarted and Events.OnServerStarted.Add then
    Events.OnServerStarted.Add(onGameStart)
end

-- File-load time attempt: if the relevant metatables are already
-- populated when this module finishes loading (usually true because
-- Lua file-load happens after PZ registers @UsedFromLua classes), install
-- the override immediately and skip the event dance entirely. This is
-- the most reliable path on dedicated server.
if ItemContainer and InventoryContainer and __classmetatables then
    local ok, err = pcall(initCapacityOverride)
    if not ok then
        SaucedCarts.error("CapacityOverride.load-time init FAILED: " .. tostring(err))
    end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Check if capacity override is active
---@return boolean True if override is initialized
function CapacityOverride.isInitialized()
    return overrideInitialized
end

--- Get the ModData key used for raw capacity storage.
--- Used by Core.lua applyMultipliers to store the raw value.
---@return string The ModData key
function CapacityOverride.getRawCapacityKey()
    return RAW_CAP_KEY
end

SaucedCarts.CapacityOverride = CapacityOverride

-- ============================================================================
-- TEST HOOKS
-- ============================================================================
-- Expose internal pure helpers for offline tests. Underscore prefix signals
-- "do not call from production code" — production callers go through the
-- metatable overrides installed in initCapacityOverride.
CapacityOverride._computeEffectiveCapacity = computeEffectiveCapacity
CapacityOverride._floatingPointCorrection  = floatingPointCorrection
CapacityOverride._getCartRawCapacity       = getCartRawCapacity
CapacityOverride._rawCapKey                = RAW_CAP_KEY

SaucedCarts.debug("CapacityOverride module loaded")

return CapacityOverride
