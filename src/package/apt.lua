-- src/package/apt.lua
-- APT backend: manage packages via apt/dpkg

local Executor = require("core.executor")
local Logger   = require("core.logger")
local DB       = require("core.db")

local M = {}

function M.install(package_name)
    -- 1. Check if already installed
    if M.is_installed(package_name) then
        Logger.info(package_name .. " is already installed")
        return true
    end

    -- 2. Execute sudo apt install -y <package>
    Logger.info("Installing " .. package_name .. " via apt...")
    local result = Executor.execute_sudo("apt install -y " .. package_name)

    -- 3. Check result
    if result.success then
        -- 4. Get version
        local version = M.get_version(package_name)
        -- 5. Record to database
        DB.add_package(package_name, "apt", version)
        Logger.info(package_name .. " installed successfully via apt")
        return true
    else
        Logger.error("Failed to install " .. package_name .. " via apt")
        return false, result.output
    end
end

function M.remove(package_name)
    if not M.is_installed(package_name) then
        Logger.info(package_name .. " is not installed via apt")
        return true
    end

    Logger.info("Removing " .. package_name .. " via apt...")
    local result = Executor.execute_sudo("apt remove -y " .. package_name)

    if result.success then
        DB.remove_package(package_name)
        Logger.info(package_name .. " removed successfully via apt")
        return true
    else
        Logger.error("Failed to remove " .. package_name .. " via apt")
        return false, result.output
    end
end

function M.is_installed(package_name)
    local result = Executor.execute("dpkg -s " .. package_name)
    -- dpkg -s returns 0 if installed
    return result.exit_code == 0
end

function M.get_version(package_name)
    local result = Executor.execute("dpkg -s " .. package_name)
    if result.success then
        -- Parse Version: line from output
        for line in result.output:gmatch("[^\n]+") do
            local ver = line:match("^Version:%s*(.+)")
            if ver then return ver end
        end
    end
    return "unknown"
end

function M.search(package_name)
    local result = Executor.execute("apt-cache show " .. package_name)
    return result.success, result.output
end

return M
