local Executor = require("core.executor")
local Logger = require("core.logger")
local DB = require("core.db")

local M = {}

function M.install(container_name, opts)
    opts = opts or {}
    if M.is_installed(container_name) then
        Logger.info(container_name .. " container already exists")
        return true
    end
    local cmd = "docker run -d --name " .. container_name
    if opts.port then
        cmd = cmd .. " -p " .. opts.port
    end
    if opts.env then
        for k, v in pairs(opts.env) do
            cmd = cmd .. " -e " .. k .. "=" .. v
        end
    end
    if opts.volume then
        cmd = cmd .. " -v " .. opts.volume
    end
    cmd = cmd .. " " .. (opts.image or container_name)
    Logger.info("Creating container: " .. container_name)
    local result = Executor.execute(cmd)
    if result.success then
        DB.add_package(container_name, "docker", opts.image or "latest")
        Logger.info("Container " .. container_name .. " started")
    else
        Logger.error("Failed to create container: " .. container_name)
    end
    return result.success, result.output
end

function M.remove(container_name)
    if not M.is_installed(container_name) then
        Logger.info(container_name .. " container does not exist")
        return true
    end
    Logger.info("Stopping container: " .. container_name)
    Executor.execute("docker stop " .. container_name)
    Logger.info("Removing container: " .. container_name)
    local result = Executor.execute("docker rm " .. container_name)
    if result.success then
        DB.remove_package(container_name)
        Logger.info("Container " .. container_name .. " removed")
    else
        Logger.error("Failed to remove container: " .. container_name)
    end
    return result.success, result.output
end

function M.is_installed(container_name)
    local result = Executor.execute("docker inspect " .. container_name .. " >/dev/null 2>&1")
    return result.exit_code == 0
end

function M.is_running(container_name)
    local result = Executor.execute("docker inspect -f '.State.Running' " .. container_name .. " 2>/dev/null")
    return result.success and result.output:match("true") ~= nil
end

function M.pull(image)
    Logger.info("Pulling image: " .. image)
    local result = Executor.execute("docker pull " .. image)
    return result.success, result.output
end

return M
