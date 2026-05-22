-- ============================================================================
-- SaucedCarts/CorpseStorage.lua
-- ============================================================================
-- PURPOSE: Loading dragged corpses into cart inventories.
--
--          Vanilla has this mechanic for a 19-string hardcoded allowlist of
--          container types (crate, coffin, dumpster, etc.) via
--          ItemContainer.canHumanCorpseFit() + Commands.deadBody.addBody.
--          Carts are not in the list. A Lua override on canHumanCorpseFit is
--          bypassed by Java-internal call chains (getSuitableContainersTo
--          DropCorpseInSquare, canItemFit), the same way Java-internal
--          getEffectiveCapacity bypassed CapacityOverride in v2.1.4.
--
--          We own the pipeline: cart-specific weight gate, client action,
--          server handler. Vanilla's corpse-to-item serialization
--          (IsoDeadBody.getItem / InventoryItem.loadCorpseFromByteData) is
--          still the one-and-only round-trip path — we just drive it.
--
-- CONTEXT: SHARED. Network command registration on server.
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/Network"

-- Pre-register Java-side grapple events that the engine fires but doesn't
-- declare in LuaEventManager's name table. Our removeGhostCorpse path
-- calls IsoZombie:removeFromWorld() which triggers GrapplerLetGo inside
-- BaseGrappleable; without the event being pre-registered, PZ logs
-- "adding unknown event" as a cosmetic warning. Registering is idempotent.
if LuaEventManager and LuaEventManager.AddEvent then
    pcall(function() LuaEventManager.AddEvent("GrapplerLetGo") end)
end

---@class SaucedCartsCorpseStorage
local CorpseStorage = {}

--- Check the sandbox option gating the entire corpse-storage feature.
--- All load/unload/context-menu/hotkey code paths short-circuit when
--- this returns false. Safe to call before SandboxVars is loaded — we
--- default to enabled in that window (matches other gates in Core).
---@return boolean
function CorpseStorage.isEnabled()
    local s = SandboxVars and SandboxVars.SaucedCarts
    if not s then return false end
    if s.EnableMod == false then return false end
    -- BETA gate: require explicit `true`. nil (v2.1.4 saves missing the
    -- new option) reads as "not enabled" so upgrading from v2.1.4 →
    -- v2.1.5 doesn't silently activate the beta feature. The previous
    -- `== false` check fell through on nil and accidentally enabled the
    -- BETA on every upgraded save.
    return s.EnableCorpseStorage == true
end

-- ============================================================================
-- PUBLIC HELPERS
-- ============================================================================

--- Is this InventoryItem one of the vanilla corpse item types?
--- "Base.CorpseMale", "Base.CorpseFemale", "Base.CorpseAnimal" are the three
--- types InventoryItem.isHumanCorpse / isAnimalCorpse recognize. Callable
--- off a plain item stored in a cart inventory.
---@param item InventoryItem|nil
---@return boolean
function CorpseStorage.isCorpseItem(item)
    if not item then return false end
    if type(item) == "userdata" and item.isHumanCorpse then
        local ok, isHuman = pcall(function() return item:isHumanCorpse() end)
        if ok and isHuman then return true end
        local okA, isAnimal = pcall(function() return item:isAnimalCorpse() end)
        if okA and isAnimal then return true end
        return false
    end
    -- Offline / table mocks: match by fullType string.
    local ok, ft = pcall(function() return item.getFullType and item:getFullType() end)
    if not ok or not ft then return false end
    return ft == "Base.CorpseMale" or ft == "Base.CorpseFemale" or ft == "Base.CorpseAnimal"
end

--- Weight gate for loading a corpse into a cart container.
--- Cart-specific: sidesteps vanilla's 19-string allowlist in
--- ItemContainer.canHumanCorpseFit. Uses getCapacity() + getCapacityWeight()
--- rather than getAvailableWeightCapacity() because the Java-internal
--- version bypasses our Lua getCapacity override (same class of issue as
--- v2.1.4 TransactionManager regression).
---
--- NB: PZ ItemContainer.getWeightReduction reduces encumbrance on the
--- CARRYING CHARACTER, not the container's capacity weight accounting.
--- A 20kg corpse in a 95%-reduction cart still consumes 20kg of the
--- cart's capacity (but only ~1kg off the player's movement penalty).
--- So the gate uses raw weight, matching Java's cap model exactly.
---@param cart InventoryItem The cart item (outer InventoryContainer)
---@param corpseWeight number Corpse weight in kg (from InventoryItem:getActualWeight)
---@return boolean ok, string|nil reason
function CorpseStorage.canLoadCorpseIntoCart(cart, corpseWeight)
    if not cart then return false, "no cart" end
    if not SaucedCarts.safeIsCart(cart) then return false, "not a cart" end
    if type(corpseWeight) ~= "number" or corpseWeight < 0 then
        return false, "invalid weight"
    end

    local container = cart.getItemContainer and cart:getItemContainer()
    if not container then return false, "no inner container" end

    local cap = container.getCapacity and container:getCapacity() or 0
    local cur = container.getCapacityWeight and container:getCapacityWeight() or 0
    local avail = cap - cur

    if avail < corpseWeight then
        return false, "cart full"
    end
    return true
end

-- ============================================================================
-- ROT
-- ============================================================================
-- Vanilla rot timeline (IsoDeadBody.updateBodies, IsoDeadBody.java:1501):
--   hoursForRemoval = SandboxOptions.hoursForCorpseRemoval (default 216 = 9d)
--   stage hours     = hoursForRemoval / 3 (~72h per zombie rot stage)
--   skeletonAt      = hoursForRemoval                (loot-loss point)
--   removalAt       = hoursForRemoval + stage hours  (~12d, full vanish)
--
-- Vanilla's updateBodies only iterates ObjectIDManager's live IsoDeadBodies;
-- corpses sitting in our cart as byteData are invisible to it. Without our
-- accounting, stored corpses freeze in time. Solution:
--
--   On load:   stamp `it:getModData().SaucedCarts_deathTime = body:getDeathTime()`
--   On unload: restore via body:setDeathTime(stamped) so vanilla's ticker
--              picks up rot at the correct stage.
--   In-cart:   periodically (cart event handlers) walk contents; if any
--              corpse's effective age >= removalAt, drop it silently —
--              matches vanilla's full-removal semantics (no bones loot).
--
-- Sandbox `hoursForCorpseRemoval == 0` means "never decay" → all checks
-- short-circuit, corpses persist forever.

local CORPSE_DEATHTIME_KEY = "SaucedCarts_deathTime"

