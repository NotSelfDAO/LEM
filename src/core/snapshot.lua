-- src/core/snapshot.lua
-- Backup snapshot creation, restoration, interrupted-update detection, and cleanup

local FS       = require("core.fs")
local Executor = require("core.executor")
local DB       = require("core.db")
local Logger   = require("core.logger")

local M = {}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local DEFAULT_BACKUP_DIR = "~/.local/share/lem/backups"
local DEFAULT_RETENTION  = 5
local DEFAULT_MAX_AGE    = 30  -- days

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Resolve the backup directory, expanding ~ if needed.
-- @param override string|nil  optional override path
-- @return string  absolute backup directory path
local function get_backup_dir(override)
    local dir = override or DEFAULT_BACKUP_DIR
    return FS.expand_path(dir)
end

--- Get file size in bytes via `wc -c`.
-- @param path string
-- @return number  file size (0 on failure)
local function file_size(path)
    local result = Executor.execute({ "wc", "-c", path })
    if result.success then
        local size = result.output:match("(%d+)")
        return tonumber(size) or 0
    end
    return 0
end

--- Extract version string from a backup filename.
-- Expected format: backup_v{version}_{timestamp}.tar.gz
-- @param filename string
-- @return string|nil  version string
local function extract_version(filename)
    return filename:match("^backup_v(.+)_+%d%d%d%d%d%d%d%d_%d%d%d%d%d%d%.tar%.gz$")
end

--- Parse a backup filename into components.
-- @param filename string
-- @return table|nil  {version, timestamp, name}
local function parse_backup_name(filename)
    local ver, ts = filename:match("^backup_v(.+)_(%d%d%d%d%d%d%d%d_%d%d%d%d%d%d)%.tar%.gz$")
    if ver and ts then
        return { version = ver, timestamp = ts, name = filename }
    end
    return nil
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Create a backup snapshot of the LEM installation.
-- @param lem_root string  root directory of the LEM installation
-- @param version string   version label for the backup
-- @return table  { success, backup_path, size_bytes, error_message }
function M.create_backup(lem_root, version)
    local ok, result = pcall(function()
        return M._create_backup_impl(lem_root, version)
    end)
    if not ok then
        Logger.error("create_backup exception: " .. tostring(result))
        return { success = false, backup_path = nil, size_bytes = 0,
                 error_message = tostring(result) }
    end
    return result
end

function M._create_backup_impl(lem_root, version)
    if not lem_root or not version then
        return { success = false, backup_path = nil, size_bytes = 0,
                 error_message = "lem_root and version are required" }
    end

    local backup_dir = get_backup_dir()
    local timestamp  = os.date("%Y%m%d_%H%M%S")
    local filename   = string.format("backup_v%s_%s.tar.gz", version, timestamp)
    local backup_path = backup_dir .. "/" .. filename

    -- Ensure backup directory exists
    local dir_ok, err = FS.ensure_dir(backup_dir)
    if not dir_ok then
        Logger.error("Failed to create backup directory: " .. tostring(err))
        return { success = false, backup_path = nil, size_bytes = 0,
                 error_message = tostring(err) }
    end

    -- Build tar command
    -- Exclude: backups/ directory itself, state.db, *.log
    -- Use -C to change to parent directory so archive contains relative paths
    local parent_dir = lem_root:match("(.+)/[^/]+/?$") or "."
    local lem_dirname = lem_root:match("([^/]+)/?$") or lem_root

    local tar_cmd = string.format(
        "tar -czf %s " ..
        "--exclude='./backups' " ..
        "--exclude='./state.db' " ..
        "--exclude='*.log' " ..
        "-C %s %s",
        backup_path, parent_dir, lem_dirname
    )

    Logger.info("Creating backup: " .. backup_path)

    local tar_result = Executor.execute(tar_cmd)
    if not tar_result.success then
        Logger.error("Backup creation failed: " .. (tar_result.output or "unknown error"))
        return { success = false, backup_path = nil, size_bytes = 0,
                 error_message = tar_result.output or "tar command failed" }
    end

    local size = file_size(backup_path)
    Logger.info(string.format("Backup created: %s (%d bytes)", backup_path, size))

    return { success = true, backup_path = backup_path, size_bytes = size }
end

--- Restore LEM installation from a backup archive.
-- @param backup_path string  path to the .tar.gz backup file
-- @param lem_root string     root directory to restore into
-- @return table  { success, error_message }
function M.restore_backup(backup_path, lem_root)
    local ok, result = pcall(function()
        return M._restore_backup_impl(backup_path, lem_root)
    end)
    if not ok then
        Logger.error("restore_backup exception: " .. tostring(result))
        return { success = false, error_message = tostring(result) }
    end
    return result
