
-- ============================================================================
-- SaucedCarts/Debug/AnimationCommands.lua
-- ============================================================================
-- PURPOSE: Debug commands for analyzing animation state while holding cart.
--
-- CONTEXT: CLIENT ONLY
-- ============================================================================

if isServer() then return {} end

require "SaucedCarts/Core"
require "SaucedCarts/Network"

local AnimationCommands = {}

--- Dump comprehensive animation state info
function AnimationCommands.dumpAnimState()
    local player = getPlayer()
    if not player then
        print("ERROR: No player found")
        return
    end

    print("========== ANIMATION STATE DUMP ==========")

    -- Basic player state
    print("\n--- PLAYER STATE ---")
    print("isMoving: " .. tostring(player:isPlayerMoving()))
    print("isSprinting: " .. tostring(player:isSprinting()))
    print("isRunning: " .. tostring(player:isRunning()))
    print("isSneaking: " .. tostring(player:isSneaking()))
    print("isAiming: " .. tostring(player:isAiming()))

    -- Key animation variables
    print("\n--- ANIMATION VARIABLES ---")
    print("Weapon: '" .. tostring(player:getVariableString("Weapon")) .. "'")
    print("RightHandMask: '" .. tostring(player:getVariableString("RightHandMask")) .. "'")
    print("LeftHandMask: '" .. tostring(player:getVariableString("LeftHandMask")) .. "'")
    print("WalkSpeed: " .. tostring(player:getVariableFloat("WalkSpeed", 0)))
    print("WalkInjury: " .. tostring(player:getVariableFloat("WalkInjury", 0)))
    print("IdleSpeed: " .. tostring(player:getVariableFloat("IdleSpeed", 0)))
    print("isMoving (var): " .. tostring(player:getVariableBoolean("isMoving")))
    print("isTurningAround: " .. tostring(player:getVariableBoolean("isTurningAround")))

    -- Animator state
    print("\n--- ANIMATOR STATE ---")
    local animator = player:getAdvancedAnimator()
    if animator then
        print("Has animator: true")

        -- GetDebug() returns full state info as string
        local debugInfo = animator:GetDebug()
        if debugInfo then
            print("Debug info:\n" .. tostring(debugInfo))
        end

        -- Get animation set name
        local animSetName = player:GetAnimSetName()
        print("AnimSet name: " .. tostring(animSetName))
    else
        print("Has animator: false")
    end

    -- Movement state
    print("\n--- MOVEMENT STATE ---")
    local moveSpeed = player:getMoveSpeed()
    print("getMoveSpeed(): " .. tostring(moveSpeed))

    local maxSpeed = player:getMaxSprintSpeed()
    print("getMaxSprintSpeed(): " .. tostring(maxSpeed))

    -- Equipped item
    print("\n--- EQUIPPED ITEM ---")
    local primary = player:getPrimaryHandItem()
    if primary then
        print("Primary hand: " .. tostring(primary:getFullType()))
        print("Is cart: " .. tostring(SaucedCarts.isCart(primary)))

        -- Check RunSpeedModifier from script
        local script = primary:getScriptItem()
        if script then
            local runSpeedMod = script:getRunSpeedModifier()
            print("RunSpeedModifier (script): " .. tostring(runSpeedMod))
        end
    else
        print("Primary hand: nil")
    end

    print("===========================================")
end

--- Continuous animation monitoring (call repeatedly or bind to key)
local monitorActive = false
local monitorTick = 0

