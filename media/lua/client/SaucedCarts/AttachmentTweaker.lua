--[[
    SaucedCarts Attachment Tweaker

    Real-time debug utility for adjusting attachment offset/rotation/scale
    while holding a cart. See changes INSTANTLY - no file editing required!

    USAGE:
        SaucedCartsTweaker.list()                      -- Show attached items with slot numbers
        SaucedCartsTweaker.enable()                    -- Tweak held item (hands)
        SaucedCartsTweaker.enable_slot(1)              -- Tweak body slot #1 (back, hip, etc.)
        SaucedCartsTweaker.enable_for_back()           -- Tweak back (auto-detects)
        SaucedCartsTweaker.enable_for("bone_name")     -- Tweak by bone name
        SaucedCartsTweaker.disable()                   -- Stop tweaking, print final values
        SaucedCartsTweaker.print()                     -- Print current values to console

    Workflow: .list() to see slots, then .enable_slot(N) to tweak one.

    KEYBINDS (while enabled):
        OFFSET (Position):         Numpad    OR    Regular
            X axis (height)        7 / 9           U / O
            Y axis (forward)       4 / 6           J / L
            Z axis (lateral)       1 / 3           M / .

        ROTATION:
            Insert/Delete  = X rotation (pitch)
            Home/End       = Y rotation (yaw - turn left/right)
            PageUp/PageDn  = Z rotation (roll - tilt to level)

        OTHER:                     Numpad    OR    Regular
            Step size              + / -           = / -
            Scale                  * / /           ] / [
            Print values           0               P
            Toggle HUD             .               H
]]

if isServer() then return end

require "ISUI/ISPanel"

SaucedCartsTweaker = SaucedCartsTweaker or {}

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------

local enabled = false
local hudVisible = true
local currentModelScript = nil
local tweakMode = "hands"
local targetAttachments = { "Bip01_Prop1", "Bip01_Prop2" }

-- Current values
local offset = { x = 0, y = 0, z = 0 }
local rotate = { x = 0, y = 0, z = 0 }
local scale = 1.0

-- Step sizes
local stepSizes = { 0.01, 0.05, 0.1, 0.5 }
local stepIndex = 2  -- Start at 0.05
local rotateStep = 5.0  -- Degrees

-- Axis labels (based on our testing)
local axisLabels = {
    offsetX = "Height (up/down)",
    offsetY = "Forward (away/toward)",
    offsetZ = "Lateral (left/right)",
    rotateX = "Pitch",
    rotateY = "Yaw (turn)",
    rotateZ = "Roll (tilt)",
}

---------------------------------------------------------------------------
-- HUD PANEL
---------------------------------------------------------------------------

local TweakerHUD = ISPanel:derive("TweakerHUD")

function TweakerHUD:new(x, y)
    local width = 320
    local height = 220
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.moveWithMouse = true
    return o
end