end

function M._restore_backup_impl(backup_path, lem_root)
    if not backup_path or not lem_root then
        return { success = false, error_message = "backup_path and lem_root are required" }
    end

    -- Verify backup file exists
    if not FS.file_exists(backup_path) then
        Logger.error("Backup file not found: " .. backup_path)
        return { success = false, error_message = "backup file not found: " .. backup_path }
    end

    -- Ensure target directory exists
    local dir_ok, err = FS.ensure_dir(lem_root)
    if not dir_ok then
        return { success = false, error_message = tostring(err) }
    end

    Logger.info("Restoring from backup: " .. backup_path)

    local tar_cmd = string.format("tar -xzf %s -C %s", backup_path, lem_root)
    local tar_result = Executor.execute(tar_cmd)

    if not tar_result.success then
        Logger.error("Backup restoration failed: " .. (tar_result.output or "unknown error"))
        return { success = false, error_message = tar_result.output or "tar extraction failed" }
    end

    Logger.info("Backup restored successfully from: " .. backup_path)
    return { success = true, error_message = nil }
end

--- Detect whether a previous update was interrupted.
-- Checks DB update_state for non-idle / non-done / non-nil status.
-- Also verifies whether the associated backup file still exists.
-- @return table  { interrupted, state, backup_exists }
function M.detect_interrupted()
    local ok, result = pcall(function()
        return M._detect_interrupted_impl()
    end)
    if not ok then
        Logger.error("detect_interrupted exception: " .. tostring(result))
        return { interrupted = false, state = nil, backup_exists = false }
    end
    return result
end

function M._detect_interrupted_impl()
    local state = DB.load_update_state()

    -- No state at all → nothing interrupted
    if not state then
        return { interrupted = false, state = nil, backup_exists = false }
    end

    local status = state.status or "idle"

    -- 'idle' or 'done' means no interruption
    if status == "idle" or status == "done" then
        return { interrupted = false, state = state, backup_exists = false }
    end

    -- Check if backup file exists
    local backup_exists = false
    if state.backup_path and state.backup_path ~= "" then
        backup_exists = FS.file_exists(state.backup_path)
    end

    Logger.warn(string.format(
        "Interrupted update detected: status=%s, from=%s, to=%s, backup_exists=%s",
        status,
        state.from_version or "?",
        state.to_version or "?",
        tostring(backup_exists)
    ))

    return { interrupted = true, state = state, backup_exists = backup_exists }
end

--- Present interactive recovery options after an interrupted update.
-- @param state table  the update state from detect_interrupted()
-- @return string  user choice: "restore", "continue", or "skip"
function M.offer_recovery(state)
    if not state then
        return "skip"
    end

    io.stderr:write("\n")
    io.stderr:write("========================================\n")
    io.stderr:write("  Interrupted Update Detected\n")
    io.stderr:write("========================================\n")
    io.stderr:write(string.format("  From version : %s\n", state.from_version or "unknown"))
    io.stderr:write(string.format("  To version   : %s\n", state.to_version or "unknown"))
    io.stderr:write(string.format("  Status       : %s\n", state.status or "unknown"))
    io.stderr:write(string.format("  Progress     : %.0f%%\n", state.progress_pct or 0))
    if state.error_message and state.error_message ~= "" then
        io.stderr:write(string.format("  Last error   : %s\n", state.error_message))
    end
    if state.started_at then
        io.stderr:write(string.format("  Started at   : %s\n", state.started_at))
    end
    io.stderr:write("========================================\n")
    io.stderr:write("\n")
    io.stderr:write("  [R] Restore from backup (revert to pre-update state)\n")
    io.stderr:write("  [C] Continue from interrupted step\n")
    io.stderr:write("  [S] Skip — clear interrupted state and proceed\n")
    io.stderr:write("\n")

    -- Read user choice (loop until valid)
    while true do
        io.stderr:write("  Enter choice (R/C/S): ")
        local input = io.read("*l")
        if not input then
            -- EOF / non-interactive → default to skip
            io.stderr:write("\n  Non-interactive mode, defaulting to Skip.\n")
            return "skip"
        end

        local choice = input:lower():match("^%s*(%S)%s*$")
        if choice == "r" then
            io.stderr:write("  → Choosing: Restore from backup\n")
            return "restore"
        elseif choice == "c" then
            io.stderr:write("  → Choosing: Continue update\n")
            return "continue"
        elseif choice == "s" then
            io.stderr:write("  → Choosing: Skip (clear state)\n")
            return "skip"
        else
            io.stderr:write("  Invalid choice. Please enter R, C, or S.\n")
        end
    end
end