function AnimationCommands.startAnimMonitor()
    if monitorActive then
        print("Animation monitor already running")
        return
    end

    monitorActive = true
    monitorTick = 0

    local function onTick()
        if not monitorActive then
            Events.OnTick.Remove(onTick)
            return
        end

        monitorTick = monitorTick + 1
        if monitorTick % 30 ~= 0 then return end  -- Every 0.5 sec at 60fps

        local player = getPlayer()
        if not player then return end

        local weapon = player:getVariableString("Weapon") or ""
        local walkSpeed = player:getVariableFloat("WalkSpeed", 0)
        local isMoving = player:isPlayerMoving()
        local moveSpeed = player:getMoveSpeed() or 0

        -- Note: getRootLayer/getCurrentStateName not exposed to Lua
        -- Use GetDebug() for full state info, or just print key variables
        print(string.format("[AnimMon] Weapon:'%s' WalkSpeed:%.2f Moving:%s MoveSpeed:%.2f",
            weapon, walkSpeed, tostring(isMoving), moveSpeed))
    end

    Events.OnTick.Add(onTick)
    print("Animation monitor started (updates every 0.5s)")
end

function AnimationCommands.stopAnimMonitor()
    monitorActive = false
    print("Animation monitor stopped")
end

--- List all active animation layers/nodes
function AnimationCommands.dumpAnimatorFull()
    local player = getPlayer()
    if not player then
        print("ERROR: No player found")
        return
    end

    local animator = player:getAdvancedAnimator()
    if not animator then
        print("ERROR: No animator found")
        return
    end

    print("========== FULL ANIMATOR DUMP ==========")

    -- Try GetDebug method (may not be exposed to Lua)
    local success, result = pcall(function()
        return animator:GetDebug()
    end)
    if success and result then
        print(tostring(result))
    else
        -- Fallback: dump what we can access
        print("GetDebug() not available, using fallback...")

        -- Try to get current state info
        local currentState = player:getCurrentState()
        if currentState then
            print("CurrentState: " .. tostring(currentState))
        end

        -- Dump animation variables we know about
        print("\n-- Key Animation Variables --")
        local vars = {"Weapon", "RightHandMask", "LeftHandMask", "isMoving", "isRunning",
                      "isSprinting", "Aim", "sneaking", "isAiming", "WalkSpeed", "walkinjury"}
        for _, varName in ipairs(vars) do
            local val = player:getVariableString(varName)
            if val and val ~= "" then
                print(string.format("  %s = '%s'", varName, val))
            else
                local boolVal = player:getVariableBoolean(varName)
                if boolVal ~= nil then
                    print(string.format("  %s = %s", varName, tostring(boolVal)))
                end
            end
        end

        -- Try to enumerate methods on animator for discovery
        print("\n-- Animator Methods (for discovery) --")
        local methodsToTry = {"getCurrentStateName", "getLayerCount", "getRootLayer",
                              "getDebugMonitor", "isPlaying", "getCurrentAnim"}
        for _, methodName in ipairs(methodsToTry) do
            local method = animator[methodName]
            if method then
                local ok, val = pcall(function() return method(animator) end)
                if ok then
                    print(string.format("  %s() = %s", methodName, tostring(val)))
                end
            end
        end
    end

    print("=========================================")
end

--- List all animation condition variables in the current AnimSet
function AnimationCommands.listAnimVariables()
    local player = getPlayer()
    if not player then
        print("ERROR: No player found")
        return
    end

    local animator = player:getAdvancedAnimator()
    if not animator then
        print("ERROR: No animator found")
        return
    end

    print("========== ANIMATION VARIABLES ==========")

    -- Get all condition variables used in the AnimSet
    local vars = animator:debugGetVariables()
    if vars then
        print("Variables used in AnimSet conditions:")
        local size = vars:size()
        for i = 0, size - 1 do
            local varName = vars:get(i)
            -- Try to get current value
            local strVal = player:getVariableString(varName)
            local floatVal = player:getVariableFloat(varName, 0)
            local boolVal = player:getVariableBoolean(varName)

            local valueStr = ""
            if strVal and strVal ~= "" then
                valueStr = "'" .. strVal .. "' (string)"
            elseif floatVal and floatVal ~= 0 then
                valueStr = tostring(floatVal) .. " (float)"
            elseif boolVal ~= nil then
                valueStr = tostring(boolVal) .. " (bool)"
            else
                valueStr = "(no value)"
            end

            print("  " .. varName .. " = " .. valueStr)
        end
        print("Total: " .. size .. " condition variables")
    else
        print("debugGetVariables() returned nil")
    end

    print("==========================================")