--- Read the master rot timeline from sandbox. Returns (skeletonAt, removalAt)
--- in world hours, or (nil, nil) when sandbox says "never decay".
---
--- IMPORTANT (2026-04-25 bugfix): Java fields like
---   SandboxOptions.instance.hoursForCorpseRemoval
--- aren't exposed to Lua as direct field accesses (they return nil). The
--- decompiled Java code uses direct field access because Java sees the
--- field through reflection — Lua has to go through getOptionByName, and
--- the option's NAME IS CAPITALIZED ("HoursForCorpseRemoval") not the
--- camelCase field name. Without this, getRotThresholds always returned
--- nil — meaning every world acted as "never decay" regardless of sandbox.
local function getRotThresholds()
    if not SandboxOptions or not SandboxOptions.instance then return nil, nil end
    local sb = SandboxOptions.instance
    if not sb.getOptionByName then return nil, nil end
    local opt = sb:getOptionByName("HoursForCorpseRemoval")
    if not opt or not opt.getValue then return nil, nil end
    local hoursForRemoval = opt:getValue() or 0
    if not hoursForRemoval or hoursForRemoval <= 0 then return nil, nil end
    local hoursPerStage = hoursForRemoval / 3.0
    return hoursForRemoval, hoursForRemoval + hoursPerStage
end

local function currentWorldHours()
    if GameTime and GameTime.getInstance then
        local gt = GameTime:getInstance()
        if gt and gt.getWorldAgeHours then return gt:getWorldAgeHours() end
    end
    return 0
end

--- Stamp the body's deathTime onto the corpse item's modData. Called once
--- after AddItem in the load handler. Idempotent: missing setters are no-ops.
---
--- Defensive: IsoDeadBody.deathTime defaults to -1.0F until a constructor
--- or load path sets it. If we read -1 (or any value <= 0), fall back to
--- currentWorldHours() so the rot clock starts from "now" rather than
--- treating the corpse as 1.4-billion hours old (current - (-1)).
function CorpseStorage.stampDeathTime(corpseItem, body)
    if not corpseItem or not body then return end
    if not corpseItem.getModData then return end
    local md = corpseItem:getModData()
    if not md then return end
    local dt = body.getDeathTime and body:getDeathTime()
    if type(dt) ~= "number" or dt <= 0 then
        dt = currentWorldHours()
    end
    md[CORPSE_DEATHTIME_KEY] = dt
    SaucedCarts.log(function()
        return "stampDeathTime: corpse item " ..
            tostring(corpseItem.getID and corpseItem:getID() or "?") ..
            " stamped deathTime=" .. tostring(dt) ..
            " (worldHours=" .. tostring(currentWorldHours()) .. ")"
    end)
end

--- Read stamped deathTime; returns nil if never stamped (legacy item).
function CorpseStorage.getStampedDeathTime(corpseItem)
    if not corpseItem or not corpseItem.getModData then return nil end
    local md = corpseItem:getModData()
    if not md then return nil end
    return md[CORPSE_DEATHTIME_KEY]
end

--- Effective age of a stored corpse item in world hours. Falls back to 0
--- (treat as fresh) if the item was loaded by a pre-rot version of the mod
--- (no stamp present).
function CorpseStorage.effectiveAge(corpseItem)
    local dt = CorpseStorage.getStampedDeathTime(corpseItem)
    if not dt then return 0 end
    local age = currentWorldHours() - dt
    return age > 0 and age or 0
end

--- After loadCorpseFromByteData on unload, restore the stamped deathTime so
--- vanilla's updateBodies ticker resumes rot from the correct stage. Without
--- this, the rematerialized body's deathTime is whatever was baked into
--- byteData at the moment we serialized — which in turn was the body's
--- deathTime AT THAT MOMENT, not the original. Re-stamping is idempotent for
--- corpses that round-trip through multiple load/unload cycles.
function CorpseStorage.restoreDeathTime(corpseItem, body)
    if not corpseItem or not body or not body.setDeathTime then return end
    local dt = CorpseStorage.getStampedDeathTime(corpseItem)
    if type(dt) ~= "number" then return end
    pcall(function() body:setDeathTime(dt) end)
end