--- Prune old backup files based on retention count and max age.
-- @param backup_dir string|nil  backup directory (default: ~/.local/share/lem/backups)
-- @param retention number|nil   max number of recent backups to keep (default 5)
-- @param max_age_days number|nil  delete backups older than this many days (default 30)
-- @return table  { pruned_count, kept_count }
function M.prune_old_backups(backup_dir, retention, max_age_days)
    local ok, result = pcall(function()
        return M._prune_old_backups_impl(backup_dir, retention, max_age_days)
    end)
    if not ok then
        Logger.error("prune_old_backups exception: " .. tostring(result))
        return { pruned_count = 0, kept_count = 0 }
    end
    return result
end

function M._prune_old_backups_impl(backup_dir, retention, max_age_days)
    backup_dir  = get_backup_dir(backup_dir)
    retention   = retention or DEFAULT_RETENTION
    max_age_days = max_age_days or DEFAULT_MAX_AGE

    -- Ensure directory exists
    if not FS.file_exists(backup_dir) then
        return { pruned_count = 0, kept_count = 0 }
    end

    -- List backup files sorted by modification time (newest first)
    local ls_result = Executor.execute({ "ls", "-1t", backup_dir })
    if not ls_result.success then
        Logger.warn("Failed to list backup directory: " .. (ls_result.output or ""))
        return { pruned_count = 0, kept_count = 0 }
    end

    -- Parse filenames from output
    local all_backups = {}
    for line in ls_result.output:gmatch("[^\n]+") do
        local fname = line:match("^backup_v.+.tar%.gz$")
        if fname then
            all_backups[#all_backups + 1] = fname
        end
    end

    if #all_backups == 0 then
        return { pruned_count = 0, kept_count = 0 }
    end

    -- Determine which to keep and which to prune
    local to_keep = {}
    local to_prune = {}

    -- First: keep the newest `retention` backups
    for i, fname in ipairs(all_backups) do
        if i <= retention then
            to_keep[fname] = true
        else
            to_prune[fname] = true
        end
    end

    -- Second: also prune anything older than max_age_days (via find)
    if max_age_days > 0 then
        local find_cmd = string.format(
            "find %s -maxdepth 1 -name 'backup_v*.tar.gz' -mtime +%d -type f",
            backup_dir, max_age_days
        )
        local find_result = Executor.execute(find_cmd)
        if find_result.success then
            for line in find_result.output:gmatch("[^\n]+") do
                local fname = line:match("([^/]+)$")
                if fname then
                    to_prune[fname] = true
                    to_keep[fname] = nil  -- age overrides retention keep
                end
            end
        end
    end

    -- Execute pruning
    local pruned_count = 0
    for fname in pairs(to_prune) do
        local fpath = backup_dir .. "/" .. fname
        local rm_result = Executor.execute({ "rm", "-f", fpath })
        if rm_result.success then
            pruned_count = pruned_count + 1
            Logger.debug("Pruned old backup: " .. fname)
        else
            Logger.warn("Failed to prune backup: " .. fname)
        end
    end

    local kept_count = #all_backups - pruned_count
    Logger.info(string.format("Backup prune complete: pruned=%d, kept=%d", pruned_count, kept_count))

    return { pruned_count = pruned_count, kept_count = kept_count }
end

--- List all available backup snapshots.
-- Scans the default backup directory for backup_v*.tar.gz files.
-- @return table  array of { name, path, size, date, version }
function M.list_backups()
    local ok, result = pcall(function()
        return M._list_backups_impl()
    end)
    if not ok then
        Logger.error("list_backups exception: " .. tostring(result))
        return {}
    end
    return result
end

function M._list_backups_impl()
    local backup_dir = get_backup_dir()

    if not FS.file_exists(backup_dir) then
        return {}
    end

    -- Use ls -lt to get files with details (newest first)
    local ls_result = Executor.execute({ "ls", "-lt", backup_dir })
    if not ls_result.success then
        return {}
    end

    local backups = {}
    for line in ls_result.output:gmatch("[^\n]+") do
        -- ls -lt format: perms links owner group size month day time/year filename
        local size, month, day, time_or_year, filename =
            line:match("^%S+%s+%d+%s+%S+%s+%S+%s+(%d+)%s+(%w+)%s+(%d+)%s+([%d:]+)%s+(%S+)$")

        if filename then
            local ver = extract_version(filename)
            if ver then
                backups[#backups + 1] = {
                    name    = filename,
                    path    = backup_dir .. "/" .. filename,
                    size    = tonumber(size) or 0,
                    date    = string.format("%s %s %s", month, day, time_or_year),
                    version = ver,
                }
            end
        end
    end

    return backups
end

return M
