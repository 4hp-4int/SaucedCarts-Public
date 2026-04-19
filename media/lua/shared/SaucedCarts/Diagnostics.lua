-- ============================================================================
-- SaucedCarts/Diagnostics.lua
-- ============================================================================
-- PURPOSE: Runtime diagnostic functions that need to be callable from
--          BOTH the client and the dedicated-server admin console. The
--          client-side SaucedCartsDebug.* namespace is gated
--          `if isServer() then return end` — that works for SP/client
--          commands but makes it impossible to inspect server-side
--          state when debugging MP-only bugs.
--
--          Functions here live on the SaucedCarts namespace (shared) so
--          the dedicated server's admin console can call
--          `SaucedCarts.capacityReport(getPlayerByOnlineID(N))` directly.
--
-- CONTEXT: SHARED (client + server). No UI.
-- ============================================================================

require "SaucedCarts/Core"

local function log(line) SaucedCarts.log(line) end

-- ============================================================================
-- CART LOOKUP HELPERS
-- ============================================================================

local function findNearestGroundCart(player)
    local psq = player:getCurrentSquare()
    if not psq then return nil end

    for dy = -2, 2 do
        for dx = -2, 2 do
            local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
            if sq then
                local objs = sq:getWorldObjects()
                if objs then
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if instanceof(o, "IsoWorldInventoryObject") then
                            local it = o:getItem()
                            if it and SaucedCarts.isCart(it) then
                                return it, o, sq
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function findHeldCart(player)
    local p = player:getPrimaryHandItem()
    if p and SaucedCarts.isCart(p) then return p end
    return nil
end

-- ============================================================================
-- CAPACITY REPORT
-- ============================================================================

--- Dump every capacity-related reading for the player's best-match cart.
--- Designed to isolate the MP on-ground capacity asymmetry: readings that
--- diverge between client and server point directly at the bug layer.
---
--- `mode` is "held", "ground", or nil (auto — prefer held, fall back to
--- nearest ground cart within 2 tiles).
---
--- Safe to call on dedicated server: accepts any IsoPlayer, no local-player
--- assumption. Server admins can target a specific connected player via
--- `SaucedCarts.capacityReport(getPlayerByOnlineID(N), "ground")`.
---
---@param player IsoPlayer The player whose surroundings/hand to inspect.
---@param mode string|nil "held" | "ground" | nil (auto).
function SaucedCarts.capacityReport(player, mode)
    if not player then
        SaucedCarts.error("capacityReport: no player provided")
        return
    end

    local cart, worldObj, sq
    if mode == "held" then
        cart = findHeldCart(player)
        if not cart then SaucedCarts.error("No cart in hand"); return end
    elseif mode == "ground" then
        cart, worldObj, sq = findNearestGroundCart(player)
        if not cart then SaucedCarts.error("No ground cart within 2 tiles"); return end
    else
        cart = findHeldCart(player)
        if cart then
            mode = "held"
        else
            cart, worldObj, sq = findNearestGroundCart(player)
            if not cart then
                SaucedCarts.error("No cart in hand and no ground cart within 2 tiles")
                return
            end
            mode = "ground"
        end
    end

    local c = cart:getItemContainer()
    if not c then SaucedCarts.error("Cart has no item container"); return end

    local modData = cart:getModData()
    local rawKey = SaucedCarts.CapacityOverride
        and SaucedCarts.CapacityOverride.getRawCapacityKey
        and SaucedCarts.CapacityOverride.getRawCapacityKey()
        or "SaucedCarts_rawCapacity"

    local function safe(label, fn)
        local ok, result = pcall(fn)
        if ok then
            log(string.format("  %-40s %s", label, tostring(result)))
        else
            log(string.format("  %-40s <ERROR: %s>", label, tostring(result)))
        end
    end

    log("=== SaucedCarts capacity diagnostic ===")
    log(string.format("Mode: %s  player: %s  context: isServer=%s isClient=%s",
        mode, player.getUsername and player:getUsername() or "?",
        tostring(isServer()), tostring(isClient())))
    log(string.format("Cart: %s  id=%d  weight(actual)=%.2f",
        cart:getFullType(), cart:getID(), cart:getActualWeight()))

    if sq then
        log(string.format("Square: (%d, %d, %d)  floorWeight=%.2f",
            sq:getX(), sq:getY(), sq:getZ(),
            sq.getTotalWeightOfItemsOnFloor and sq:getTotalWeightOfItemsOnFloor() or -1))
    else
        log("Square: (held — in player inventory)")
    end

    log("-- capacity readings --")
    safe("inner getCapacity (Lua)",          function() return c:getCapacity() end)
    safe("inner getEffectiveCapacity (Lua)", function() return c:getEffectiveCapacity(player) end)
    safe("outer getCapacity (Lua)",          function() return cart:getCapacity() end)
    safe("capacityWeight (current used)",    function() return c:getCapacityWeight() end)
    safe("getMaxWeight",                     function() return c:getMaxWeight() end)
    safe("getFreeCapacity",                  function() return c:getFreeCapacity(player) end)
    log("-- moddata --")
    safe("raw ModData key",                  function() return rawKey end)
    safe("raw capacity in ModData",          function() return modData[rawKey] end)
    safe("SaucedCarts_multipliersApplied",   function() return modData.SaucedCarts_multipliersApplied end)
    log("-- hasRoomFor probes --")
    safe("hasRoomFor(player, 10.0)",         function() return c:hasRoomFor(player, 10.0) end)
    safe("hasRoomFor(player, 30.0)",         function() return c:hasRoomFor(player, 30.0) end)
    safe("hasRoomFor(player, 100.0)",        function() return c:hasRoomFor(player, 100.0) end)
    log("-- runtime state --")
    safe("CapacityOverride.isInitialized",   function() return SaucedCarts.CapacityOverride.isInitialized() end)
    safe("StrictShopOnly sandbox",           function() return SandboxVars.SaucedCarts.StrictShopOnly end)
    safe("CapacityMultiplier sandbox",       function() return SandboxVars.SaucedCarts.CapacityMultiplier end)
    safe("isServer()",                       function() return isServer() end)
    safe("isClient()",                       function() return isClient() end)
    log("=======================================")
