--[[
    SaucedCarts — WorldCleanupGuard
    ===============================

    Boot-time keep-list guard against vanilla's world-item cleanup.

    Vanilla's ONLY world-item removal mechanism is a filter inside
    IsoGridSquare.load (IsoGridSquare.java:3285-3314, buildid 24574865) that
    discards matching IsoWorldInventoryObjects while a chunk deserializes,
    driven by three sandbox options:

      WorldItemRemovalList            CSV of item full types
      ItemRemovalListBlacklistToggle  false (default): the list is a
                                      REMOVE-list — only listed items are ever
                                      swept, carts can never match, we leave
                                      the list alone.
                                      true: the list becomes a KEEP-list —
                                      every item NOT listed is swept once old
                                      enough. Common anti-litter server config;
                                      eats carts with their entire cargo.
      HoursForWorldItemRemoval        age threshold in game-hours. NOTE: with
                                      the toggle on, the family-match branches
                                      of the filter bypass the `hours > 0`
                                      guard, so 0 means "sweep instantly on
                                      every chunk load", not "disabled".

    markDropPersistent (Core.lua) already exempts every cart we drop by
    setting ignoreRemoveSandbox at drop time, but that cannot protect:
      * carts saved to disk before v2.1.16 (the flag is applied at drop time
        only — nothing retro-flags an already-saved cart),
      * loot-spawned carts players load up in place without an equip+drop
        cycle (WorldSpawning deliberately leaves fresh loot sweepable).
    On keep-list servers those vanish on the next chunk reload — i.e. after a
    restart or once everyone logs out and back in ("all our carts disappeared"
    reports).

    So: when the toggle is TRUE, ensure every registered cart type is present
    in the keep-list, in memory, every boot. Two subtleties, both from reading
    the filter:
      * It also family-matches type:split("_")[0] (IsoGridSquare.java:
        3306-3309), so any cart type containing an underscore needs its
        before-the-underscore prefix listed too or the family branch still
        matches it.
      * The change is DELIBERATELY never written to disk. The server rewrites
        <server>_SandboxVars.lua from the clean loaded values at boot
        (GameServer.java:1471) BEFORE any mod event fires, so the boot cycle
        never accumulates our entries. An admin saving sandbox options from
        the in-game editor does persist them (GameServer.java:1701) — which is
        harmless: worldItemRemovalListContains (SandboxOptions.java:1314) is a
        plain string-set lookup, never validated against item scripts, so
        leftover entries are inert if the mod is ever removed.
]]

require "SaucedCarts/Core"
require "SaucedCarts/CartData"

local Guard = {}
SaucedCarts.WorldCleanupGuard = Guard

local function trim(s)
    return string.match(s, "^%s*(.-)%s*$") or s
end

--- Split a CSV into an ordered array of trimmed entries (empties dropped).
local function splitCSV(csv)
    local out = {}
    if not csv then return out end
    local pos = 1
    while true do
        local comma = string.find(csv, ",", pos, true)
        local piece
        if comma then
            piece = string.sub(csv, pos, comma - 1)
        else
            piece = string.sub(csv, pos)
        end
        piece = trim(piece)
        if piece ~= "" then table.insert(out, piece) end
        if not comma then break end
        pos = comma + 1
    end
    return out
end

--- The keep-list entries one cart type needs: the full type itself, plus —
--- when the name contains an underscore — everything before the first one,
--- because IsoGridSquare.load family-matches type:split("_")[0].
---@param fullType string
---@return string[]
function Guard.entriesForCartType(fullType)
    local entries = { fullType }
    local us = string.find(fullType, "_", 1, true)
    if us then
        table.insert(entries, string.sub(fullType, 1, us - 1))
    end
    return entries
end

--- Pure core (unit-tested): given the current CSV and the cart types, return
--- the augmented CSV plus the list of additions, or nil when every needed
--- entry is already present (idempotent). Existing entries and their order
--- are preserved; additions are appended sorted for determinism.
---@param listStr string|nil Current WorldItemRemovalList value
---@param cartTypes string[] Registered cart full types
---@return string|nil patched, string[]|nil added
function Guard.computeKeepListPatch(listStr, cartTypes)
    local existing = splitCSV(listStr)
    local present = {}
    for _, e in ipairs(existing) do present[e] = true end

    local toAdd, seen = {}, {}
    for _, cartType in ipairs(cartTypes) do
        for _, entry in ipairs(Guard.entriesForCartType(cartType)) do
            if not present[entry] and not seen[entry] then
                seen[entry] = true
                table.insert(toAdd, entry)
            end
        end
    end
    if #toAdd == 0 then return nil end
    table.sort(toAdd)

    local merged = {}
    for _, e in ipairs(existing) do table.insert(merged, e) end
    for _, e in ipairs(toAdd) do table.insert(merged, e) end
    return table.concat(merged, ","), toAdd
end

--- Apply the guard against the live sandbox options. In-memory only — takes
--- effect on the next chunk load, must re-run every boot (it does, via the
--- event wiring below). Never throws.
---@return boolean applied True when the list was changed
function Guard.apply()
    local applied = false
    local ok, err = pcall(function()
        if not getSandboxOptions then return end
        local sandbox = getSandboxOptions()
        if not sandbox or not sandbox.getOptionByName then return end

        local toggleOpt = sandbox:getOptionByName("ItemRemovalListBlacklistToggle")
        local listOpt = sandbox:getOptionByName("WorldItemRemovalList")
        if not toggleOpt or not listOpt then return end

        -- Remove-list mode (vanilla default): only listed items are swept, so
        -- carts can't match unless an admin listed them on purpose. Not ours
        -- to touch.
        if not toggleOpt:getValue() then return end

        local patched, added =
            Guard.computeKeepListPatch(listOpt:getValue(), SaucedCarts.getAllCartTypes())
        if not patched then return end

        listOpt:setValue(patched)
        applied = true
        SaucedCarts.log("WorldCleanupGuard: ItemRemovalListBlacklistToggle is on — added "
            .. table.concat(added, ", ")
            .. " to the in-memory WorldItemRemovalList keep-list so world cleanup never deletes carts")
    end)
    if not ok then
        SaucedCarts.error("WorldCleanupGuard: failed to apply keep-list guard: " .. tostring(err))
    end
    return applied
end

-- Dedicated / hosted server: sandbox options are loaded (and the file
-- re-saved from those clean values, GameServer.java:1471) long before this
-- fires, so the boot cycle never writes our append back to disk. Clients
-- inherit the patched list via the SandboxOptions packet at connect.
Events.OnServerStarted.Add(function()
    Guard.apply()
end)

-- Single-player runs the same chunk-load filter in its own VM.
Events.OnGameStart.Add(function()
    if not isClient() and not isServer() then
        Guard.apply()
    end
end)

SaucedCarts.debug("WorldCleanupGuard loaded")

return Guard
