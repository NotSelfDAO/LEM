-- src/source/repository.lua
-- APT repository management — uses core.db for persistence

local Executor = require("core.executor")
local Logger   = require("core.logger")
local FS       = require("core.fs")
local Keyring  = require("source.keyring")
local DB       = require("core.db")

local M = {}

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Map a core.db source record (field: repo) to the public format (field: url).
local function map_source_row(row)
    return {
        name         = row.name,
        url          = row.repo,
        distribution = row.distribution,
        component    = row.component,
        added_time   = row.added_time,
    }
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Add a repository.
-- Full flow: download & install GPG key, write .list file, record in DB,
-- then run apt update.
-- @param config table  { name, url, distribution, component, key_url }
-- @return boolean, string  success and output/error message
function M.add(config)
    -- 1. Download and install GPG key (if key_url provided)
    if config.key_url then
        local tmp_key = "/tmp/lem_" .. config.name .. ".key"
        local ok, err = Keyring.download(config.key_url, tmp_key)
        if not ok then return false, "failed to download key: " .. tostring(err) end

        ok, err = Keyring.install(tmp_key, config.name)
        if not ok then return false, "failed to install key: " .. tostring(err) end

        -- Clean up temporary key file
        Executor.execute("rm -f " .. tmp_key)
    end

    -- 2. Create sources.list.d entry
    FS.ensure_dir("/etc/apt/sources.list.d")
    local list_file = "/etc/apt/sources.list.d/" .. config.name .. ".list"
    local keyring_path = "/etc/apt/keyrings/" .. config.name .. ".gpg"

    local line
    if config.key_url then
        line = string.format("deb [signed-by=%s] %s %s %s",
            keyring_path, config.url, config.distribution, config.component)
    else
        line = string.format("deb %s %s %s",
            config.url, config.distribution, config.component)
    end

    FS.write(list_file, line .. "\n")
    Logger.info("Repository added: " .. config.name)

    -- 3. Record in database (core.db uses field name "repo" for the URL)
    DB.add_source(config.name, config.url, config.distribution, config.component)

    -- 4. Run apt update
    Logger.info("Running apt update...")
    local result = Executor.execute_sudo("apt update")
    return result.success, result.output
end

--- Remove a repository.
-- @param name string  repository name
-- @return boolean, string
function M.remove(name)
    local list_file = "/etc/apt/sources.list.d/" .. name .. ".list"
    local key_file  = "/etc/apt/keyrings/" .. name .. ".gpg"

    -- Remove list file
    if FS.file_exists(list_file) then
        Executor.execute_sudo("rm -f " .. list_file)
        Logger.info("Removed " .. list_file)
    end

    -- Remove key file
    if FS.file_exists(key_file) then
        Executor.execute_sudo("rm -f " .. key_file)
        Logger.info("Removed " .. key_file)
    end

    -- Remove from database
    DB.remove_source(name)

    Logger.info("Repository removed: " .. name)
    return true
end

--- List all LEM-managed sources.
-- @return table  array of source records { name, url, distribution, component, added_time }
function M.list()
    local rows = DB.list_sources()
    local result = {}
    for _, row in ipairs(rows) do
        result[#result + 1] = map_source_row(row)
    end
    return result
end

--- Run apt update to refresh package lists.
-- @return boolean, string
function M.update()
    Logger.info("Running apt update...")
    local result = Executor.execute_sudo("apt update")
    if result.success then
        Logger.info("apt update completed successfully")
    else
        Logger.error("apt update failed: " .. tostring(result.output))
    end
    return result.success, result.output
end

return M