function TweakerHUD:render()
    ISPanel.render(self)

    local font = UIFont.Small
    local fontH = getTextManager():getFontHeight(font)
    local x = 10
    local y = 10
    local col = { r = 1, g = 1, b = 1, a = 1 }
    local colLabel = { r = 0.7, g = 0.7, b = 0.7, a = 1 }
    local colValue = { r = 0.3, g = 1, b = 0.3, a = 1 }
    local colHeader = { r = 1, g = 0.8, b = 0.2, a = 1 }

    -- Title + mode
    self:drawText("ATTACHMENT TWEAKER [" .. string.upper(tweakMode) .. "]", x, y, colHeader.r, colHeader.g, colHeader.b, colHeader.a, font)
    y = y + fontH + 5

    -- Step size
    local step = stepSizes[stepIndex]
    self:drawText(string.format("Step: %.2f  |  Rot Step: %.0f", step, rotateStep), x, y, colLabel.r, colLabel.g, colLabel.b, colLabel.a, font)
    y = y + fontH + 10

    -- Offset section
    self:drawText("OFFSET", x, y, colHeader.r, colHeader.g, colHeader.b, colHeader.a, font)
    self:drawText("ROTATION", x + 160, y, colHeader.r, colHeader.g, colHeader.b, colHeader.a, font)
    y = y + fontH + 2

    -- X row
    self:drawText("X:", x, y, colLabel.r, colLabel.g, colLabel.b, colLabel.a, font)
    self:drawText(string.format("%.4f", offset.x), x + 25, y, colValue.r, colValue.g, colValue.b, colValue.a, font)
    self:drawText("X:", x + 160, y, colLabel.r, colLabel.g, colLabel.b, colLabel.a, font)
    self:drawText(string.format("%.1f", rotate.x), x + 185, y, colValue.r, colValue.g, colValue.b, colValue.a, font)
    y = y + fontH

    -- Y row
    self:drawText("Y:", x, y, colLabel.r, colLabel.g, colLabel.b, colLabel.a, font)
    self:drawText(string.format("%.4f", offset.y), x + 25, y, colValue.r, colValue.g, colValue.b, colValue.a, font)
    self:drawText("Y:", x + 160, y, colLabel.r, colLabel.g, colLabel.b, colLabel.a, font)
    self:drawText(string.format("%.1f", rotate.y), x + 185, y, colValue.r, colValue.g, colValue.b, colValue.a, font)
    y = y + fontH

    -- Z row
    self:drawText("Z:", x, y, colLabel.r, colLabel.g, colLabel.b, colLabel.a, font)
    self:drawText(string.format("%.4f", offset.z), x + 25, y, colValue.r, colValue.g, colValue.b, colValue.a, font)
    self:drawText("Z:", x + 160, y, colLabel.r, colLabel.g, colLabel.b, colLabel.a, font)
    self:drawText(string.format("%.1f", rotate.z), x + 185, y, colValue.r, colValue.g, colValue.b, colValue.a, font)
    y = y + fontH + 5

    -- Scale
    self:drawText("Scale:", x, y, colLabel.r, colLabel.g, colLabel.b, colLabel.a, font)
    self:drawText(string.format("%.4f", scale), x + 50, y, colValue.r, colValue.g, colValue.b, colValue.a, font)
    y = y + fontH + 10

    -- Axis hints
    self:drawText("X=Height  Y=Forward  Z=Lateral", x, y, 0.5, 0.5, 0.5, 1, font)
    y = y + fontH
    self:drawText("RotY=Turn  RotZ=Tilt/Level", x, y, 0.5, 0.5, 0.5, 1, font)
    y = y + fontH + 5

    -- Instructions
    self:drawText("[Numpad 0 = Copy Values]", x, y, 0.6, 0.6, 0.6, 1, font)
end

local hudPanel = nil

local function showHUD()
    if hudPanel then return end
    hudPanel = TweakerHUD:new(50, 200)
    hudPanel:initialise()
    hudPanel:addToUIManager()
end

local function hideHUD()
    if hudPanel then
        hudPanel:removeFromUIManager()
        hudPanel = nil
    end
end

---------------------------------------------------------------------------
-- CORE FUNCTIONS
---------------------------------------------------------------------------

local function getStep()
    return stepSizes[stepIndex]
end

local function getTargetAttachments()
    return targetAttachments
end

local function printValues()
    local attachNames = getTargetAttachments()
    print("")
    print("=== SaucedCarts Attachment Tweaker ===")
    print("Mode: " .. tweakMode .. " (" .. table.concat(attachNames, ", ") .. ")")
    print("")
    print("-- Copy/paste into your model script:")
    for _, name in ipairs(attachNames) do
        print(string.format("        attachment %s", name))
        print("        {")
        print(string.format("            offset = %.4f %.4f %.4f,", offset.x, offset.y, offset.z))
        print(string.format("            rotate = %.1f %.1f %.1f,", rotate.x, rotate.y, rotate.z))
        print(string.format("            scale = %.4f,", scale))
        print("        }")
        print("")
    end
    print("-- Axis reference:")
    print("--   Offset X = Height (up/down)")
    print("--   Offset Y = Forward (away from player)")
    print("--   Offset Z = Lateral (left/right)")
    print("--   Rotate Y = Yaw (turn cart around)")
    print("--   Rotate Z = Roll (tilt to level)")
    print("======================================")
    print("")
end

-- Get or create an attachment on the model script
local function getOrCreateAttachment(modelScript, name)
    local attach = modelScript:getAttachmentById(name)
    if attach then return attach, false end

    -- Create a new attachment at runtime
    attach = ModelAttachment.new(name)
    attach:setBone(name)
    attach:getOffset():set(0, 0, 0)
    attach:getRotate():set(0, 0, 0)
    attach:setScale(1.0)
    modelScript:addAttachment(attach)
    print("Tweaker: Created attachment '" .. name .. "' (did not exist on model)")
    return attach, true
end

