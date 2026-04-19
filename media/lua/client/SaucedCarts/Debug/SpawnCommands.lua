-- ============================================================================
-- SaucedCarts/Debug/SpawnCommands.lua
-- ============================================================================
-- PURPOSE: Debug commands for cart world-spawning. Answers the peace-of-mind
--          question "why isn't a cart spawning where I expect?" by surfacing
--          the building-signature filter's verdict for the player's current
--          square and all registered spawn entries.
--
-- CONTEXT: CLIENT ONLY
--
-- USAGE (in Lua console, admin / debug mode):
--   SaucedCartsDebug.spawnEligibility()
--     > Square (9234, 10567, 0): room="parkinglot", outdoor
--     > Registered entries targeting this room:
--     >   SaucedCarts.ShoppingCart: DENIED (outdoor_denied)
--     >   YourMod.MiniCart:         ALLOWED (outdoor_allowed) [allowOutdoor=true]
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"
require "SaucedCarts/SpawnLocations"

local SpawnCommands = {}

local function log(line) SaucedCarts.log(line) end

--- Report spawn eligibility for the player's current square against every
--- registered spawn entry matching the current room name. Useful when
--- debugging "why is/isn't a cart spawning here?" — shows which filter
--- layer made the call for each registered entry.
function SpawnCommands.spawnEligibility()
    local player = getSpecificPlayer(0)
    if not player then
        SaucedCarts.error("No player")
        return
    end

    local sq = player:getCurrentSquare()
    if not sq then
        SaucedCarts.error("No square")
        return
    end

    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local room = sq:getRoom()
    local roomName = room and room:getName() or nil
    local building = sq:getBuilding()

    log("=== SaucedCarts spawn eligibility ===")
    log(string.format("Square: (%d, %d, %d)", x, y, z))
    log("Room:     " .. tostring(roomName or "(outdoor)"))

    if building then
        local def = building:getDef()
        if def then
            log(string.format(
                "Building: %d,%d  isResidential=%s  isShop=%s",
                def:getX(), def:getY(),
                tostring(def:isResidential()),
                tostring(def:isShop())
            ))
        else
            log("Building: (present, but no def)")
        end
    else
        log("Building: none (outdoor square)")
    end

    if SandboxVars.SaucedCarts then
        log("StrictShopOnly sandbox: " ..
            tostring(SandboxVars.SaucedCarts.StrictShopOnly == true))
    end

    if not roomName then
        log("No room at this square -> no spawn entries to evaluate.")
        log("=====================================")
        return
    end

    local entries = SaucedCarts.getSpawnEntriesForRoom(roomName)
    if not entries or #entries == 0 then
        log(string.format("No registered entries target room '%s'.", roomName))
        log("=====================================")
        return
    end

    log(string.format("Registered entries targeting '%s':", roomName))
    for _, entry in ipairs(entries) do
        local e = SaucedCarts.evaluateSpawnEligibility(building, entry)
        local verdict = e.allowed and "ALLOWED" or "DENIED"
        local flagNotes = {}
        if entry.allowResidential     then table.insert(flagNotes, "allowResidential") end
        if entry.allowOutdoor         then table.insert(flagNotes, "allowOutdoor") end
        if entry.skipFrameworkFilters then table.insert(flagNotes, "skipFrameworkFilters") end
        local flagSuffix = ""
        if #flagNotes > 0 then
            flagSuffix = " [" .. table.concat(flagNotes, ", ") .. "]"
        end
        log(string.format("  %-40s %s (%s)  chance=%d%%%s",
            entry.type, verdict, e.reason, entry.chance, flagSuffix))
    end
    log("=====================================")
end

--- List every room currently registered with a cart spawn entry (from
--- SaucedCarts default + any addon that called registerCart). Flags rooms
--- that PZ doesn't recognise (not in Distributions.lua) as "phantom" so
--- addon authors can spot registrations that will never fire.
function SpawnCommands.listSpawnRooms()
    local names = SaucedCarts.getSpawnRoomNames()
    log("=== SaucedCarts registered spawn rooms ===")
    if #names == 0 then
        log("  (none)")
        log("==========================================")
        return
    end

    for _, roomName in ipairs(names) do
        local entries = SaucedCarts.getSpawnEntriesForRoom(roomName) or {}
        local isVanilla = SaucedCarts.isVanillaRoom(roomName)
        local tag = isVanilla and "" or "  [PHANTOM — not in vanilla Distributions.lua]"
        log(string.format("  %s (%d cart type%s)%s",
            roomName, #entries, #entries == 1 and "" or "s", tag))
        for _, entry in ipairs(entries) do
            local flags = {}
            if entry.allowResidential     then table.insert(flags, "allowResidential") end
            if entry.allowOutdoor         then table.insert(flags, "allowOutdoor") end
            if entry.skipFrameworkFilters then table.insert(flags, "skipFrameworkFilters") end
            local flagSuffix = ""
            if #flags > 0 then flagSuffix = "  [" .. table.concat(flags, ", ") .. "]" end
            log(string.format("    - %s  chance=%d%%%s",
                entry.type, entry.chance, flagSuffix))
        end
    end

    local phantom = SaucedCarts.getPhantomSpawnRooms()
    if #phantom > 0 then
        log(string.format("Warning: %d phantom room(s) registered — these never match vanilla PZ maps:",
            #phantom))
        for _, name in ipairs(phantom) do
            log("  - " .. name)
        end
    end
    log("==========================================")
end

return SpawnCommands
