-- ============================================================================
-- SaucedCarts/GroundVisualReconciler.lua
-- ============================================================================
-- PURPOSE: Server-side drift reconciler for GROUND cart visuals.
--
-- CONTEXT: SERVER ONLY (SP is covered by the same sweep running in the
--          single VM; MP clients receive the resulting broadcasts).
--
-- WHY: CartTransferInterceptor only sees transfers whose src/dest is a
-- cart's REAL inner container. Aggregated inventory views (CleanUI /
-- Proximity Inventory loot panels, Tetris aggregate grids) hand vanilla a
-- SYNTHETIC container as the source, so pulling items out of a ground cart
-- through one bypasses our pipeline entirely: vanilla's transaction system
-- moves the items server-side and the repaint funnel never runs (found
-- 2026-08-08: cart drained to 0.0 weight, mesh stayed on the partial
-- model). Equipped carts have had a drift reconciler since v2.1.14
-- (CartStateHandler); this is the ground-cart twin, server-authoritative.
--
-- COST: every SWEEP_TICKS ticks, scan squares in SCAN_RADIUS around each
-- online player for ground carts and run the UNFORCED differ — a no-op
-- when in sync, one updateGroundCartVisual broadcast when drifted. The
-- sweep also heals any other unknown mutation source (other mods, admin
-- commands, decay) by construction.
-- ============================================================================

require "SaucedCarts/Core"
require "SaucedCarts/CartVisuals"

local SWEEP_TICKS = 900   -- ~15s at 60 ticks/s: backstop only; the client-side
                           -- transfer nudge (CartTransferInterceptor) is the
                           -- primary, instant path for player-driven bypasses
local SCAN_RADIUS = 12

local tickCounter = 0

local function reconcileNearPlayer(player)
    if not player then return 0 end
    local psq = player:getCurrentSquare()
    if not psq then return 0 end

    local cell = getCell()
    if not cell then return 0 end

    local repainted = 0
    local px, py, pz = psq:getX(), psq:getY(), psq:getZ()
    for dy = -SCAN_RADIUS, SCAN_RADIUS do
        for dx = -SCAN_RADIUS, SCAN_RADIUS do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            if sq then
                local objs = sq:getWorldObjects()
                if objs then
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if instanceof(o, "IsoWorldInventoryObject") then
                            local it = o:getItem()
                            if it and SaucedCarts.safeIsCart(it) then
                                -- Unforced: the differ memo makes an
                                -- in-sync cart free; only drift repaints
                                -- (and broadcasts).
                                if SaucedCarts.updateCartVisual(it, player) then
                                    repainted = repainted + 1
                                    SaucedCarts.log(
                                        "GroundVisualReconciler: healed drifted ground cart "
                                        .. tostring(it:getID())
                                        .. " -> " .. tostring(it:getStaticModel()))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return repainted
end

-- Exported for tests and pz-shell probes.
SaucedCarts.reconcileGroundCartVisualsNear = reconcileNearPlayer

-- ----------------------------------------------------------------------------
-- Event-driven nudge (primary path). The client detects a vanilla transfer
-- touching a cart's REAL container (CartTransferInterceptor's transferItem
-- wrap) and sends cartVisualNudge; we recalc a few ticks later so the
-- transaction's server-side move has definitely landed first. The sweep
-- above stays as the slow backstop for mutations no client ever sees.
-- ----------------------------------------------------------------------------
local NUDGE_DELAY_TICKS = 10
local pendingNudges = {}

function SaucedCarts.queueGroundCartVisualNudge(cartId, x, y, z, player)
    for _, n in ipairs(pendingNudges) do
        if n.cartId == cartId then
            n.ticks = NUDGE_DELAY_TICKS  -- coalesce: restart the timer
            return
        end
    end
    table.insert(pendingNudges, {
        cartId = cartId, x = x, y = y, z = z,
        player = player, ticks = NUDGE_DELAY_TICKS,
    })
end

local function processNudges()
    if #pendingNudges == 0 then return end
    local i = 1
    while i <= #pendingNudges do
        local n = pendingNudges[i]
        n.ticks = n.ticks - 1
        if n.ticks <= 0 then
            table.remove(pendingNudges, i)
            pcall(function()
                local cart = SaucedCarts.Network
                    and SaucedCarts.Network.findGroundCart
                    and SaucedCarts.Network.findGroundCart(n.x, n.y, n.z, n.cartId)
                if not cart and n.player then
                    local inv = n.player:getInventory()
                    cart = inv and inv:getItemById(n.cartId)
                end
                if cart and SaucedCarts.updateCartVisual(cart, n.player) then
                    SaucedCarts.log("GroundVisualReconciler: nudge repainted cart "
                        .. tostring(n.cartId) .. " -> " .. tostring(cart:getStaticModel()))
                end
            end)
        else
            i = i + 1
        end
    end
end

local function onTick()
    processNudges()
    tickCounter = tickCounter + 1
    if tickCounter < SWEEP_TICKS then return end
    tickCounter = 0

    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if players and players.size then
        for i = 0, players:size() - 1 do
            pcall(reconcileNearPlayer, players:get(i))
        end
        return
    end

    -- SP: single local player
    local p = getSpecificPlayer and getSpecificPlayer(0) or nil
    if p then pcall(reconcileNearPlayer, p) end
end

if Events and Events.OnTick and Events.OnTick.Add then
    Events.OnTick.Add(onTick)
end
