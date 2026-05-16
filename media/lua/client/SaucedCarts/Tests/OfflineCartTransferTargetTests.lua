--[[
    SaucedCarts — Cart transfer targets the WRONG stacked container
    ===============================================================

    Player report (v2.1.6): two boxes stacked on one tile; transferring an
    item from the cart to the TOP box puts it in the BOTTOM box. Same class:
    fridge vs freezer on one object.

    Root cause: client classifySide serialises a "world" container as only
    (sqX,sqY,sqZ, containerType). The server resolveSide then returns the
    FIRST object on the tile whose container type matches — so two stacked
    crates (identical container type, same tile) always resolve to the first
    one. Vanilla disambiguates by (square, parent:getObjectIndex(), container
    index within the object) — see ISInventoryPage.lua:1405-1410. The cart
    path threw both indices away.

    Fix: classifySide must also emit objectIndex + containerIndex; the server
    resolves the exact object/container by those, falling back to the old
    type-match only for old in-flight clients that don't send them.

    These tests lock the client-side disambiguator. Pre-fix classifySide
    returns 6 values (no indices) → the index assertions fail.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/Core"
require "SaucedCarts/TimedActions/ISCartTransferAction"

-- A world container bound to an IsoObject that lives at a known object index
-- on its square and is the Nth container of that object (mirrors a stacked
-- crate / the freezer half of a fridge).
local function makeIndexedWorldContainer(opts)
    opts = opts or {}
    local sq = { _x = opts.x or 10, _y = opts.y or 20, _z = opts.z or 0 }
    sq.getX = function(self) return self._x end
    sq.getY = function(self) return self._y end
    sq.getZ = function(self) return self._z end

    local container = {}  -- forward ref; identity matters for index match
    local siblings = {}   -- containers on the same parent object
    for i = 1, (opts.containerIndex or 0) do
        siblings[i] = { _filler = true }
    end
    siblings[(opts.containerIndex or 0) + 1] = container

    local parent = {
        _objIndex = opts.objectIndex or 0,
        getObjectIndex = function(self) return self._objIndex end,
        getContainerCount = function(self) return #siblings end,
        getContainerByIndex = function(self, i) return siblings[i + 1] end,
    }

    container.getType = function(self) return opts.typeName or "crate" end
    container.getContainingItem = function(self) return nil end
    container.getSourceGrid = function(self) return sq end
    container.getParent = function(self) return parent end
    return container, parent, sq
end

local tests = {}

-- The core regression: a world container that is object #4's 2nd container
-- (containerIndex 1) must serialise BOTH indices so the server can pick the
-- exact one instead of first-by-type.
tests["classify_side_world_emits_object_and_container_index"] = function()
    local cont = makeIndexedWorldContainer({
        typeName = "crate", x = 11, y = 22, z = 0,
        objectIndex = 4, containerIndex = 1,
    })
    local kind, cartId, sqX, sqY, sqZ, contType, objIdx, contIdx =
        ISCartTransferAction.classifySide(cont, nil)

    if not Assert.equal(kind, "world", "kind=world") then return false end
    if not Assert.equal(contType, "crate", "containerType preserved") then return false end
    if not Assert.equal(objIdx, 4, "objectIndex serialised (parent:getObjectIndex())") then
        return false
    end
    return Assert.equal(contIdx, 1,
        "containerIndex serialised (index of this container within its object)")
end

-- Two stacked crates differ ONLY by object/container index — the data the
-- server needs to tell them apart. Both classify to the same (sq, type);
-- the indices must differ.
tests["classify_side_distinguishes_stacked_same_type_containers"] = function()
    local top = makeIndexedWorldContainer({
        typeName = "crate", x = 5, y = 5, z = 0, objectIndex = 0, containerIndex = 0,
    })
    local bottom = makeIndexedWorldContainer({
        typeName = "crate", x = 5, y = 5, z = 0, objectIndex = 1, containerIndex = 0,
    })

    local _, _, _, _, _, _, topObj = ISCartTransferAction.classifySide(top, nil)
    local _, _, tX, tY, tZ, tType = ISCartTransferAction.classifySide(top, nil)
    local _, _, _, _, _, _, botObj = ISCartTransferAction.classifySide(bottom, nil)

    if not Assert.equal(tType, "crate", "same container type") then return false end
    if not Assert.equal(tX, 5, "same tile X") then return false end
    if not Assert.notEqual(topObj, botObj,
        "stacked crates get distinct objectIndex (server can disambiguate)") then
        return false
    end
    return Assert.isTrue(topObj ~= nil and botObj ~= nil, "both indices present")
end

-- Back-compat: a world container whose parent doesn't expose object indexing
-- still classifies as "world" with valid coords/type (indices just nil →
-- server falls back to type-match).
tests["classify_side_world_without_index_api_still_valid"] = function()
    local sq = { getX = function() return 1 end, getY = function() return 2 end,
        getZ = function() return 0 end }
    local cont = {
        getType = function() return "shelves" end,
        getContainingItem = function() return nil end,
        getSourceGrid = function() return sq end,
        getParent = function() return nil end,  -- no index API
    }
    local kind, _, x, y, z, ctype, objIdx, contIdx =
        ISCartTransferAction.classifySide(cont, nil)
    if not Assert.equal(kind, "world", "still world") then return false end
    if not Assert.equal(ctype, "shelves", "type preserved") then return false end
    if not Assert.equal(x, 1, "coords preserved") then return false end
    if not Assert.isNil(objIdx, "objectIndex nil when parent has no index API") then
        return false
    end
    return Assert.isNil(contIdx, "containerIndex nil when unresolvable")
end

return tests
