-- src/source/keyring.lua
-- GPG key management for APT repositories

local Executor = require("core.executor")
local Logger = require("core.logger")
local FS = require("core.fs")

local M = {}

--- Download a GPG key from a URL.
-- @param url  string  URL to download the key from
-- @param dest string  local path to save the key
-- @return boolean, string  success and output/error message
function M.download(url, dest)
    Logger.info("Downloading GPG key from " .. url)
    local result = Executor.execute("wget -qO " .. dest .. " " .. url)
    if not result.success then
        -- Fallback to curl
        result = Executor.execute("curl -fsSL -o " .. dest .. " " .. url)
    end
    if result.success then
        Logger.info("GPG key downloaded to " .. dest)
    else
        Logger.error("Failed to download GPG key")
    end
    return result.success, result.output
end

--- Convert a key to dearmor format (for apt).
-- @param key_path    string  path to the ASCII-armoured key
-- @param output_path string  path for the binary output
-- @return boolean, string
function M.dearmor(key_path, output_path)
    local cmd = "gpg --dearmor -o " .. output_path .. " " .. key_path
    local result = Executor.execute(cmd)
    return result.success, result.output
end

--- Install a GPG key into /etc/apt/keyrings/.
-- If the key is an .asc file it will be dearmoured automatically.
-- @param key_path string  path to the key file
-- @param name     string  repository name (used for the output filename)
-- @return boolean, string
function M.install(key_path, name)
    FS.ensure_dir("/etc/apt/keyrings")
    local dest = "/etc/apt/keyrings/" .. name .. ".gpg"

    if key_path:match("%.asc$") then
        local ok, err = M.dearmor(key_path, dest)
        if not ok then return false, "failed to dearmor key: " .. tostring(err) end
    else
        local result = Executor.execute("cp " .. key_path .. " " .. dest)
        if not result.success then return false, result.output end
    end

    Logger.info("GPG key installed to " .. dest)
    return true
end

return M