--- Walk a cart's inner container and remove any corpse items whose effective
--- age is past vanilla's removal threshold. Matches vanilla updateBodies
--- semantics — past this age, the world body would have despawned entirely
--- (no bones, no loot). Lazy: called from cart event handlers (equip/drop/
--- move), no periodic ticker needed.
---@param cart InventoryItem
---@return number purged how many items were removed
function CorpseStorage.purgeRottedCorpses(cart)
    if not cart or not CorpseStorage.isEnabled() then return 0 end
    -- Threshold = skeletonAt (sandbox HoursForCorpseRemoval). Matches the
    -- unload silent-drop boundary in CartTransferInterceptor / GrabCorpse-
    -- Interceptor. Past skeletonAt the corpse is dead-to-us either way:
    -- can't survive vanilla's despawn tick (would flicker out), can't be
    -- rendered as a skeleton (setSkeleton isn't Lua-exposed). Purging here
    -- keeps cart inventories from accumulating unrecoverable items.
    local skeletonAt = getRotThresholds()
    if not skeletonAt then return 0 end  -- sandbox: never decay

    local container = cart.getItemContainer and cart:getItemContainer()
    if not container or not container.getItems then return 0 end

    local purged = 0
    pcall(function()
        local items = container:getItems()
        if not items then return end
        for i = items:size() - 1, 0, -1 do
            local it = items:get(i)
            if it and CorpseStorage.isCorpseItem(it) then
                local age = CorpseStorage.effectiveAge(it)
                if age >= skeletonAt then
                    pcall(function() container:Remove(it) end)
                    purged = purged + 1
                end
            end
        end
    end)

    if purged > 0 then
        SaucedCarts.log(function()
            return "purgeRottedCorpses: removed " .. purged ..
                " past-removal corpses from cart " ..
                tostring(cart.getID and cart:getID() or "?")
        end)
        if container.setDrawDirty then
            pcall(function() container:setDrawDirty(true) end)
        end
    end
    return purged
end

CorpseStorage._CORPSE_DEATHTIME_KEY = CORPSE_DEATHTIME_KEY
CorpseStorage._getRotThresholds     = getRotThresholds
CorpseStorage._currentWorldHours    = currentWorldHours

-- ============================================================================
-- CART LOOKUP
-- ============================================================================
-- Server-side cart resolution: player's inventory first, then a bounded
-- ground sweep. Mirrors CartTransferInterceptor.findCartNearPlayer. Kept
-- local rather than exported so each handler can tune radius independently.

local function findCartNearPlayer(player, cartId, radius)
    radius = radius or 3
    if not player or not cartId then return nil end

    local inv = player.getInventory and player:getInventory()
    if inv and inv.getItemById then
        local it = inv:getItemById(cartId)
        if it and SaucedCarts.safeIsCart(it) then return it end
    end

    local psq = player.getCurrentSquare and player:getCurrentSquare()
    if not psq or not getCell then return nil end
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

-- ============================================================================
-- SERVER HANDLER
-- ============================================================================
--
-- Flow
--   1. Validate player still dragging + cart still reachable + weight fits
--   2. Resolve grappled target:
--        IsoDeadBody    -> use directly
--        IsoGameCharacter -> becomeCorpseSilently() to produce IsoDeadBody
--   3. deadBody:getItem() — vanilla serializes state into InventoryItem.byteData
--   4. cartContainer:AddItem(corpseItem) + sendAddItemToContainer broadcast
--   5. sq:removeCorpse(deadBody, false) + deadBody:invalidateCorpse()
--   6. player.grappleable:LetGoOfGrappled("SaucedCarts_LoadedToCart")
--
-- Idempotence
--   Double-send from client (network retry, double-perform in MP) is handled
--   by a per-player transient guard. First invocation wins; second sees the
--   guard flag and bails before doing any mutation.

-- Transient in-flight guards keyed by player online id. Cleared on success
-- or failure.
--
-- H5 (2026-04-24): why we keep BOTH `_inFlight` AND the prior C2-removed
-- `isDraggingCorpse` check (now replaced by id-based resolution):
--
--   * `_inFlight[pid]`: protects against WITHIN-TICK double-entry on a
--     single VM. The MP "double-perform" pattern fires `:perform` on
--     both client and server in the same frame; if the same handler ran
--     twice in the same tick it'd cause AddItem to fire twice. The
--     guard is set entering the pcall and cleared after — single-frame
--     re-entry sees inFlight=true and bails.
--
--   * The (now-removed) live-state check protected against ACROSS-CALL
--     duplicate commands from a buggy/malicious client retrying stale
--     loads after release. C2 replaced it with id-based resolution: if
--     the body/zombie can't be resolved by id (already loaded, deleted),
--     the handler bails. The id IS the across-call dedupe key.
--
-- Keeping the in-flight guard is non-redundant: it's the within-tick
-- safety net for the MP shared-action double-perform pattern, which the
-- id-based check would let through on the second entry (id still resolves
-- if the first hasn't completed yet).
local inFlight = {}

local function resolveDeadBody(grappledTarget)
    if not grappledTarget then return nil end
    if instanceof(grappledTarget, "IsoDeadBody") then
        return grappledTarget
    end
    if instanceof(grappledTarget, "IsoGameCharacter")
        and grappledTarget.becomeCorpseSilently then
        local ok, body = pcall(function() return grappledTarget:becomeCorpseSilently() end)
        if ok then return body end
    end
    return nil
end

--- Parse the "reanimated-for-grapple" zombie's tostring to recover the
--- ORIGINAL IsoDeadBody's ObjectID. Vanilla's pickUpCorpse -> reanimate()
--- calls removeFromWorld() on the source body, which does NOT broadcast
--- RemoveCorpseFromMap. Clients keep the body in their local world as a
--- ghost. We use the id to tell each client to purge its local copy.
--- tostring shape: "IsoZombie{ Name:ReanimatedCorpse_IsoDeadBody{ Name:X, ID:NN, ... }, ID:MM ... }"
local function extractOriginalBodyIdFromGrappled(grappledTarget)
    if not grappledTarget then return nil end
    if not (instanceof(grappledTarget, "IsoZombie")
        and grappledTarget.isReanimatedForGrappleOnly
        and grappledTarget:isReanimatedForGrappleOnly()) then
        return nil
    end
    local s = tostring(grappledTarget)
    -- Match the FIRST "ID:NN" inside the nested IsoDeadBody{...} portion —
    -- the zombie's own outer ID comes later.
    local id = s:match("IsoDeadBody%{[^}]-%sID:(%d+)")
    return id and tonumber(id) or nil
end

local function releaseGrapple(player)
    -- Vanilla's ISDropCorpseAction uses character:setDoGrappleLetGo() in
    -- :start(). That's the proper entry point — it coordinates animation
    -- + state + network sync. LetGoOfGrappled directly on the grappleable
    -- is the internal implementation and doesn't unwind client state.
    if player.setDoGrappleLetGo then
        pcall(function() player:setDoGrappleLetGo() end)
    end
end

--- Look up an IsoDeadBody on a given square by its numeric id. Returns
--- nil if no such body is present. Used by the direct-from-world load
--- path where the client identifies the target via coords + id rather
--- than via the grapple state.
local function findBodyAtSquare(x, y, z, bodyId)
    if not (x and y and z and bodyId and getCell) then return nil end
    local sq = getCell():getGridSquare(x, y, z)
    if not sq or not sq.getDeadBodys then return nil end
    local bodies = sq:getDeadBodys()
    if not bodies then return nil end
    for i = 0, bodies:size() - 1 do
        local b = bodies:get(i)
        if b and b.getID and b:getID() == bodyId then return b end
    end
    return nil
end

--- Look up a grapple-wrapper IsoZombie (ReanimatedForGrappleOnly) by its
--- onlineId. Used by C2's id-based resolution on the server side: client
--- sends the zombie's onlineId captured pre-release, server finds the
--- still-extant wrapper without relying on live grapple state. Scans the
--- entire cell zombie list — cheap compared to per-tick cost of the live
--- fallback it replaces.
local function findGrappleZombieByOnlineId(onlineId)
    if not onlineId or not getCell then return nil end
    local cell = getCell()
    local list = cell and cell.getZombieList and cell:getZombieList()
    if not list then return nil end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and z.getOnlineID and z:getOnlineID() == onlineId
            and z.isReanimatedForGrappleOnly
            and z:isReanimatedForGrappleOnly() then
            return z
        end
    end
    return nil
end

--- Plausibility check: the resolved body/zombie's current square must be
--- within MAX tiles of the player's square. Cheap cheat-guard against a
--- spoofed client command that names a body the player was never near.
local function bodyCloseToPlayer(body, player, maxTiles)
    if not body or not player then return false end
    local bsq = body.getCurrentSquare and body:getCurrentSquare()
        or (body.getSquare and body:getSquare())
    local psq = player.getCurrentSquare and player:getCurrentSquare()
    if not bsq or not psq then return false end
    local dx = math.abs((bsq.getX and bsq:getX() or 0) - (psq.getX and psq:getX() or 0))
    local dy = math.abs((bsq.getY and bsq:getY() or 0) - (psq.getY and psq:getY() or 0))
    return dx <= maxTiles and dy <= maxTiles
end
local CORPSE_LOAD_MAX_DISTANCE = 10

---@param player IsoPlayer
---@param args table
---   cartId:    cart item id (required)
---   ghostId:   onlineId (zombie kind) or ObjectID (body kind)
---   ghostKind: "zombie" or "body"
---   ghostX/Y/Z: tile coords captured client-side at :start
function CorpseStorage.handleLoadCorpseToCart(player, args)
    if not player or not args or not args.cartId then
        SaucedCarts.debug("loadCorpseToCart: invalid args")
        return false
    end
    if not CorpseStorage.isEnabled() then
        SaucedCarts.debug("loadCorpseToCart: feature disabled via sandbox")
        return false
    end

    local pid = player.getOnlineID and player:getOnlineID() or 0
    if inFlight[pid] then
        SaucedCarts.debug("loadCorpseToCart: in-flight guard tripped, dropping duplicate")
        return false
    end
    inFlight[pid] = true

    local ok, result = pcall(function()
        -- NOTE (C2, 2026-04-24): we used to short-circuit here on
        -- `not player:isDraggingCorpse()`. That raced with grapple-state
        -- replication in MP — client :start releases grapple locally
        -- (for the snappy animation), so by the time the network command
        -- arrives on the server, server's replicated state may have
        -- caught up to false → silent load failure. The check is gone;
        -- resolution below uses client-supplied ids and a plausibility
        -- distance check instead.

        local cart = findCartNearPlayer(player, args.cartId)
        if not cart then
            SaucedCarts.debug(function()
                return "loadCorpseToCart: cart " .. tostring(args.cartId) .. " not found near player"
            end)
            CorpseStorage._notifyLoadFailure(player, "no_cart")
            return false
        end

        local cartContainer = cart.getItemContainer and cart:getItemContainer()
        if not cartContainer then
            SaucedCarts.debug("loadCorpseToCart: cart has no container")
            CorpseStorage._notifyLoadFailure(player, "fallback")
            return false
        end

        -- Pre-gate BEFORE any mutation. Matters most on the grapple path
        -- (resolveDeadBody mutates the grapple wrapper) but it's cheap and
        -- a nice symmetry for the direct path too.
        local gateWeight = 20.0
        if IsoGameCharacter and IsoGameCharacter.getWeightAsCorpse then
            local okW, w = pcall(function() return IsoGameCharacter.getWeightAsCorpse() end)
            if okW and type(w) == "number" then gateWeight = w end
        end
        local gateOk, reason = CorpseStorage.canLoadCorpseIntoCart(cart, gateWeight)
        if not gateOk then
            -- Race window: cart was full by the time the server-side handler
            -- ran (another player loaded simultaneously, contents shifted via
            -- transfer between client gate-check and our handler, etc.).
            -- Notify the originating client so the user sees a halo instead
            -- of a silent action-fizzle.
            SaucedCarts.debug(function() return
                "loadCorpseToCart: gate rejected (" .. tostring(reason) .. ")" end)
            CorpseStorage._notifyLoadFailure(player, reason)
            return false
        end

        -- Resolution by client-supplied id + kind (C2 refactor, 2026-04-24):
        -- client captured these in :start BEFORE releasing its local grapple,
        -- so they're authoritative regardless of server-side grapple
        -- replication timing.
        local ghostBodyId = args.ghostId
        if args.ghostKind ~= nil
            and args.ghostKind ~= "zombie"
            and args.ghostKind ~= "body" then
            SaucedCarts.log(function()
                return "loadCorpseToCart: unexpected ghostKind='" ..
                    tostring(args.ghostKind) .. "' — normalizing to 'body'"
            end)
        end
        local ghostKind = (args.ghostKind == "zombie") and "zombie" or "body"
        local ghostX, ghostY, ghostZ = args.ghostX, args.ghostY, args.ghostZ
        local deadBody

        if ghostKind == "zombie" then
            -- Client captured the grapple-wrapper zombie's onlineId.
            -- Look it up directly — doesn't depend on live grapple state.
            local zombie = findGrappleZombieByOnlineId(tonumber(ghostBodyId))
            if not zombie then
                SaucedCarts.debug(function()
                    return "loadCorpseToCart: no grapple-zombie with onlineId=" ..
                        tostring(ghostBodyId) .. " in cell"
                end)
                return false
            end
            if not bodyCloseToPlayer(zombie, player, CORPSE_LOAD_MAX_DISTANCE) then
                SaucedCarts.log(function()
                    return "loadCorpseToCart: grapple-zombie too far from player "
                        .. "(cheat-guard) — bodyId=" .. tostring(ghostBodyId)
                end)
                return false
            end
            -- Release grapple BEFORE killing the wrapper. In SP the grapple
            -- state machine + the just-killed zombie share a VM; if we
            -- becomeCorpseSilently first, the player's grappleable holds a
            -- dangling pointer and setDoGrappleLetGo fails to unwind the
            -- drag-corpse movement state → player can spin/push but not
            -- walk. Letting go while the wrapper is still alive lets vanilla
            -- clean up properly, then we kill it for the corpse spawn.
            releaseGrapple(player)
            if zombie.becomeCorpseSilently then
                local okB, body = pcall(function() return zombie:becomeCorpseSilently() end)
                deadBody = okB and body or nil
            end
        else
            -- ghostKind == "body": the grappled target was already a
            -- dead body (rare — would have been reanimated otherwise).
            deadBody = findBodyAtSquare(ghostX, ghostY, ghostZ, tonumber(ghostBodyId))
            if deadBody and not bodyCloseToPlayer(deadBody, player, CORPSE_LOAD_MAX_DISTANCE) then
                SaucedCarts.log(function()
                    return "loadCorpseToCart: grapple-body too far from player "
                        .. "(cheat-guard) — bodyId=" .. tostring(ghostBodyId)
                end)
                return false
            end
            -- Same rationale as the zombie branch: release grapple while
            -- the body reference is still live, before invalidate/remove
            -- runs below.
            releaseGrapple(player)
        end

        if not deadBody then
            SaucedCarts.debug(function()
                return "loadCorpseToCart: resolution failed " ..
                    "(kind=" .. tostring(ghostKind) .. " id=" .. tostring(ghostBodyId) .. ")"
            end)
            return false
        end

        local corpseItem = deadBody.getItem and deadBody:getItem()
        if not corpseItem then
            SaucedCarts.debug("loadCorpseToCart: deadBody:getItem() returned nil")
            return false
        end

        local weight = corpseItem.getActualWeight and corpseItem:getActualWeight() or gateWeight

        cartContainer:AddItem(corpseItem)
        -- Stamp body's deathTime onto the new item BEFORE any other handler
        -- (network broadcast, removeCorpse, invalidate) can touch it. The
        -- restore on unload uses this to resume vanilla's rot ticker at the
        -- correct stage; without it, stored corpses freeze in time.
        CorpseStorage.stampDeathTime(corpseItem, deadBody)
        if sendAddItemToContainer then
            sendAddItemToContainer(cartContainer, corpseItem)
        end
        -- Mark cart dirty so the inventory panel repaints. Same fix as
        -- the transfer-path setDrawDirty bug: without this, the corpse
        -- item is server-authoritatively in the cart but the player's
        -- UI doesn't refresh until they close/reopen the panel.
        if cartContainer.setDrawDirty then cartContainer:setDrawDirty(true) end

        -- H1 reconcile: cart's corpse count just went up. Register the
        -- new count at the cart's current tile (player sq if equipped,
        -- cart world item sq if grounded).
        CorpseStorage.reconcile(cart, CorpseStorage.cartTargetSquare(cart, player))

        local sq = deadBody.getSquare and deadBody:getSquare()
        if sq and sq.removeCorpse then
            pcall(function() sq:removeCorpse(deadBody, false) end)
        end
        if deadBody.invalidateCorpse then
            pcall(function() deadBody:invalidateCorpse() end)
        end

        -- Purge the client-side ghost. Vanilla's reanimate() teardown
        -- doesn't send RemoveCorpseFromMap, so clients keep the original
        -- body in their local world forever — it renders as a flat corpse
        -- at the pickup location. Broadcast the id + coords so every
        -- client can jump directly to the square without scanning.
        if ghostBodyId and SaucedCarts.Network and SaucedCarts.Network.broadcast then
            SaucedCarts.Network.broadcast("removeGhostCorpse", {
                bodyId = ghostBodyId,
                kind   = ghostKind,
                x = ghostX, y = ghostY, z = ghostZ,
            })
        end

        SaucedCarts.log(function()
            return "loadCorpseToCart: loaded corpse into cart " ..
                tostring(cart:getID()) .. " (weight=" .. tostring(weight) ..
                "kg, ghostId=" .. tostring(ghostBodyId) ..
                " kind=" .. tostring(ghostKind) ..
                " coords=" .. tostring(ghostX) .. "," .. tostring(ghostY) .. "," .. tostring(ghostZ) .. ")"
        end)
        return true
    end)

    inFlight[pid] = nil

    if not ok then
        SaucedCarts.error("loadCorpseToCart: handler error: " .. tostring(result))
        return false
    end
    return result
end

-- Registration. Network module is shared — on SP/client side this is a
-- no-op dispatcher (the handler only fires on server via OnClientCommand).
SaucedCarts.Network.registerServerHandler("loadCorpseToCart", CorpseStorage.handleLoadCorpseToCart)

-- ============================================================================
-- CLIENT-SIDE GHOST CLEANUP
-- ============================================================================
-- Vanilla bug: pickUpCorpse() -> reanimate() removes the source IsoDeadBody
-- from the server via IsoObject.removeFromWorld(), which unlike
-- IsoGridSquare.removeCorpse() does NOT broadcast RemoveCorpseFromMap.
-- Every client keeps the body in its local view forever, rendering as a
-- flat corpse decal at the pickup location. The client can still
-- right-click / loot the ghost body, but any interaction fails server-side
-- because the body is no longer in the server's ObjectIDManager.
--
-- Fix: when our load succeeds, server broadcasts the ORIGINAL bodyId
-- (parsed from the grappled zombie's tostring) and each client scans its
-- local world for that IsoDeadBody and removes it with bRemote=true (no
-- re-broadcast — we're already the chain terminator).

---@param args table { bodyId = number, x = number, y = number, z = number }
function CorpseStorage.handleRemoveGhostCorpse(args)
    SaucedCarts.log(function()
        return "removeGhostCorpse: received bodyId=" .. tostring(args and args.bodyId) ..
            " kind=" .. tostring(args and args.kind) ..
            " coords=" .. tostring(args and args.x) .. "," ..
            tostring(args and args.y) .. "," .. tostring(args and args.z)
    end)
    if not args or not args.bodyId then return end
    local targetId = tonumber(args.bodyId)
    if not targetId then return end

    -- Kind "zombie": bodyId is actually the ZOMBIE's onlineId. Match by
    -- onlineId (stable across server+client) rather than parsing the
    -- zombie's name (client-side zombie names are null — the
    -- ReanimatedCorpse_IsoDeadBody prefix is set only on server).
    if args.kind == "zombie" then
        local cell = getCell and getCell()
        local zombies = cell and cell.getZombieList and cell:getZombieList()
        if not zombies then
            SaucedCarts.log("removeGhostCorpse: zombie kind but no zombie list")
            return
        end
        for i = zombies:size() - 1, 0, -1 do
            local z = zombies:get(i)
            if z and z.getOnlineID and z:getOnlineID() == targetId then
                pcall(function() z:removeFromWorld() end)
                pcall(function() z:removeFromSquare() end)
                pcall(function() cell:getObjectList():remove(z) end)
                pcall(function() cell:getZombieList():remove(z) end)
                SaucedCarts.log(function()
                    return "removeGhostCorpse: PURGED local grapple-zombie onlineId=" .. targetId
                end)
                return
            end
        end
        SaucedCarts.log(function()
            return "removeGhostCorpse: no zombie with onlineId=" .. targetId .. " in cell"
        end)
        return
    end

    -- Default / kind "body": look up the IsoDeadBody by square + id.
    if not (args.x and args.y and args.z and getCell) then
        SaucedCarts.log("removeGhostCorpse: missing coords, cannot locate body")
        return
    end
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if not sq or not sq.getDeadBodys then
        SaucedCarts.log(function()
            return "removeGhostCorpse: no square at " .. args.x .. "," .. args.y .. "," .. args.z
        end)
        return
    end
    local bodies = sq:getDeadBodys()
    if not bodies then return end
    for i = bodies:size() - 1, 0, -1 do
        local b = bodies:get(i)
        if b and b.getID and b:getID() == targetId then
            pcall(function() sq:removeCorpse(b, true) end)
            SaucedCarts.log(function()
                return "removeGhostCorpse: PURGED local body " .. tostring(targetId) ..
                    " at " .. args.x .. "," .. args.y
            end)
            return
        end
    end
    SaucedCarts.log(function()
        return "removeGhostCorpse: body id " .. targetId ..
            " NOT FOUND in square (" .. bodies:size() .. " bodies present)"
    end)
end

SaucedCarts.Network.registerClientHandler("removeGhostCorpse", CorpseStorage.handleRemoveGhostCorpse)

-- ============================================================================
-- CLIENT-SIDE LOAD-FAILURE HALO
-- ============================================================================
-- The click-time gates in ContextMenu / Hotkeys halo immediately when the
-- gate fails locally. But there are races we can't catch client-side:
--
--   * Cart filled between click-time and `:perform()` (rare but real —
--     another action mutates the cart's contents, or another player loads
--     simultaneously on a shared grounded cart).
--   * Server's view of the cart disagrees with the client's snapshot
--     (e.g., transient state mismatch after a transfer).
--
-- Without a notification path, the action plays to completion + nothing
-- happens. User sees no feedback. Fix: server fires `loadCorpseFailed`
-- back to the originating player when the handler bails; client halos.

--- Map a gate-failure reason to a translation key. Centralized so the
--- server's `_notifyLoadFailure` and the client's halo handler agree on
--- the lookup.
local LOAD_FAIL_TEXT_KEYS = {
    ["cart full"] = "UI_SaucedCarts_LoadBlocked_cart_full",
    ["no_cart"]   = "UI_SaucedCarts_LoadNoCart",
}

--- Server-only: send a `loadCorpseFailed` to one player carrying the
--- gate-rejection reason. No-op outside the server VM.
---@param player IsoPlayer the originating client
---@param reason string|nil one of "cart full" / "no_cart" / "fallback" / etc.
function CorpseStorage._notifyLoadFailure(player, reason)
    if not isServer() then return end
    if not player or not SaucedCarts.Network or not SaucedCarts.Network.sendToClient then
        return
    end
    SaucedCarts.Network.sendToClient(player, "loadCorpseFailed", { reason = reason })
end

--- Client handler — fires HaloTextHelper with the right text on receipt.
function CorpseStorage.handleLoadCorpseFailed(args)
    if not HaloTextHelper or not getPlayer then return end
    local p = getPlayer()
    if not p then return end
    local reason = args and args.reason
    local key = LOAD_FAIL_TEXT_KEYS[reason] or "UI_SaucedCarts_LoadBlocked_fallback"
    pcall(function() HaloTextHelper.addBadText(p, getText(key)) end)
end

SaucedCarts.Network.registerClientHandler("loadCorpseFailed", CorpseStorage.handleLoadCorpseFailed)

-- ============================================================================
-- TEST HOOKS
-- ============================================================================
-- Offline tests drive the handler directly via Network._invokeServerHandler,
-- but also need the lookup helper and in-flight guard table for harness
-- setup / teardown.
CorpseStorage._findCartNearPlayer = findCartNearPlayer
CorpseStorage._resolveDeadBody    = resolveDeadBody
CorpseStorage._inFlight           = inFlight

SaucedCarts.CorpseStorage = CorpseStorage

-- ============================================================================
-- CLIENT-SIDE FIRST-USE PRE-WARM
-- ============================================================================
-- The first IsoDeadBody materialization in a session triggers Java-side
-- cold init: DeadBodyAtlas texture allocation, HumanVisual pipeline,
-- shader load, ragdoll bone pool init. Observed ~1.5-2s main-thread
-- pause on first cart unload.
--
-- Pre-materialize a throwaway corpse at player-spawn time so the init
-- cost is paid during the existing loading screen. Server-side rendering
-- doesn't apply, so this is client-only. bRemote=true on removeFromWorld
-- suppresses any stray RemoveCorpseFromMap broadcast.

local preWarmed = false
local function prewarmCorpseDeserialization()
    if preWarmed then return end
    if not CorpseStorage.isEnabled() then return end

    if not (InventoryItemFactory and getPlayer and getCell) then return end
    local player = getPlayer()
    if not player then return end
    local sq = player.getCurrentSquare and player:getCurrentSquare()
    if not sq then return end

    preWarmed = true  -- flip only after prerequisites are ready

    local ok, err = pcall(function()
        local item = InventoryItemFactory.CreateItem("Base.CorpseMale")
        if not item or not item.loadCorpseFromByteData then return end

        -- byteData is nil on a fresh item → loadCorpseFromByteData falls
        -- back to createAndStoreDefaultDeadBody. That path runs
        --     new IsoZombie(currentCell) + dressInRandomOutfit +
        --     new IsoDeadBody(zombie, true, square != null)
        --
        -- M2 attempted to pass nil sq to skip staticMovingObjects entry +
        -- avoid the 1-frame flicker. EMPIRICALLY (user-reported 2026-04-24)
        -- that didn't warm the deserialization path: the cold init that
        -- causes the freeze includes lazy GL atlas allocation triggered
        -- on FIRST RENDER, not on construction. Pass real sq so the body
        -- actually renders for one frame; immediately remove it. Trade
        -- a 1-frame flicker at game-load (when user is barely paying
        -- attention) against a 1.5-2s freeze on first user action.
        local body = item:loadCorpseFromByteData(sq)
        if not body then return end

        if sq.removeCorpse then
            sq:removeCorpse(body, true)  -- bRemote=true: no broadcast
        else
            if body.removeFromWorld  then body:removeFromWorld()  end
            if body.removeFromSquare then body:removeFromSquare() end
        end
        if body.invalidateCorpse then body:invalidateCorpse() end
    end)
    if ok then
        SaucedCarts.log("CorpseStorage: pre-warmed deserialization path")
    else
        SaucedCarts.debug(function()
            return "CorpseStorage: prewarm failed (non-critical): " .. tostring(err)
        end)
    end
end

if not isServer() then  -- SP + MP client
    -- OnCreatePlayer fires before the player is placed on a square in MP;
    -- prewarm's guards would bail. Run on OnPlayerUpdate and self-unregister
    -- once the prewarm succeeds (preWarmed flag). Cheap per-tick check.
    if Events and Events.OnPlayerUpdate and Events.OnPlayerUpdate.Add then
        local onTick
        onTick = function()
            if preWarmed then
                Events.OnPlayerUpdate.Remove(onTick)
                return
            end
            prewarmCorpseDeserialization()
        end
        Events.OnPlayerUpdate.Add(onTick)
    end
end

-- ============================================================================
-- H1: PER-CART CORPSE-COUNT RECONCILE (foundation for MP stink)
-- ============================================================================
-- Tracks how many corpses each cart contributes to vanilla's per-chunk
-- CorpseCount registry and at which tile. Single source of truth lives in
-- the cart's InventoryItem modData:
--
--     SaucedCarts_corpseRegSq    = {x=int, y=int, z=int}  (nil if unreg'd)
--     SaucedCarts_corpseRegCount = int                    (0 if unreg'd)
--
-- The ONLY mutation point is CorpseStorage.reconcile(cart, targetSq):
--   - snapshot current cart's corpse-item count
--   - if targetSq == lastSq: apply delta (currentCount - lastCount)
--   - else: full swap (decrement N at lastSq, increment N at targetSq)
--   - persist new (targetSq, currentCount) to modData
-- Idempotent: reconcile(cart, sq) called twice with no other mutation = net 0.
--
-- CLIENT-LOCAL SEMANTICS: CorpseCount chunk data is per-VM. This reconcile
-- only touches the local client's CorpseCount. Each client independently
-- tracks the carts it has interacted with. The future MP-stink feature
-- broadcasts a server-authoritative "this cart now contributes N stink at
-- (x,y,z)" to all clients; cross-client gameplay logic (sickness threshold,
-- flies sound radius) MUST consume the broadcast-aggregated value, NOT the
-- per-client CorpseCount directly.
--
-- TOCTOU safety: `countCorpseItemsIn` iterates the container's items by
-- index inside pcall. If Java internals mutate mid-iteration, we absorb
-- the error and skip the reconcile rather than crashing.
--
-- DURABILITY: chunk CorpseCount data resets when the chunk unloads.
-- OnLoadGridsquare listener re-reconciles any loaded grounded cart on the
-- square, restoring our contribution.

-- Sentinel for the "cart was never registered" state; keep bookeeping simple.
local RECONCILE_MOD_KEY_SQ     = "SaucedCarts_corpseRegSq"
local RECONCILE_MOD_KEY_COUNT  = "SaucedCarts_corpseRegCount"

--- TOCTOU-safe count of corpse items in a container. Iterates by index
--- inside pcall — Java-internal mutation during the iteration produces an
--- error we swallow (returning the partial count is acceptable; the next
--- reconcile will self-correct).
---@param container ItemContainer
---@return number
local function countCorpseItemsIn(container)
    if not container or not container.getItems then return 0 end
    local count = 0
    local ok = pcall(function()
        local items = container:getItems()
        if not items then return end
        local n = items.size and items:size() or 0
        for i = 0, n - 1 do
            local it = items:get(i)
            if it and CorpseStorage.isCorpseItem(it) then
                count = count + 1
            end
        end
    end)
    if not ok then
        SaucedCarts.debug("reconcile/countCorpseItemsIn: iteration threw; returning partial")
    end
    return count
end

--- Compare two tile descriptors (tables with x/y/z). Treat nil as no-tile.
local function tilesEqual(a, b)
    if not a or not b then return false end
    return a.x == b.x and a.y == b.y and a.z == b.z
end

--- THE single mutation point for per-cart corpse-count tracking.
--- See the module header for the full contract.
---
---@param cart InventoryItem
---@param targetSq IsoGridSquare|nil where the cart currently lives (nil = unregister)
function CorpseStorage.reconcile(cart, targetSq)
    if not cart or not cart.getModData then return end
    local md = cart:getModData()
    if not md then return end

    local ok = pcall(function()
        local lastSq    = md[RECONCILE_MOD_KEY_SQ]
        local lastCount = md[RECONCILE_MOD_KEY_COUNT] or 0

        local container = cart.getItemContainer and cart:getItemContainer()
        local currentCount = countCorpseItemsIn(container)

        local targetTile = nil
        if targetSq and targetSq.getX then
            targetTile = { x = targetSq:getX(), y = targetSq:getY(), z = targetSq:getZ() }
        end

        -- Reconcile is pure modData accounting. The lastSq + lastCount
        -- tracking below survives save/load and bootstrap; future MP-stink
        -- (when CorpseCount/FliesSound get Lua-exposed by TIS or via a
        -- different sickness pathway) will read these to decide what to
        -- emit, but as of v2.1.5 nothing else consumes them.

        -- Unregister path (targetTile=nil, e.g. cart broke): clear modData
        -- count to 0 regardless of what's currently in the container. Contents
        -- may still be there (a breaking cart spills items in a separate
        -- step; the spill path registers bodies directly via addCorpse).
        -- If we kept `currentCount` here and the cart came back into play,
        -- a future reconcile(cart, sq) would double-add.
        md[RECONCILE_MOD_KEY_SQ]    = targetTile
        md[RECONCILE_MOD_KEY_COUNT] = targetTile and currentCount or 0

        SaucedCarts.debug(function()
            return string.format("reconcile: cart=%s lastSq=%s lastN=%d → targetSq=%s N=%d",
                tostring(cart.getID and cart:getID() or "?"),
                lastSq and (lastSq.x .. "," .. lastSq.y) or "nil",
                lastCount,
                targetTile and (targetTile.x .. "," .. targetTile.y) or "nil",
                currentCount)
        end)
    end)
    if not ok then
        SaucedCarts.debug("reconcile: failed (non-critical; next invocation will self-correct)")
    end
end

--- Determine the target square for a cart in its current state. Returns
--- the player's square if the cart is equipped by the player, else the
--- cart's world-item square, else nil.
---@param cart InventoryItem
---@param player IsoGameCharacter|nil
---@return IsoGridSquare|nil
function CorpseStorage.cartTargetSquare(cart, player)
    if not cart then return nil end
    -- Equipped by the given player?
    if player and player.getPrimaryHandItem then
        local prim = player:getPrimaryHandItem()
        if prim and cart.getID and prim:getID() == cart:getID() then
            return player.getCurrentSquare and player:getCurrentSquare() or nil
        end
    end
    -- On the ground as a world item?
    local worldItem = cart.getWorldItem and cart:getWorldItem()
    if worldItem and worldItem.getSquare then
        return worldItem:getSquare()
    end
    return nil
end

-- ============================================================================
-- RECONCILE EVENT WIRING (client-local)
-- ============================================================================
--
-- NOTE (stink removed, 2026-04-26): the MP-stink broadcast layer that
-- previously lived here was stripped after we discovered vanilla's
-- `CorpseCount` and `FliesSound` registries are NOT exposed to Lua
-- (LuaManager.exposeAll has neither, and CorpseCount.java carries no
-- @LuaMethod). Without engine-level exposure from TIS, no Lua-side path
-- can feed those registries — so feeding cart contributions into vanilla
-- sickness / flies-buzz is unimplementable as designed. Reconcile remains
-- as the per-cart modData state tracker (regSq, regCount).
--
-- The Sync rules engine (shared/SaucedCarts/Sync.lua) is still in the
-- codebase for future per-attribute MP sync needs (cart names, easter-egg
-- emotes, repair-status sync, etc.). Stink would need a different sickness
-- pathway entirely — likely IsoGameCharacter.setCorpseSicknessRate or
-- direct FOOD_SICKNESS stat injection on player update — to land in any
-- future version.
-- OnGameStart bootstrap: any cart the player's inventory or nearby world
-- already has at session start gets its initial reconcile (modData state
-- refresh). Discrete cart events (equip/drop/move/broke) also reconcile
-- + run the rot purge.

if not isServer() and SaucedCarts.Events then
    if SaucedCarts.Events.onCartEquip then
        SaucedCarts.Events.onCartEquip:Add(function(player, cart, source)
            if not CorpseStorage.isEnabled() then return end
            -- Purge BEFORE reconcile — purge mutates the inventory so the
            -- count seen by reconcile must reflect post-purge state.
            CorpseStorage.purgeRottedCorpses(cart)
            CorpseStorage.reconcile(cart, CorpseStorage.cartTargetSquare(cart, player))
        end)
    end
    if SaucedCarts.Events.onCartDrop then
        SaucedCarts.Events.onCartDrop:Add(function(player, cart, square)
            if not CorpseStorage.isEnabled() then return end
            CorpseStorage.purgeRottedCorpses(cart)
            CorpseStorage.reconcile(cart, square)
        end)
    end
    -- Note (2026-04-26): onCartMove (per-tile) used to fire reconcile +
    -- purge here, originally for the now-stripped stink layer's per-tile
    -- contribution tracking. Without stink there's no per-tile consumer:
    --   * reconcile's modData state has no readers in production
    --   * purgeRottedCorpses doesn't change behavior between two adjacent
    --     tiles — equip/drop already cover it, and the unload silent-drop
    --     is the actual UX gate when a corpse hits removalAt mid-trip.
    -- Removed to cut wasted per-tick work during long pushes.
    if SaucedCarts.Events.onCartBroke then
        SaucedCarts.Events.onCartBroke:Add(function(player, cart, square)
            if not CorpseStorage.isEnabled() then return end
            -- Pass nil → full decrement, clear modData. Contents that
            -- spill go through performCartTransfer's materialization
            -- branch which does its own addCorpse.
            CorpseStorage.reconcile(cart, nil)
        end)
    end
end

--- Scan player's inventory and nearby world for carts needing reconcile.
--- Used by OnGameStart bootstrap and OnLoadGridsquare chunk-reload.
---@param player IsoGameCharacter
---@param sqFilter IsoGridSquare|nil if set, restrict to carts on this exact square
local function reconcileCartsInRange(player, sqFilter)
    if not player or not CorpseStorage.isEnabled() then return end
    -- Player inventory
    local inv = player.getInventory and player:getInventory()
    if inv and inv.getItems then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it and SaucedCarts.safeIsCart(it) and not sqFilter then
                CorpseStorage.reconcile(it, CorpseStorage.cartTargetSquare(it, player))
            end
        end
    end
    -- Nearby world
    local psq = player.getCurrentSquare and player:getCurrentSquare()
    if not psq or not getCell then return end
    local baseX, baseY, baseZ = psq:getX(), psq:getY(), psq:getZ()
    for dy = -3, 3 do
        for dx = -3, 3 do
            local sq = getCell():getGridSquare(baseX + dx, baseY + dy, baseZ)
            if sq and (not sqFilter or sq == sqFilter) then
                local objs = sq:getWorldObjects()
                if objs then
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if instanceof(o, "IsoWorldInventoryObject") then
                            local it = o:getItem()
                            if it and SaucedCarts.safeIsCart(it) then
                                CorpseStorage.reconcile(it, sq)
                            end
                        end
                    end
                end
            end
        end
    end
end

if not isServer() and Events then
    if Events.OnGameStart and Events.OnGameStart.Add then
        Events.OnGameStart.Add(function()
            if not CorpseStorage.isEnabled() then return end
            -- M3 (2026-04-24): loud check that the vanilla `sendCorpse`
            -- global is exposed. Without it, MP cart→ground unload
            -- silently fails to broadcast the new IsoDeadBody to remote
            -- clients (server-only addCorpse doesn't auto-broadcast).
            -- Since this is a vanilla `@LuaMethod` (LuaManager.java:3381)
            -- it should always exist on B42; loud failure if a future
            -- vanilla rename hits us.
            if type(sendCorpse) ~= "function" then
                SaucedCarts.error(
                    "CorpseStorage: vanilla `sendCorpse` global missing — " ..
                    "MP cart unload broadcast will not work. Verify against " ..
                    "the current PZ build's LuaManager exposure.")
            end
            local player = getPlayer and getPlayer()
            if player then reconcileCartsInRange(player, nil) end
        end)
    end
    -- Chunk-reload durability: when a square loads with a grounded cart,
    -- re-register. If the chunk data WAS persisted our delta is 0 (no-op);
    -- if it wasn't, we re-add.
    if Events.OnLoadGridsquare and Events.OnLoadGridsquare.Add then
        Events.OnLoadGridsquare.Add(function(sq)
            if not sq or not CorpseStorage.isEnabled() then return end
            local player = getPlayer and getPlayer()
            if player then reconcileCartsInRange(player, sq) end
        end)
    end
end

-- Test hooks: expose internals so offline tests can exercise reconcile
-- without waiting for live events.
CorpseStorage._countCorpseItemsIn  = countCorpseItemsIn
CorpseStorage._tilesEqual          = tilesEqual
CorpseStorage._RECONCILE_MOD_KEY_SQ    = RECONCILE_MOD_KEY_SQ
CorpseStorage._RECONCILE_MOD_KEY_COUNT = RECONCILE_MOD_KEY_COUNT

SaucedCarts.debug("CorpseStorage module loaded")

return CorpseStorage