local function applyToAttachments()
    if not currentModelScript then return end

    for _, name in ipairs(getTargetAttachments()) do
        local attach = getOrCreateAttachment(currentModelScript, name)
        local off = attach:getOffset()
        if off then
            off:set(offset.x, offset.y, offset.z)
        end

        local rot = attach:getRotate()
        if rot then
            rot:set(rotate.x, rotate.y, rotate.z)
        end

        attach:setScale(scale)
    end
end

local function loadFromModelScript(modelScript)
    local targetName = getTargetAttachments()[1]
    local attach = modelScript:getAttachmentById(targetName)
    if attach then
        local off = attach:getOffset()
        if off then
            offset.x = off:x()
            offset.y = off:y()
            offset.z = off:z()
        end

        local rot = attach:getRotate()
        if rot then
            rotate.x = rot:x()
            rotate.y = rot:y()
            rotate.z = rot:z()
        end

        scale = attach:getScale() or 1.0
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------

-- Get info about all attached body items: { model, bone, location }
local function getAttachedItemInfos(player)
    local results = {}
    local attachedItems = player:getAttachedItems()
    if not attachedItems or attachedItems:size() == 0 then return results end

    local group = attachedItems:getGroup()
    for i = 0, attachedItems:size() - 1 do
        local attached = attachedItems:get(i)
        local location = attached:getLocation()
        local item = attached:getItem()
        local model = item and item:getStaticModel() or nil
        local bone = nil
        if group then
            local loc = group:getLocation(location)
            if loc then
                bone = loc:getAttachmentName()
            end
        end
        if model then
            table.insert(results, { model = model, bone = bone, location = location })
        end
    end
    return results
end

-- Resolve model + bone from: explicit string > held item > attached items
-- Returns modelName, actualBone (bone may differ from requested targetBone)
local function resolveModelAndBone(modelNameOrNil, targetBone)
    if modelNameOrNil and type(modelNameOrNil) == "string" then
        return modelNameOrNil, targetBone
    end

    local player = getPlayer()
    if not player then
        print("Tweaker: No player found")
        return nil, nil
    end

    -- Try held item first
    local item = player:getPrimaryHandItem()
    if item then
        local modelName = item:getStaticModel()
        if modelName then return modelName, targetBone end
    end

    -- Scan attached items
    local infos = getAttachedItemInfos(player)

    -- Try matching the target bone exactly
    if targetBone then
        for _, info in ipairs(infos) do
            if info.bone == targetBone then
                print("Tweaker: Found attached item on " .. targetBone)
                return info.model, targetBone
            end
        end
    end

    -- Use first attached item, return its actual bone
    if #infos > 0 then
        local info = infos[1]
        local bone = info.bone or targetBone
        print("Tweaker: Using attached item at " .. (info.location or "?") .. " (bone: " .. tostring(bone) .. ")")
        return info.model, bone
    end

    print("Tweaker: No item found. Hold an item, attach one to your body, or pass a model name.")
    print("  Tip: SaucedCartsTweaker.list() to see attached items")
    return nil, nil
end

local function enableWithMode(mode, attachments, modelNameOrNil)
    local modelName, actualBone = resolveModelAndBone(modelNameOrNil, attachments[1])
    if not modelName then return end

    -- Update attachment targets if auto-detection found a different bone
    if actualBone and actualBone ~= attachments[1] then
        attachments = { actualBone }
        mode = actualBone
    end

    tweakMode = mode
    targetAttachments = attachments
    print("Tweaker: Model: " .. tostring(modelName))
    print("Tweaker: Mode: " .. mode .. " (" .. table.concat(attachments, ", ") .. ")")

    -- Get the ModelScript from ScriptManager
    local modelScript = ScriptManager.instance:getModelScript(modelName)
    if not modelScript then
        print("Tweaker: Could not find ModelScript for: " .. tostring(modelName))
        return
    end

    currentModelScript = modelScript

    local targetName = attachments[1]
    if loadFromModelScript(modelScript) then
        print("Tweaker: Loaded current values from " .. targetName)
    else
        print("Tweaker: No " .. targetName .. " attachment found, using defaults")
    end

    enabled = true
    showHUD()

    print("")
    print("=== TWEAKER ENABLED (" .. string.upper(mode) .. ") ===")
    print("Target: " .. table.concat(attachments, ", "))
    print("Keybinds (Numpad OR Regular):")
    print("  Offset X (height):  7/9  or  U/O")
    print("  Offset Y (fwd):     4/6  or  J/L")
    print("  Offset Z (lateral): 1/3  or  M/.")
    print("  Rotate: Ins/Del=X  Home/End=Y  PgUp/PgDn=Z")
    print("  Scale:  */÷  or  ]/[")
    print("  Step:   +/-  or  =/-")
    print("  Print:  0    or  P")
    print("  HUD:    .    or  H")
    print("")
    printValues()