end

--- Detailed layer inspection (uses GetDebug which is exposed to Lua)
function AnimationCommands.dumpLayers()
    local player = getPlayer()
    if not player then
        print("ERROR: No player found")
        return
    end

    local animator = player:getAdvancedAnimator()
    if not animator then
        print("ERROR: No animator found")
        return
    end

    print("========== ANIMATION LAYERS ==========")
    -- Note: getRootLayer, getSubLayerCount, etc. are not exposed to Lua
    -- GetDebug() provides layer info as formatted string
    local debugInfo = animator:GetDebug()
    if debugInfo then
        print(tostring(debugInfo))
    else
        print("GetDebug() returned nil")
    end
    print("======================================")
end

--- Check if specific states are currently active
function AnimationCommands.checkCartStates()
    local player = getPlayer()
    if not player then
        print("ERROR: No player found")
        return
    end

    local animator = player:getAdvancedAnimator()
    if not animator then
        print("ERROR: No animator found")
        return
    end

    print("========== CART STATE CHECK ==========")

    -- Check for our cart states
    local cartStates = {"IdleCart", "walkCart", "runCart", "sprintCart"}
    local vanillaStates = {"Idle", "defaultWalk", "defaultRun", "defaultSprint"}

    print("Cart states:")
    for _, stateName in ipairs(cartStates) do
        local exists = animator:containsState(stateName)
        print("  " .. stateName .. ": " .. (exists and "EXISTS" or "not found"))
    end

    print("\nVanilla movement states:")
    for _, stateName in ipairs(vanillaStates) do
        local exists = animator:containsState(stateName)
        print("  " .. stateName .. ": " .. (exists and "EXISTS" or "not found"))
    end

    -- Current state info via GetDebug()
    print("\nCurrent animator state:")
    local debugInfo = animator:GetDebug()
    if debugInfo then
        -- Just print first few lines (state info)
        local lines = {}
        for line in tostring(debugInfo):gmatch("[^\n]+") do
            table.insert(lines, line)
            if #lines >= 5 then break end
        end
        for _, line in ipairs(lines) do
            print("  " .. line)
        end
    end

    -- Weapon variable (triggers cart animations)
    local weapon = player:getVariableString("Weapon")
    print("\nWeapon variable: '" .. tostring(weapon) .. "'")

    print("======================================")
end

-- =============================================================================
-- MP ANIMATION DEBUG COMMANDS
-- =============================================================================
-- These commands help diagnose animation sync issues in multiplayer.
-- They allow querying server state and comparing with local perception.

-- Track pending desync check request
local pendingDesyncCheck = false

--- Dump animation state for all remote players (local perception)
--- Shows what this client thinks remote players' animation vars are
function AnimationCommands.dumpRemotePlayerAnims()
    local localPlayer = getPlayer()
    if not localPlayer then
        print("ERROR: No local player")
        return
    end

    local onlinePlayers = getOnlinePlayers()
    if not onlinePlayers then
        print("Not in multiplayer")
        return
    end

    print("========== REMOTE PLAYER ANIMATIONS ==========")
    local localOnlineId = localPlayer:getOnlineID()
    local remoteCount = 0

    for i = 0, onlinePlayers:size() - 1 do
        local p = onlinePlayers:get(i)
        if p and p:getOnlineID() ~= localOnlineId then
            remoteCount = remoteCount + 1
            local weapon = p:getVariableString("Weapon") or ""
            local rightMask = p:getVariableString("RightHandMask") or ""
            local leftMask = p:getVariableString("LeftHandMask") or ""
            local primary = p:getPrimaryHandItem()
            local hasCart = primary and SaucedCarts.isCart(primary)

            print(string.format("[%s] onlineID=%d", p:getUsername(), p:getOnlineID()))
            print(string.format("  Weapon='%s' RightMask='%s' LeftMask='%s'", weapon, rightMask, leftMask))
            print(string.format("  Primary: %s (isCart: %s)",
                primary and primary:getFullType() or "nil",
                tostring(hasCart)))
            print(string.format("  Expected: Weapon='%s'", hasCart and "cart" or ""))
        end
    end

    if remoteCount == 0 then
        print("No remote players connected")
    end
    print("===============================================")
