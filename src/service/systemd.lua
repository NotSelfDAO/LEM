local Executor = require("core.executor")
local Logger = require("core.logger")

local M = {}

function M.start(service)
    Logger.info("Starting service: " .. service)
    local result = Executor.execute_sudo("systemctl start " .. service)
    return result.success, result.output
end

function M.stop(service)
    Logger.info("Stopping service: " .. service)
    local result = Executor.execute_sudo("systemctl stop " .. service)
    return result.success, result.output
end

function M.enable(service)
    Logger.info("Enabling service: " .. service)
    local result = Executor.execute_sudo("systemctl enable " .. service)
    return result.success, result.output
end

function M.disable(service)
    Logger.info("Disabling service: " .. service)
    local result = Executor.execute_sudo("systemctl disable " .. service)
    return result.success, result.output
end

function M.restart(service)
    Logger.info("Restarting service: " .. service)
    local result = Executor.execute_sudo("systemctl restart " .. service)
    return result.success, result.output
end

function M.is_active(service)
    local result = Executor.execute("systemctl is-active " .. service)
    return result.exit_code == 0
end

return M