end

-- enable() - tweak hand attachments. Item must be in hands.
function SaucedCartsTweaker.enable()
    enableWithMode("hands", { "Bip01_Prop1", "Bip01_Prop2" })
end

-- enable_for_back(modelName) - tweak back attachment.
-- modelName optional if item is in hands, required if item is on back.
function SaucedCartsTweaker.enable_for_back(modelName)
    enableWithMode("back", { "Bip01_BackPack" }, modelName)
end

-- enable_for(attachmentName, modelName) - tweak any named attachment.
-- modelName optional if item is in hands.
function SaucedCartsTweaker.enable_for(attachmentName, modelName)
    if not attachmentName or type(attachmentName) ~= "string" then
        print("Tweaker: Usage: SaucedCartsTweaker.enable_for(\"attachment_name\")")
        print("  SaucedCartsTweaker.enable_for(\"attachment_name\", \"ModelName\")")
        print("  Examples: \"Bip01_BackPack\", \"wrench_left\", \"wrench_right\"")
        return
    end
    enableWithMode(attachmentName, { attachmentName }, modelName)
end

function SaucedCartsTweaker.disable()
    enabled = false
    hideHUD()
    print("")
    print("=== TWEAKER DISABLED ===")
    printValues()
    currentModelScript = nil
    tweakMode = "hands"
    targetAttachments = { "Bip01_Prop1", "Bip01_Prop2" }
end

function SaucedCartsTweaker.print()
    printValues()
end

function SaucedCartsTweaker.list()
    local player = getPlayer()
    if not player then
        print("Tweaker: No player found")
        return
    end

    print("")
    print("=== Attached Items ===")

    -- Held items
    local primary = player:getPrimaryHandItem()
    local secondary = player:getSecondaryHandItem()
    if primary then
        print(string.format("  [hands]  Model: %s", tostring(primary:getStaticModel())))
    end
    if secondary and secondary ~= primary then
        print(string.format("  [off-hand]  Model: %s", tostring(secondary:getStaticModel())))
    end

    -- Body-attached items
    local infos = getAttachedItemInfos(player)
    if #infos == 0 then
        print("  (no body-attached items)")
    else
        for i, info in ipairs(infos) do
            print(string.format("  #%d  [%s]  Bone: %s  Model: %s",
                i, info.location or "?", info.bone or "?", info.model or "?"))
        end
    end

    print("")
    print("Usage:")
    print("  SaucedCartsTweaker.enable_slot(1)   -- tweak slot #1 from list above")
    print("  SaucedCartsTweaker.enable_slot(2)   -- tweak slot #2, etc.")
    print("======================")
    print("")
end