end

--- Server-console convenience: dump the capacity report for every
--- connected player's held-or-nearest cart. Iterates
--- `getOnlinePlayers()` (MP only). On SP this is a no-op.
---
--- Usage from dedicated-server admin console:
---   SaucedCarts.capacityReportAllPlayers()
function SaucedCarts.capacityReportAllPlayers()
    local players = getOnlinePlayers and getOnlinePlayers()
    if not players then
        SaucedCarts.error("capacityReportAllPlayers: getOnlinePlayers unavailable (SP?)")
        return
    end
    local n = players:size()
    if n == 0 then
        SaucedCarts.error("capacityReportAllPlayers: no players online")
        return
    end
    for i = 0, n - 1 do
        SaucedCarts.capacityReport(players:get(i))
    end
end

-- ============================================================================
-- SERVER-SIDE TRIGGER (client sends, server runs in its own Lua VM)
-- ============================================================================
-- A client-side diagnostic runs in the client's Lua VM — even when connected
-- to a dedicated server, `isServer()` is false there. To capture the server
-- process's view of the same cart, the client fires a command; the server
-- listens, finds the player, runs capacityReport in its own VM, and writes
-- the output to the server's DebugLog-server.txt.
--
-- Trigger from the client console:
--   SaucedCartsDebug.capacityReportServer()          -- server runs "ground"
--   SaucedCartsDebug.capacityReportServer("held")
--
-- Output lands in the server's log. On our docker setup that's
-- `./tools/pz-dedicated-docker/server-data/Zomboid/Logs/<date>_DebugLog-server.txt`.

local SERVER_CMD_MODULE  = "SaucedCarts"
local SERVER_CMD_COMMAND = "__capacityReport"

-- Server listener: only install in contexts where server code runs.
-- Dedicated server: isClient() == false. Self-hosted host: both are true.
if not isClient() or isServer() then
    if Events and Events.OnClientCommand and Events.OnClientCommand.Add then
        Events.OnClientCommand.Add(function(module, command, player, args)
            if module ~= SERVER_CMD_MODULE then return end
            if command ~= SERVER_CMD_COMMAND then return end
            if not player then return end

            SaucedCarts.log("--- capacityReport requested by client (server-side view) ---")
            local mode = args and args.mode
            SaucedCarts.capacityReport(player, mode)
        end)
    end
end

--- Client-side helper: fires the server trigger. Server runs the report
--- on its own state and writes it to the server's DebugLog.
---@param mode string|nil "held" | "ground" | nil
function SaucedCarts.requestServerCapacityReport(mode)
    if isServer() and not isClient() then
        SaucedCarts.error("requestServerCapacityReport: already on the server")
        return
    end
    sendClientCommand(SERVER_CMD_MODULE, SERVER_CMD_COMMAND, { mode = mode })
    SaucedCarts.log(string.format(
        "Requested server capacityReport (mode=%s). Check server DebugLog-server.txt.",
        tostring(mode or "auto")))
end

SaucedCarts.debug("Diagnostics module loaded")
