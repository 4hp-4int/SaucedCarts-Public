--[[
    SaucedCarts Test File Output
    PURPOSE: Write test results to file for external review
    CONTEXT: client
]]

-- Context guard
if isServer() and not isClient() then return end

require "SaucedCarts/Core"

SaucedCarts.TestFileOutput = {}
local fileWriter = nil
local resultBuffer = {}

--- Open the results file for writing
function SaucedCarts.TestFileOutput.open()
    fileWriter = getFileWriter("SaucedCartsTestResults.txt", true, false)
    resultBuffer = {}

    local header = "=== SaucedCarts Test Results ==="
    local timestamp = "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S")
    local separator = string.rep("=", 40)

    SaucedCarts.TestFileOutput.write(header)
    SaucedCarts.TestFileOutput.write(timestamp)
    SaucedCarts.TestFileOutput.write(separator)
    SaucedCarts.TestFileOutput.write("")
end

--- Write a line to the results file (and console)
---@param line string The line to write
function SaucedCarts.TestFileOutput.write(line)
    line = line or ""
    print("[SaucedCarts:TEST] " .. line)
    table.insert(resultBuffer, line)

    if fileWriter then
        fileWriter:write(line .. "\n")
    end
end

--- Write formatted output
---@param fmt string Format string
---@vararg any Format arguments
function SaucedCarts.TestFileOutput.writef(fmt, ...)
    SaucedCarts.TestFileOutput.write(string.format(fmt, ...))
end

--- Close the results file
function SaucedCarts.TestFileOutput.close()
    if fileWriter then
        SaucedCarts.TestFileOutput.write("")
        SaucedCarts.TestFileOutput.write("=== End of Test Results ===")
        fileWriter:close()
        fileWriter = nil
        print("[SaucedCarts:TEST] Results saved to: Zomboid/Lua/SaucedCartsTestResults.txt")
    end
end

--- Get the buffered results as a string
---@return string
function SaucedCarts.TestFileOutput.getBuffer()
    return table.concat(resultBuffer, "\n")
end

--- Check if file output is active
---@return boolean
function SaucedCarts.TestFileOutput.isOpen()
    return fileWriter ~= nil
end

return SaucedCarts.TestFileOutput
