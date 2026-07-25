local Executor = require("core.executor")
local FS = require("core.fs")
local Logger = require("core.logger")

local M = {}

local DEFAULT_CONFIGS = { "nvim", "git", "tmux", "bash" }

function M.backup(configs, backup_dir)
    configs = configs or DEFAULT_CONFIGS
    backup_dir = backup_dir or FS.expand_path("~/.local/share/lem/backups")
    FS.ensure_dir(backup_dir)
    local config_dir = FS.expand_path("~/.config")
    local backed_up = 0
    for _, name in ipairs(configs) do
        local src = config_dir .. "/" .. name
        local dest = backup_dir .. "/" .. name
        local result = Executor.execute("test -e " .. src)
        if result.exit_code == 0 then
            local cp_result = Executor.execute("cp -a " .. src .. " " .. dest)
            if cp_result.success then
                Logger.info("Backed up: " .. name)
                backed_up = backed_up + 1
            else
                Logger.error("Failed to backup: " .. name)
            end
        else
            Logger.warn("Config not found, skipping: " .. name)
        end
    end
    print("Backed up " .. backed_up .. " config(s) to " .. backup_dir)
    return true
end

function M.restore(configs, backup_dir)
    configs = configs or DEFAULT_CONFIGS
    backup_dir = backup_dir or FS.expand_path("~/.local/share/lem/backups")
    local config_dir = FS.expand_path("~/.config")
    local restored = 0
    for _, name in ipairs(configs) do
        local src = backup_dir .. "/" .. name
        local dest = config_dir .. "/" .. name
        if FS.file_exists(src) or Executor.execute("test -d " .. src).exit_code == 0 then
            local cp_result = Executor.execute("cp -a " .. src .. " " .. dest)
            if cp_result.success then
                Logger.info("Restored: " .. name)
                restored = restored + 1
            else
                Logger.error("Failed to restore: " .. name)
            end
        else
            Logger.warn("Backup not found, skipping: " .. name)
        end
    end
    print("Restored " .. restored .. " config(s) from " .. backup_dir)
    return true
end

function M.list_backups(backup_dir)
    backup_dir = backup_dir or FS.expand_path("~/.local/share/lem/backups")
    if not FS.file_exists(backup_dir) then
        print("No backups found")
        return {}
    end
    local result = Executor.execute("ls " .. backup_dir)
    if result.success then
        local items = {}
        for name in result.output:gmatch("%S+") do items[#items + 1] = name end
        return items
    end
    return {}
end

return M
