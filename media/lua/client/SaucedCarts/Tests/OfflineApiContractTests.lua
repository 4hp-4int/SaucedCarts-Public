--[[
    SaucedCarts — Vanilla API contract tests
    ========================================

    Locks the API surface of ISCartTransferAction against vanilla's
    ISInventoryTransferAction.

    WHY: our CartTransferInterceptor wraps `ISInventoryTransferAction.new`
    and substitutes `ISCartTransferAction` whenever a transfer touches a
    cart's inner container. Vanilla code that downstream calls methods on
    the returned action (e.g. `action:setOnComplete(...)` from crafting
    callbacks, `action:setAllowMissingItems(true)` from
    ISCraftingUI.ReturnItemToContainer) crashes with "Object tried to
    call nil" if our class doesn't expose that method.

    A 2026-04-28 user report flagged exactly this — putting charcoal in
    a cart and crafting from a furnace fired ISCraftingUI's return-leftovers
    flow which calls setAllowMissingItems on our action class. We didn't
    have that method. Crash.

    These tests guarantee:
      1. Both classes loaded — sanity.
      2. Critical-external-API methods present — catches dropped stubs.
      3. Surface audit — every vanilla method either exists on our class
         OR is in KNOWN_VANILLA_INTERNALS as an audited "self-only" call.
         New vanilla methods (e.g. from a future PZ patch) light up here.
      4. Lifecycle methods directly defined on our class — catches a
         future refactor that tries `ISInventoryTransferAction:derive`
         and silently inherits vanilla's transaction-driven flow.
      5. Behavioral checks for setOnComplete + setAllowMissingItems.
      6. Third-party-external-API methods present + behavioral check.
         Mods like Inventory Tetris patch methods onto vanilla's class at
         boot and call them on whatever :new returns — including our
         substituted action. A 2026-08-04 report: dragging an item into
         an open cart panel with Tetris installed crashed at
         ItemGridUI_events.lua:414 calling setTetrisTarget on our action.
         The kit never loads Workshop mods, so these entries are pinned
         by hand from the third-party source (file:line in each entry);
         the runtime twin is CartTransferInterceptor's boot-time surface
         audit, which logs any foreign method we haven't shimmed.

    DESIGN NOTE — why we DON'T derive from ISInventoryTransferAction:
    Two reasons. (1) Boot order: our action file loads during preload
    (Core → CartTransferInterceptor → here) which happens BEFORE
    vanilla_requires fires in the offline test env. Vanilla isn't in
    scope at derive time. (2) 42.17 added createItemTransaction in
    vanilla's :start, isItemTransactionDone polling in :update, queue
    iteration in :perform — none of which our pipeline supports. Even
    if we got the boot order right, we'd have to override every life-
    cycle method anyway, and a future vanilla addition we forgot to
    override would silently route through their transaction system.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "SaucedCarts/CartTransferInterceptor"
require "SaucedCarts/TimedActions/ISCartTransferAction"

-- ============================================================================
-- Methods on vanilla ISInventoryTransferAction that are PURELY internal
-- implementation — vanilla code never calls these on action instances from
-- outside the class, only the action calls them on `self`. Our substituted
-- class doesn't need to expose them, so the contract test ignores them.
--
-- Audit anchor: when adding to this list, justify with a comment.
-- ============================================================================
local KNOWN_VANILLA_INTERNALS = {
    -- :start / :update / :stop / :perform / :isValid / :waitToStart / :new
    -- — lifecycle methods we already override and that test #4 below also
    -- enforces are directly defined on our class.
    ["start"]            = true,
    ["update"]           = true,
    ["stop"]             = true,
    ["perform"]          = true,
    ["isValid"]          = true,
    ["waitToStart"]      = true,
    ["new"]              = true,
    ["getDuration"]      = true,
    -- Self-only helpers vanilla calls inside its own :start / :perform.
    -- External code doesn't touch these.
    ["doActionAnim"]     = true,
    ["startActionAnim"]  = true,
    ["transferItem"]     = true,
    ["checkQueueList"]   = true,
    ["canMergeAction"]   = true,
    ["floorHasRoomFor"]  = true,
    ["canDropOnFloor"]   = true,
    ["getNotFullFloorSquare"] = true,
    -- Sound helpers — only vanilla's :start / :stop fire these on `self`.
    ["playSourceContainerOpenSound"]  = true,
    ["playSourceContainerCloseSound"] = true,
    ["playDestContainerOpenSound"]    = true,
    ["playDestContainerCloseSound"]   = true,
    ["stopLoopingSound"]              = true,
    ["getTransferStartSoundName"]     = true,
    ["getTransferCompleteSoundName"]  = true,
    -- playTransferCompleteSound — NEW in B42 buildid 23504596. Vanilla's
    -- :transferItem calls self:playTransferCompleteSound(item)
    -- (ISInventoryTransferAction.lua:625,685). Our action derives from
    -- ISBaseTimedAction and never runs vanilla's :transferItem on self
    -- (performCartTransfer calls ISTransferAction:transferItem directly), so
    -- vanilla never invokes this on our action. Self-only — safe to ignore.
    ["playTransferCompleteSound"]     = true,
    -- forceComplete / forceStop — only vanilla's :update fires these on
    -- `self` based on transaction state. Our action doesn't use vanilla's
    -- transaction system so we don't need to expose these.
    ["forceComplete"] = true,
    -- Logging hook — vanilla's logger calls this. We don't log via the
    -- same channel.
    ["getExtraLogData"] = true,
    -- isAlreadyTransferred — vanilla's :perform calls this on `self` only.
    ["isAlreadyTransferred"] = true,
    -- getTimeDelta — vanilla's queue uses this for time accounting; default
    -- inherited from ISBaseTimedAction.
    ["getTimeDelta"] = true,
}

-- ============================================================================
-- LIFECYCLE METHODS that MUST be directly on our class
-- ============================================================================
-- A future refactor that derives from ISInventoryTransferAction (or another
-- well-meaning rewrite) would silently inherit vanilla's lifecycle methods.
-- 42.17's vanilla :start calls createItemTransaction; :update polls
-- isItemTransactionDone; :perform iterates queueList. None of those work
-- with our network-command-driven pipeline. This test catches the regress.
local LIFECYCLE_DIRECT_OVERRIDE_REQUIRED = {
    "new", "isValid", "start", "update", "perform", "stop",
    "waitToStart", "getDuration",
}

-- ============================================================================
-- Methods that MUST be exposed because vanilla code calls them on the
-- action instance from OUTSIDE the class. Each entry points at a vanilla
-- file:line where the external call happens — so a future maintainer can
-- see why removing the stub would re-break something.
-- ============================================================================
local CRITICAL_EXTERNAL_API = {
    setOnComplete = {
        whyExposed = "ISCraftingUI.ReturnItemToContainer (line 19-20), "
            .. "ISInventoryPaneContextMenu.OnCraftComplete + map / alarm flows "
            .. "(multiple call sites in ISInventoryPaneContextMenu.lua)",
    },
    setAllowMissingItems = {
        whyExposed = "ISCraftingUI.ReturnItemToContainer (line 20). "
            .. "Crafting cleanup paths set this to keep action alive when "
            .. "ingredients were destroyed mid-recipe (e.g. molotov gas can).",
    },
}

-- ============================================================================
-- Methods THIRD-PARTY mods call on action instances from outside. Same
-- contract as CRITICAL_EXTERNAL_API, but the caller is a Workshop mod, so
-- the offline env can never discover these by introspection — each entry is
-- pinned by hand against the third-party source, with file:line receipts.
-- ============================================================================
local THIRD_PARTY_EXTERNAL_API = {
    setTetrisTarget = {
        whyExposed = "Inventory Tetris (Workshop 3397561666) adds this to "
            .. "ISInventoryTransferAction at OnGameBoot (Patches/TimedActions/"
            .. "InventoryTetris_InventoryTransferAction.lua:62) and calls it "
            .. "on the instance immediately after :new at six sites: "
            .. "ItemGridUI_events.lua:266/:414/:461, "
            .. "ItemGridStackSplitWindow.lua:110, AmmoOnMagazineHandler.lua:69, "
            .. "AttachmentOnWeaponHandler.lua:38. 2026-08-04 player report: "
            .. "drag into open cart panel crashed 'Object tried to call nil "
            .. "in handleDragAndDropTransfer'.",
    },
}

-- ============================================================================
-- TESTS
-- ============================================================================

local tests = {}

tests["vanilla_class_loaded_for_introspection"] = function()
    -- CI has no PZ install: vanilla_requires falls back to mocks and this
    -- contract is uncheckable there. It MUST still run (and fail loudly)
    -- on any machine with a real install — that's every dev machine.
    if not ISInventoryTransferAction then
        return PZTestKit.skip("requires a real PZ install "
            .. "(vanilla_requires fell back to mocks; contract "
            .. "introspection is hollow without vanilla's class)")
    end
    return Assert.notNil(ISInventoryTransferAction,
        "ISInventoryTransferAction must be loaded — check pz-test.lua "
        .. "vanilla_requires + the ISInventoryPage stub at the top of "
        .. "pz-test.lua. Without it, contract checks are hollow.")
end

tests["our_class_loaded"] = function()
    return Assert.notNil(ISCartTransferAction,
        "ISCartTransferAction must be loaded for contract checks")
end

tests["critical_external_api_methods_present"] = function()
    -- Every CRITICAL_EXTERNAL_API method must exist on our class. These
    -- are the ones whose absence directly crashes vanilla code.
    for methodName, info in pairs(CRITICAL_EXTERNAL_API) do
        if not Assert.equal(type(ISCartTransferAction[methodName]), "function",
            "ISCartTransferAction:" .. methodName ..
            " is required (called from " .. info.whyExposed .. ")") then
            return false
        end
    end
    return true
end

tests["api_surface_matches_vanilla_or_is_documented_internal"] = function()
    -- Walk every function on vanilla's class. Each one must be either:
    --   (a) present on ISCartTransferAction, OR
    --   (b) listed in KNOWN_VANILLA_INTERNALS as an audited internal.
    -- New vanilla methods (e.g. from a PZ patch) light up here.
    if not ISInventoryTransferAction then return false end

    local missing = {}
    for k, v in pairs(ISInventoryTransferAction) do
        if type(v) == "function"
           and not KNOWN_VANILLA_INTERNALS[k]
           and type(ISCartTransferAction[k]) ~= "function" then
            table.insert(missing, k)
        end
    end

    if #missing > 0 then
        local msg = "ISCartTransferAction missing vanilla method(s) — "
            .. "vanilla code may call these and crash with 'Object tried "
            .. "to call nil'. Either add a stub/impl, or — if it's purely "
            .. "internal to the action class — list it in "
            .. "KNOWN_VANILLA_INTERNALS with a comment. Methods: "
            .. table.concat(missing, ", ")
        return Assert.equal(#missing, 0, msg)
    end
    return true
end

tests["lifecycle_methods_directly_defined"] = function()
    -- These methods MUST be directly on ISCartTransferAction, not inherited.
    -- A future refactor that derives from ISInventoryTransferAction would
    -- silently inherit vanilla's transaction-driven lifecycle and break us.
    local missingOverrides = {}
    for _, methodName in ipairs(LIFECYCLE_DIRECT_OVERRIDE_REQUIRED) do
        local v = rawget(ISCartTransferAction, methodName)
        if type(v) ~= "function" then
            table.insert(missingOverrides, methodName)
        end
    end
    if #missingOverrides > 0 then
        return Assert.equal(#missingOverrides, 0,
            "ISCartTransferAction must DIRECTLY define these lifecycle "
            .. "methods (rawget — no __index walk). Missing: "
            .. table.concat(missingOverrides, ", "))
    end
    return true
end

tests["setOnComplete_stores_callback_and_args"] = function()
    local action = ISCartTransferAction:new(
        nil, nil, nil, nil, "in", nil, 1
    )
    local sentinel = function() end
    action:setOnComplete(sentinel, "a", "b", "c")
    if not Assert.equal(action.onCompleteFunc, sentinel,
        "onCompleteFunc captured") then return false end
    if not Assert.notNil(action.onCompleteArgs,
        "onCompleteArgs table created") then return false end
    return Assert.equal(action.onCompleteArgs[1], "a", "first arg captured")
end

tests["setAllowMissingItems_stores_flag"] = function()
    local action = ISCartTransferAction:new(
        nil, nil, nil, nil, "in", nil, 1
    )
    action:setAllowMissingItems(true)
    return Assert.equal(action.allowMissingItems, true,
        "allowMissingItems flag stored")
end

tests["third_party_external_api_methods_present"] = function()
    for methodName, info in pairs(THIRD_PARTY_EXTERNAL_API) do
        if not Assert.equal(type(ISCartTransferAction[methodName]), "function",
            "ISCartTransferAction:" .. methodName ..
            " is required (called from " .. info.whyExposed .. ")") then
            return false
        end
    end
    return true
end

tests["setTetrisTarget_stores_grid_fields"] = function()
    -- Field-for-field mirror of Inventory Tetris's implementation
    -- (InventoryTetris_InventoryTransferAction.lua:62-69). The fields are
    -- inert for our pipeline, but Tetris reads them back off the action
    -- (canMergeAction compares gridX/gridY/gridIndex/isRotated), so they
    -- must land verbatim, not just not-crash.
    local action = ISCartTransferAction:new(
        nil, nil, nil, nil, "in", nil, 1
    )
    action:setTetrisTarget(3, 4, 2, true, "secondary-sentinel")
    if not Assert.equal(action.gridX, 3, "gridX stored") then return false end
    if not Assert.equal(action.gridY, 4, "gridY stored") then return false end
    if not Assert.equal(action.gridIndex, 2, "gridIndex stored") then return false end
    if not Assert.equal(action.isRotated, true, "isRotated stored") then return false end
    if not Assert.equal(action.tetrisSecondary, "secondary-sentinel",
        "tetrisSecondary stored") then return false end
    return Assert.equal(action.enforceTetrisRules, true,
        "enforceTetrisRules flag set")
end

return tests
