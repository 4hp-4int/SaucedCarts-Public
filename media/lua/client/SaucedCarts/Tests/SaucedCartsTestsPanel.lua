--[[
    SaucedCarts Tests Panel
    PURPOSE: UI panel for running tests with visual feedback
    CONTEXT: client

    Opens via: SaucedCartsDebug.openTestPanel()
]]

-- Context guard
if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISScrollingListBox"
require "SaucedCarts/Core"
require "SaucedCarts/Tests/SaucedCartsTests"

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6
local ROW_HEIGHT = BUTTON_HGT + 4

SaucedCartsTestsPanel = ISPanel:derive("SaucedCartsTestsPanel")
SaucedCartsTestsPanel.instance = nil

-- Track test results for UI updates
local testResults = {}
local currentTest = nil

function SaucedCartsTestsPanel:initialise()
    ISPanel.initialise(self)
end

function SaucedCartsTestsPanel:createChildren()
    ISPanel.createChildren(self)

    local x = UI_BORDER_SPACING
    local y = UI_BORDER_SPACING

    -- Title
    self.titleLabel = ISLabel:new(x, y, FONT_HGT_MEDIUM, "SaucedCarts Tests", 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)
    y = y + FONT_HGT_MEDIUM + UI_BORDER_SPACING

    -- Run All button
    local buttonWidth = 100
    self.runAllButton = ISButton:new(x, y, buttonWidth, BUTTON_HGT, "Run All", self, SaucedCartsTestsPanel.onRunAll)
    self.runAllButton:initialise()
    self.runAllButton:instantiate()
    self.runAllButton.borderColor = {r=1, g=1, b=1, a=0.4}
    self:addChild(self.runAllButton)

    -- Stop button
    self.stopButton = ISButton:new(x + buttonWidth + UI_BORDER_SPACING, y, buttonWidth, BUTTON_HGT, "Stop", self, SaucedCartsTestsPanel.onStop)
    self.stopButton:initialise()
    self.stopButton:instantiate()
    self.stopButton.borderColor = {r=1, g=1, b=1, a=0.4}
    self:addChild(self.stopButton)

    -- Close button
    self.closeButton = ISButton:new(self.width - buttonWidth - UI_BORDER_SPACING, y, buttonWidth, BUTTON_HGT, "Close", self, SaucedCartsTestsPanel.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self.closeButton.borderColor = {r=1, g=1, b=1, a=0.4}
    self:addChild(self.closeButton)

    y = y + BUTTON_HGT + UI_BORDER_SPACING

    -- Test count label
    local testCount = SaucedCarts.Tests.getCount()
    self.countLabel = ISLabel:new(x, y, FONT_HGT_SMALL, testCount .. " tests registered", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.countLabel:initialise()
    self:addChild(self.countLabel)
    y = y + FONT_HGT_SMALL + UI_BORDER_SPACING

    -- Scrolling test list
    local listHeight = self.height - y - FONT_HGT_SMALL - UI_BORDER_SPACING * 3
    self.testList = ISScrollingListBox:new(x, y, self.width - UI_BORDER_SPACING * 2, listHeight)
    self.testList:initialise()
    self.testList:instantiate()
    self.testList.itemheight = ROW_HEIGHT
    self.testList.selected = 0
    self.testList.joypadParent = self
    self.testList.font = UIFont.Small
    self.testList.doDrawItem = self.doDrawTestItem
    self.testList.onMouseDown = self.onTestListMouseDown
    self.testList.parent = self
    self.testList.backgroundColor = {r=0, g=0, b=0, a=0.3}
    self.testList.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    self:addChild(self.testList)

    -- Populate test list
    local tests = SaucedCarts.Tests.getTests()
    local testNames = {}
    for name, _ in pairs(tests) do
        table.insert(testNames, name)
    end
    table.sort(testNames)

    for _, name in ipairs(testNames) do
        self.testList:addItem(name, {
            name = name,
            status = "untested",
            statusText = "Untested",
            statusColor = {r=0.5, g=0.5, b=0.5}
        })
        testResults[name] = self.testList.items[#self.testList.items].item
    end

    y = y + listHeight + UI_BORDER_SPACING

    -- Status bar at bottom
    self.statusLabel = ISLabel:new(x, y, FONT_HGT_SMALL, "Ready", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self:addChild(self.statusLabel)
end

-- Custom draw function for test list items
function SaucedCartsTestsPanel:doDrawTestItem(y, item, alt)
    local itemData = item.item
    if not itemData then return y + self.itemheight end

    local x = 4
    local nameWidth = 280
    local runBtnWidth = 40
    local runBtnX = nameWidth + 10
    local statusX = runBtnX + runBtnWidth + 10

    -- Background for alternating rows
    if alt then
        self:drawRect(0, y, self.width, self.itemheight, 0.1, 1, 1, 1)
    end

    -- Highlight on hover
    if self.mouseoverSelected == item.index then
        self:drawRect(0, y, self.width, self.itemheight, 0.2, 1, 1, 1)
    end

    -- Test name
    self:drawText(itemData.name, x, y + 4, 1, 1, 1, 1, self.font)

    -- Run button (drawn as text button)
    local btnY = y + 2
    local btnH = self.itemheight - 4
    local mouseX = self:getMouseX()
    local mouseY = self:getMouseY()
    local overRunBtn = mouseX >= runBtnX and mouseX <= runBtnX + runBtnWidth and
                       mouseY >= btnY and mouseY <= btnY + btnH

    if overRunBtn then
        self:drawRect(runBtnX, btnY, runBtnWidth, btnH, 0.3, 0.3, 0.6, 1)
    else
        self:drawRect(runBtnX, btnY, runBtnWidth, btnH, 0.2, 0.2, 0.4, 1)
    end
    self:drawRectBorder(runBtnX, btnY, runBtnWidth, btnH, 0.6, 0.6, 0.8, 1)
    self:drawTextCentre("Run", runBtnX + runBtnWidth / 2, y + 4, 1, 1, 1, 1, self.font)

    -- Status text
    local color = itemData.statusColor or {r=0.5, g=0.5, b=0.5}
    self:drawText(itemData.statusText or "Untested", statusX, y + 4, color.r, color.g, color.b, 1, self.font)

    return y + self.itemheight
end

-- Handle clicks on the test list
function SaucedCartsTestsPanel:onTestListMouseDown(x, y)
    if not self.items or #self.items == 0 then return end

    local rowIndex = self:rowAt(x, y)
    if rowIndex == -1 then return end

    local item = self.items[rowIndex]
    if not item or not item.item then return end

    -- Check if click was on the Run button
    local nameWidth = 280
    local runBtnWidth = 40
    local runBtnX = nameWidth + 10

    if x >= runBtnX and x <= runBtnX + runBtnWidth then
        -- Run this specific test
        local testName = item.item.name
        if testName then
            self.parent.statusLabel:setName("Running: " .. testName)
            SaucedCarts.Tests.runOne(testName)
        end
    end
end

function SaucedCartsTestsPanel:onRunAll()
    self.statusLabel:setName("Running all tests...")
    SaucedCarts.Tests.runAll()
end

function SaucedCartsTestsPanel:onStop()
    SaucedCarts.Tests.stop()
    self.statusLabel:setName("Stopped")
end

function SaucedCartsTestsPanel:onClose()
    self:setVisible(false)
    self:removeFromUIManager()
    SaucedCartsTestsPanel.instance = nil
end

function SaucedCartsTestsPanel:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
    self:drawRectBorder(0, 0, self.width, self.height, self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
end

function SaucedCartsTestsPanel:update()
    ISPanel.update(self)
end

function SaucedCartsTestsPanel:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.backgroundColor = {r=0, g=0, b=0, a=0.8}
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    o.moveWithMouse = true

    return o
end

--- Open the test panel
function SaucedCartsTestsPanel.open()
    if SaucedCartsTestsPanel.instance then
        SaucedCartsTestsPanel.instance:setVisible(true)
        SaucedCartsTestsPanel.instance:bringToTop()
        return SaucedCartsTestsPanel.instance
    end

    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local panelW = 500
    local panelH = 600  -- Taller to show more tests
    local x = (screenW - panelW) / 2
    local y = (screenH - panelH) / 2

    local panel = SaucedCartsTestsPanel:new(x, y, panelW, panelH)
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    panel:setVisible(true)
    panel:bringToTop()

    SaucedCartsTestsPanel.instance = panel
    return panel
end

--- Update a test result in the UI
---@param testName string
---@param passed boolean
function SaucedCartsTestsPanel.updateResult(testName, passed)
    local result = testResults[testName]
    if not result then return end

    if passed then
        result.status = "passed"
        result.statusText = "PASSED"
        result.statusColor = {r=0.2, g=0.8, b=0.2}
    else
        result.status = "failed"
        result.statusText = "FAILED"
        result.statusColor = {r=0.8, g=0.2, b=0.2}
    end

    -- Update status bar with summary
    if SaucedCartsTestsPanel.instance then
        local passed_count = 0
        local failed_count = 0
        local total = 0
        for _, data in pairs(testResults) do
            total = total + 1
            if data.status == "passed" then
                passed_count = passed_count + 1
            elseif data.status == "failed" then
                failed_count = failed_count + 1
            end
        end
        local tested = passed_count + failed_count
        SaucedCartsTestsPanel.instance.statusLabel:setName(
            string.format("Tested: %d/%d | Passed: %d | Failed: %d", tested, total, passed_count, failed_count)
        )
    end
end

--- Mark a test as running
---@param testName string
function SaucedCartsTestsPanel.markRunning(testName)
    local result = testResults[testName]
    if not result then return end

    result.status = "running"
    result.statusText = "Running..."
    result.statusColor = {r=1, g=1, b=0.2}
    currentTest = testName
end

return SaucedCartsTestsPanel
