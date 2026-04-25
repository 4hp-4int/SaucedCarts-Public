-- ============================================================================
-- SaucedCarts/TimedActions/ISCartLoadCorpseAction.lua
-- ============================================================================
-- PURPOSE: Custom timed action for loading a grappled corpse into a cart.
--          The player must be actively dragging an IsoDeadBody (or a
--          ReanimatedForGrappleOnly IsoZombie produced by vanilla
--          pickUpCorpse) when this action starts.
--
--          The action releases the local grapple in :start (so the "heave"
--          anim plays during the timed action), captures the ghost
--          id+kind+coords, and sends them to the server. Server resolves
--          by id (no live isDraggingCorpse check — see C2).
--
-- WHY NOT REUSE ISDropCorpseIntoContainer:
--   Vanilla's action triggers throwGrappledIntoInventory, which kicks off
--   a Java state machine that eventually fires deadBody.addBody on the
--   server. That vanilla server handler gates on canItemFit -> Java
--   canHumanCorpseFit which uses a 19-string allowlist excluding carts.
--   The move would be silently rejected. Owning our own pipeline sidesteps
--   the allowlist and the state-machine race.
--
-- CONTEXT: SHARED.
-- ============================================================================

require "TimedActions/ISBaseTimedAction"
require "SaucedCarts/Core"
require "SaucedCarts/Network"
require "SaucedCarts/CorpseStorage"

ISCartLoadCorpseAction = ISBaseTimedAction:derive("ISCartLoadCorpseAction")
ISCartLoadCorpseAction.Type = "ISCartLoadCorpseAction"

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Capture the grappled object's identity on the client.
---
--- The "ghost" is whatever vestigial object the client holds after vanilla
--- pickUpCorpse -> reanimate() runs locally (IsoDeadBody if reanimate ran
--- server-only, IsoZombie-ReanimatedForGrappleOnly if it ran on both sides).
---
--- Returns (id, kind, x, y, z) where:
---   kind="zombie" → id is zombie's onlineId (replicated across server+client)
---   kind="body"   → id is IsoDeadBody's ObjectID
local function captureGhost(character)
    local g = character.getGrapplingTarget and character:getGrapplingTarget()
    if not g then return nil end

    if instanceof(g, "IsoZombie") and g.isReanimatedForGrappleOnly
        and g:isReanimatedForGrappleOnly() then
        local zsq = g.getCurrentSquare and g:getCurrentSquare()
        local onlineId = g.getOnlineID and g:getOnlineID()
        SaucedCarts.log(function()
            return "captureGhost: zombie kind, onlineId=" .. tostring(onlineId) ..
                " sq=" .. (zsq and (zsq:getX() .. "," .. zsq:getY() .. "," .. zsq:getZ()) or "nil")
        end)
        if zsq then
            return onlineId, "zombie", zsq:getX(), zsq:getY(), zsq:getZ()
        end
        return onlineId, "zombie"
    end

    if instanceof(g, "IsoDeadBody") then
        local bsq = g.getCurrentSquare and g:getCurrentSquare()
        local id = g.getID and g:getID()
        SaucedCarts.log(function()
            return "captureGhost: body kind, bodyId=" .. tostring(id) ..
                " sq=" .. (bsq and (bsq:getX() .. "," .. bsq:getY() .. "," .. bsq:getZ()) or "nil")
        end)
        if bsq then
            return id, "body", bsq:getX(), bsq:getY(), bsq:getZ()
        end
        return id, "body"
    end

    SaucedCarts.log(function()
        return "captureGhost: unrecognized grappled type: " .. tostring(g)
    end)
    return nil
end

--- Returns the conservative gate weight (vanilla's static
--- IsoGameCharacter.getWeightAsCorpse, ~20kg in B42). Server re-checks
--- with the item's actual weight on commit.
local function gateCorpseWeight()
    local weight = 20.0
    if IsoGameCharacter and IsoGameCharacter.getWeightAsCorpse then
        local ok, w = pcall(function() return IsoGameCharacter.getWeightAsCorpse() end)
        if ok and type(w) == "number" then weight = w end
    end
    return weight