-- enable_slot(n) - tweak the Nth body-attached item from list()
function SaucedCartsTweaker.enable_slot(n)
    local player = getPlayer()
    if not player then
        print("Tweaker: No player found")
        return
    end

    local infos = getAttachedItemInfos(player)
    if #infos == 0 then
        print("Tweaker: No body-attached items. Attach a weapon first.")
        return
    end

    if not n or type(n) ~= "number" or n < 1 or n > #infos then
        print("Tweaker: Invalid slot. Use SaucedCartsTweaker.list() to see available slots (1-" .. #infos .. ")")
        return
    end

    local info = infos[n]
    print("Tweaker: Slot #" .. n .. ": " .. (info.location or "?") .. " (bone: " .. (info.bone or "?") .. ")")
    enableWithMode(info.bone or info.location, { info.bone or info.location }, info.model)
end

function SaucedCartsTweaker.isEnabled()
    return enabled
end

function SaucedCartsTweaker.toggleHUD()
    hudVisible = not hudVisible
    if hudVisible then
        showHUD()
    else
        hideHUD()
    end
end

function SaucedCartsTweaker.set(ox, oy, oz, rx, ry, rz, s)
    offset.x = ox or offset.x
    offset.y = oy or offset.y
    offset.z = oz or offset.z
    rotate.x = rx or rotate.x
    rotate.y = ry or rotate.y
    rotate.z = rz or rotate.z
    scale = s or scale
    applyToAttachments()
    print("Values set.")
    printValues()
end

function SaucedCartsTweaker.reset()
    if currentModelScript then
        loadFromModelScript(currentModelScript)
        applyToAttachments()
        print("Reset to model values.")
    end
end

---------------------------------------------------------------------------
-- ADJUSTMENT FUNCTIONS
---------------------------------------------------------------------------

local function adjust(field, axis, delta)
    if field == "offset" then
        if axis == "x" then offset.x = offset.x + delta
        elseif axis == "y" then offset.y = offset.y + delta
        elseif axis == "z" then offset.z = offset.z + delta
        end
    elseif field == "rotate" then
        if axis == "x" then rotate.x = rotate.x + delta
        elseif axis == "y" then rotate.y = rotate.y + delta
        elseif axis == "z" then rotate.z = rotate.z + delta
        end
    elseif field == "scale" then
        scale = scale + delta
        if scale < 0.01 then scale = 0.01 end
    end
    applyToAttachments()
end

---------------------------------------------------------------------------
-- KEYBIND HANDLER
---------------------------------------------------------------------------

local function onKeyPressed(key)
    if not enabled then return end

    local step = getStep()

    -- OFFSET CONTROLS (Numpad OR regular keys with modifiers)
    -- X axis (height): Numpad 7/9 OR U/O
    if key == Keyboard.KEY_NUMPAD7 or key == Keyboard.KEY_U then
        adjust("offset", "x", step)
    elseif key == Keyboard.KEY_NUMPAD9 or key == Keyboard.KEY_O then
        adjust("offset", "x", -step)
    -- Y axis (forward): Numpad 4/6 OR J/L
    elseif key == Keyboard.KEY_NUMPAD4 or key == Keyboard.KEY_J then
        adjust("offset", "y", -step)
    elseif key == Keyboard.KEY_NUMPAD6 or key == Keyboard.KEY_L then
        adjust("offset", "y", step)
    -- Z axis (lateral): Numpad 1/3 OR M/. (period)
    elseif key == Keyboard.KEY_NUMPAD1 or key == Keyboard.KEY_M then
        adjust("offset", "z", step)
    elseif key == Keyboard.KEY_NUMPAD3 or key == Keyboard.KEY_PERIOD then
        adjust("offset", "z", -step)

    -- ROTATION CONTROLS (same keys work)
    elseif key == Keyboard.KEY_INSERT then
        adjust("rotate", "x", rotateStep)
    elseif key == Keyboard.KEY_DELETE then
        adjust("rotate", "x", -rotateStep)
    elseif key == Keyboard.KEY_HOME then
        adjust("rotate", "y", rotateStep)
    elseif key == Keyboard.KEY_END then
        adjust("rotate", "y", -rotateStep)
    elseif key == Keyboard.KEY_PRIOR then  -- PageUp
        adjust("rotate", "z", rotateStep)
    elseif key == Keyboard.KEY_NEXT then   -- PageDown
        adjust("rotate", "z", -rotateStep)

    -- SCALE CONTROLS: Numpad */ OR [ ]
    elseif key == Keyboard.KEY_MULTIPLY or key == Keyboard.KEY_RBRACKET then
        adjust("scale", nil, step)
    elseif key == Keyboard.KEY_DIVIDE or key == Keyboard.KEY_LBRACKET then
        adjust("scale", nil, -step)

    -- STEP SIZE: Numpad +/- OR = and -
    elseif key == Keyboard.KEY_ADD or key == Keyboard.KEY_EQUALS then
        stepIndex = stepIndex + 1
        if stepIndex > #stepSizes then stepIndex = 1 end
        print(string.format("Step size: %.2f", getStep()))
    elseif key == Keyboard.KEY_SUBTRACT or key == Keyboard.KEY_MINUS then
        stepIndex = stepIndex - 1
        if stepIndex < 1 then stepIndex = #stepSizes end
        print(string.format("Step size: %.2f", getStep()))

    -- PRINT VALUES: Numpad 0 OR P
    elseif key == Keyboard.KEY_NUMPAD0 or key == Keyboard.KEY_P then
        printValues()

    -- TOGGLE HUD: Numpad . OR H
    elseif key == Keyboard.KEY_DECIMAL or key == Keyboard.KEY_H then
        SaucedCartsTweaker.toggleHUD()
    end
end

Events.OnKeyPressed.Add(onKeyPressed)

---------------------------------------------------------------------------
-- INIT
---------------------------------------------------------------------------

print("[SaucedCarts] Attachment Tweaker loaded")
print("  .list()          -- show all attached items with slot numbers")
print("  .enable()        -- tweak held item (hands)")
print("  .enable_slot(1)  -- tweak body slot #1 (back, hip, etc.)")
