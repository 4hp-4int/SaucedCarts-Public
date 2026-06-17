--[[
    SaucedCarts/Tests/OfflineCartDropSquareTests.lua
    ================================================

    Locks SaucedCarts.resolveCartDropSquare — the stairs/no-floor redirect that
    stops a dropped cart from falling to the floor below.

    Rules under test:
      * a safe square (solid floor, not stairs) returns itself, untouched
      * a stairs square redirects to the nearest adjacent solid-floor landing
        at the SAME level (cardinals tried before diagonals)
      * an indoor no-solid-floor square (hole/ledge) also redirects
      * an OUTDOOR no-solid-floor square (natural ground) does NOT redirect —
        no false positive
      * if no safe neighbour exists, it falls back to the original square
        (preserves prior behaviour rather than blocking the drop)
      * nil square -> nil
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"

-- IsoDirections isn't defined in the offline env — provide the 8 keys the
-- helper iterates (values are opaque tokens used only as table keys).
IsoDirections = IsoDirections or {
    N = "N", E = "E", S = "S", W = "W",
    NE = "NE", SE = "SE", SW = "SW", NW = "NW",
}

--- Minimal IsoGridSquare mock exposing exactly the methods resolveCartDropSquare
--- calls. opts: stairs, building, solidFloor(default true), free(default true),
--- z(default 0), neighbors(map IsoDirections.* -> square).
local function mkSquare(opts)
    opts = opts or {}
    local sq = { _tag = opts.tag }
    sq.HasStairs        = function(self) return opts.stairs == true end
    sq.getBuilding      = function(self) return opts.building and {} or nil end
    sq.isSolidFloor     = function(self) return opts.solidFloor ~= false end
    sq.isFree           = function(self, _) return opts.free ~= false end
    sq.getZ             = function(self) return opts.z or 0 end
    sq.getAdjacentSquare = function(self, dir) return (opts.neighbors or {})[dir] end
    return sq
end

local resolve = SaucedCarts.resolveCartDropSquare

local tests = {}

tests["nil_square_returns_nil"] = function()
    return Assert.isTrue(resolve(nil) == nil, "nil -> nil")
end

tests["safe_square_returns_itself"] = function()
    local sq = mkSquare({ tag = "floor" })
    return Assert.isTrue(resolve(sq) == sq, "solid non-stairs square is returned untouched")
end

tests["stairs_redirects_to_cardinal_landing"] = function()
    local landing = mkSquare({ tag = "landing" })
    local stairs = mkSquare({ stairs = true, building = true,
        neighbors = { [IsoDirections.N] = landing } })
    return Assert.isTrue(resolve(stairs) == landing, "stairs -> adjacent solid landing")
end

tests["cardinals_skipped_for_valid_diagonal"] = function()
    -- All cardinals are stairs/invalid; only the NE diagonal is a valid landing.
    local badStairs = mkSquare({ stairs = true })
    local notSolid  = mkSquare({ solidFloor = false })
    local landing   = mkSquare({ tag = "diag" })
    local stairs = mkSquare({ stairs = true, building = true, neighbors = {
        [IsoDirections.N] = badStairs, [IsoDirections.E] = notSolid,
        [IsoDirections.S] = badStairs, [IsoDirections.W] = notSolid,
        [IsoDirections.NE] = landing,
    } })
    return Assert.isTrue(resolve(stairs) == landing, "falls through to a valid diagonal landing")
end

tests["different_level_neighbour_rejected"] = function()
    -- A neighbour one level down is not a same-level landing -> skip, fall back.
    local below = mkSquare({ tag = "below", z = -1 })
    local stairs = mkSquare({ stairs = true, building = true, z = 0,
        neighbors = { [IsoDirections.N] = below } })
    return Assert.isTrue(resolve(stairs) == stairs, "lower-level neighbour ignored; falls back to self")
end

tests["indoor_no_floor_redirects"] = function()
    -- Indoors with no solid floor = hole/ledge over a lower level.
    local landing = mkSquare({ tag = "landing" })
    local hole = mkSquare({ building = true, solidFloor = false,
        neighbors = { [IsoDirections.E] = landing } })
    return Assert.isTrue(resolve(hole) == landing, "indoor no-floor square redirects")
end

tests["outdoor_no_floor_not_redirected"] = function()
    -- Outdoors (no building) with no solid floor is natural ground — fine.
    local landing = mkSquare({ tag = "landing" })
    local ground = mkSquare({ building = false, solidFloor = false,
        neighbors = { [IsoDirections.E] = landing } })
    return Assert.isTrue(resolve(ground) == ground, "outdoor ground is NOT a false positive")
end

tests["stairs_no_valid_neighbour_falls_back"] = function()
    local stairs = mkSquare({ stairs = true, building = true, neighbors = {} })
    return Assert.isTrue(resolve(stairs) == stairs, "no landing -> fall back to original (no regression)")
end

return tests