end

--- Query server's authoritative animation state
--- Server responds via debugAnimStateResponse handler below
function AnimationCommands.queryServerAnimState()
    if not isClient() then
        print("Only works in multiplayer client")
        return
    end

    local player = getPlayer()
    if not player or not player:getOnlineID() then
        print("Not connected to server")
        return
    end

    pendingDesyncCheck = false  -- Clear any pending desync check
    SaucedCarts.Network.sendToServer(player, "requestDebugAnimState", {})
    print("Requesting server animation state...")
end

--- Check for animation desync between local perception and server state
--- Requests server state, then compares when response arrives
function AnimationCommands.checkAnimDesync()
    if not isClient() then
        print("Only works in multiplayer client")
        return
    end

    local player = getPlayer()
    if not player or not player:getOnlineID() then
        print("Not connected to server")
        return
    end

    pendingDesyncCheck = true
    SaucedCarts.Network.sendToServer(player, "requestDebugAnimState", {})
    print("Requesting server state for desync check...")
end

--- Force a full animation sync request (same as late-joiner sync)
--- Useful for testing the sync mechanism or recovering from desync
function AnimationCommands.forceAnimSync()
    if not isClient() then
        print("Only works in multiplayer client")
        return
    end

    local player = getPlayer()
    if not player or not player:getOnlineID() then
        print("Not connected to server")
        return
    end

    SaucedCarts.Network.sendToServer(player, "requestAnimationSync", {})
    print("Requested full animation sync from server")
end

-- Client handler: Receive debug animation state from server
SaucedCarts.Network.registerClientHandler("debugAnimStateResponse", function(args)
    if not args then
        print("ERROR: Invalid debug response")
        return
    end

    if not pendingDesyncCheck then
        -- Just print server state
        print("========== SERVER ANIMATION STATE ==========")
        print("Equipped count: " .. tostring(args.equippedCount or 0))
        if args.states then
            for _, state in ipairs(args.states) do
                print(string.format("  [%s] onlineID=%d hasCart=%s",
                    state.username or "unknown",
                    state.onlineId or 0,
                    tostring(state.hasCart)))
            end
        end
        if not args.states or #args.states == 0 then
            print("  (no players have carts equipped)")
        end
        print("=============================================")
        return
    end

    -- Desync check mode
    pendingDesyncCheck = false

    -- Build server state lookup
    local serverState = {}
    if args.states then
        for _, state in ipairs(args.states) do
            serverState[state.onlineId] = state.hasCart
        end
    end

    -- Compare with local perception
    print("========== ANIMATION DESYNC CHECK ==========")
    local onlinePlayers = getOnlinePlayers()
    if not onlinePlayers then
        print("ERROR: Can't get online players")
        return
    end

    local desyncs = 0
    local checked = 0

    for i = 0, onlinePlayers:size() - 1 do
        local p = onlinePlayers:get(i)
        if p then
            checked = checked + 1
            local onlineId = p:getOnlineID()
            local serverSaysCart = serverState[onlineId] or false
            local localWeapon = p:getVariableString("Weapon") or ""
            local localSaysCart = (localWeapon == "cart")

            if serverSaysCart ~= localSaysCart then
                desyncs = desyncs + 1
                print(string.format("DESYNC: [%s] server=%s local=%s",
                    p:getUsername(), tostring(serverSaysCart), tostring(localSaysCart)))
            else
                print(string.format("OK: [%s] state=%s",
                    p:getUsername(), tostring(serverSaysCart)))
            end
        end
    end

    print(string.format("\nChecked %d players, found %d desyncs", checked, desyncs))
    print("============================================")
end)

return AnimationCommands