end

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

function ISCartLoadCorpseAction:isValid()
    if not self.character or not self.cart then return false end
    if getGameSpeed and getGameSpeed() > 1 then return false end
    if not self.character:isDraggingCorpse() then return false end

    -- Weight gate — corpse weight doesn't change mid-action but the cart's
    -- fill level could (another player loading items). Re-check live.
    local ok, _ = SaucedCarts.CorpseStorage.canLoadCorpseIntoCart(self.cart, gateCorpseWeight())
    return ok and true or false
end

function ISCartLoadCorpseAction:waitToStart()
    return self.character and self.character.shouldBeTurning and self.character:shouldBeTurning() or false
end

function ISCartLoadCorpseAction:start()
    -- Allow this action to proceed while dragging a corpse — vanilla's
    -- default denies timed actions while grappling.
    if self.action and self.action.setAllowedWhileDraggingCorpses then
        self.action:setAllowedWhileDraggingCorpses(true)
    end

    -- Capture ghost info BEFORE releasing the grapple — getGrapplingTarget
    -- returns nil once setDoGrappleLetGo fires. Stash on self for :perform.
    self._ghostId, self._ghostKind, self._ghostX, self._ghostY, self._ghostZ =
        captureGhost(self.character)

    -- Release grapple immediately on the LOCAL VM only. The drag-corpse
    -- state was suppressing our Loot anim — releasing early lets the
    -- "heaving corpse into cart" motion actually play during the timed
    -- action. Server-side grapple is left engaged so the load handler at
    -- :perform can still resolve via id (see C2).
    if not isServer() and self.character.setDoGrappleLetGo then
        pcall(function() self.character:setDoGrappleLetGo() end)
    end

    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "Low")
end

function ISCartLoadCorpseAction:update()
    if self.character then
        self.character:setMetabolicTarget(Metabolics.LightDomestic)
    end
end

function ISCartLoadCorpseAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISCartLoadCorpseAction:perform()
    if self.cart and self.character then
        -- Ghost info captured in :start before grapple release. Re-capture
        -- only if :start didn't run (SP instant action shortcut).
        local ghostId   = self._ghostId
        local ghostKind = self._ghostKind
        local ghostX    = self._ghostX
        local ghostY    = self._ghostY
        local ghostZ    = self._ghostZ
        if not ghostId then
            ghostId, ghostKind, ghostX, ghostY, ghostZ = captureGhost(self.character)
        end

        local payload = {
            cartId    = self.cart:getID(),
            ghostId   = ghostId,
            ghostKind = ghostKind,
            ghostX    = ghostX,
            ghostY    = ghostY,
            ghostZ    = ghostZ,
        }

        if isClient() then
            SaucedCarts.Network.sendToServer(self.character, "loadCorpseToCart", payload)
        else
            -- SP / dedi-server path: invoke the handler directly.
            SaucedCarts.CorpseStorage.handleLoadCorpseToCart(self.character, payload)
        end
    end
    ISBaseTimedAction.perform(self)
end

function ISCartLoadCorpseAction:getDuration()
    if self.character and self.character.isTimedActionInstant
        and self.character:isTimedActionInstant() then
        return 1
    end
    return self.maxTime or 40  -- ~2s at 20tps
end

---@param character IsoPlayer
---@param cart InventoryItem
---@param time number|nil tick count override (defaults to 40 = ~2s)
function ISCartLoadCorpseAction:new(character, cart, time)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.cart      = cart
    o.maxTime   = time or 40
    o.stopOnWalk = true
    o.stopOnRun  = true
    o.forceProgressBar = true
    return o
end

return ISCartLoadCorpseAction
