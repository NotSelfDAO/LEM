-- src/core/updater.lua
-- Auto-update module: check GitHub releases and apply updates
-- Refactored to step-pipeline mode with progress, resume, snapshot integration

local FS = require("core.fs")
local Executor = require("core.executor")
local Logger = require("core.logger")
local DB = require("core.db")
local Progress = require("core.progress")
local Resume = require("core.resume")
local Snapshot = require("core.snapshot")

local M = {}

------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------

-- GitHub repository (owner/repo)
M.github_repo = "AAA-Software-Wholesaler/LEM"

-- Fallback version (used when DB has no version history)
M._fallback_version = "1.0.0"

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Extract a JSON string value by key using simple pattern matching.
-- Handles: "key" : "value"  (no nested objects)
-- @param json string   raw JSON text
-- @param key  string   field name
-- @return string|nil   the matched value (without quotes)
local function json_get_string(json, key)
    if not json or not key then return nil end
    local pattern = '"' .. key .. '"%s*:%s*"([^"]*)"'
    return json:match(pattern)
end

--- Extract a JSON array of objects (simple, one-level) by key.
-- Returns an iterator over tables with string fields extracted via pattern.
-- For simplicity we only parse "browser_download_url" from assets[].
-- @param json string
-- @param key  string   array field name (e.g. "assets")
-- @return table[]      list of tables with selected fields
local function json_get_assets(json, key)
    if not json or not key then return {} end
    local assets = {}
    -- Find the array region: "assets" : [ ... ]
    local arr_start = json:find('"' .. key .. '"%s*:%s*%[')
    if not arr_start then return {} end
    -- Find matching closing bracket (simple: first ']' after start)
    local arr_end = json:find("%]", arr_start)
    if not arr_end then return {} end
    local arr_text = json:sub(arr_start, arr_end)

    -- Extract each object's browser_download_url and name
    for url in arr_text:gmatch('"browser_download_url"%s*:%s*"([^"]*)"') do
        local name = arr_text:match('"name"%s*:%s*"([^"]*)"')
        assets[#assets + 1] = {
            url = url,
            name = name or url:match("([^/]+)$"),
        }
    end
    return assets
end

--- Strip leading "v" from a version tag.
-- @param tag string  e.g. "v1.2.3"
-- @return string     e.g. "1.2.3"
local function strip_v(tag)
    if not tag then return nil end
    return (tag:gsub("^v", ""))
end

--- Load configuration from config/lem.lua with defaults.
-- @return table  configuration table
function M._load_config()
    local config_path = (_G.LEM_ROOT or ".") .. "/config/lem.lua"
    local ok, config = pcall(dofile, config_path)
    if ok and config then
        return config
    end
    return {
        update = {
            backup_retention = 3,
            backup_max_age = 30,
            resume_download = true,
            skip_unchanged_compile = true,
            download_timeout = 600,
            auto_commit = true,
        }
    }
end

--- Compute sha256 checksum of native/ directory contents for change detection.
-- @param lem_root string
-- @return string|nil  concatenated checksum string or nil on failure
local function native_checksum(lem_root)
    local native_dir = lem_root .. "/native"
    if not FS.file_exists(native_dir) then return nil end
    local result = Executor.execute(
        "find '" .. native_dir .. "' -type f -name '*.c' -o -name '*.h' | sort | xargs cat 2>/dev/null | sha256sum"
    )
    if result.success then
        return result.output:match("(%S+)")
    end
    return nil
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Get the current installed version (prefer DB version_history, fallback to hardcoded).
-- @return string  version string
function M.get_current_version()
    local history = DB.list_version_history(1)
    if history and #history > 0 then
        return history[1].version
    end
    return M._fallback_version
end

--- Check the latest release on GitHub.
-- @return table|nil  { version, tag, url, assets } or nil on failure
-- @return string|nil error message on failure
function M.check_latest()
    local api_url = string.format(
        "https://api.github.com/repos/%s/releases/latest",
        M.github_repo
    )

    Logger.info("Checking latest release: " .. api_url)

    local result = Executor.execute("curl -sL " .. api_url)
    if not result.success then
        Logger.error("curl failed: " .. tostring(result.output))
        return nil, "failed to fetch release info"
    end

    local body = result.output
    if not body or #body < 10 then
        return nil, "empty response from GitHub"
    end

    -- Check for API error
    local message = json_get_string(body, "message")
    if message and message ~= "" then
        -- Could be rate-limited or not found
        Logger.warn("GitHub API message: " .. message)
    end

    local tag = json_get_string(body, "tag_name")
    if not tag or tag == "" then
        return nil, "could not parse tag_name from response"
    end

    local version = strip_v(tag)
    local tarball_url = json_get_string(body, "tarball_url")
    local zipball_url = json_get_string(body, "zipball_url")

    -- Prefer tarball_url; fall back to constructing one
    local download_url = tarball_url
        or string.format("https://github.com/%s/archive/refs/tags/%s.tar.gz",
                         M.github_repo, tag)

    -- Parse assets (may be empty for source-only releases)
    local assets = json_get_assets(body, "assets")

    local info = {
        version = version,
        tag     = tag,
        url     = download_url,
        assets  = assets,
    }

    Logger.info("Latest version: " .. version .. " (" .. tag .. ")")
    return info
end

--- Compare two semver strings.
-- @param v1 string  e.g. "1.0.0"
-- @param v2 string  e.g. "1.2.0"
-- @return number    -1 (v1<v2), 0 (equal), 1 (v1>v2)
function M.compare_versions(v1, v2)
    if not v1 or not v2 then return 0 end

    local function parse(v)
        local parts = {}
        for n in v:gmatch("(%d+)") do
            parts[#parts + 1] = tonumber(n) or 0
        end
        return parts
    end

    local p1 = parse(v1)
    local p2 = parse(v2)
    local len = math.max(#p1, #p2)

    for i = 1, len do
        local a = p1[i] or 0
        local b = p2[i] or 0
        if a < b then return -1 end
        if a > b then return  1 end
    end
    return 0
end

--- Check whether an update is available.
-- @return table|nil  { has_update, current, latest } or nil on error
function M.has_update()
    local info, err = M.check_latest()
    if not info then
        Logger.error("has_update: " .. tostring(err))
        return nil, err
    end

    local current = M.get_current_version()
    local cmp = M.compare_versions(current, info.version)
    return {
        has_update = (cmp < 0),
        current    = current,
        latest     = info.version,
        tag        = info.tag,
        url        = info.url,
        assets     = info.assets,
    }
end

--- Download and apply an update from GitHub.
-- Step-pipeline mode with progress tracking, resume download, and snapshot backup.
-- Steps: CHECK → DOWNLOAD → BACKUP → EXTRACT → COMPILE → VERIFY → COMMIT
-- @return boolean, string|nil  (true on success, or false + error message)
function M.apply_update()
    local progress = Progress.new({"CHECK", "DOWNLOAD", "BACKUP", "EXTRACT", "COMPILE", "VERIFY", "COMMIT"})
    local start_time = os.time()

    local lem_root   = _G.LEM_ROOT or os.getenv("HOME") .. "/.local/share/lem"

    ------------------------------------------------------------------
    -- Step 0: Detect interrupted update
    ------------------------------------------------------------------
    local interrupted = Snapshot.detect_interrupted()
    if interrupted.interrupted then
        local choice = Snapshot.offer_recovery(interrupted.state)
        if choice == "restore" then
            local restore_result = Snapshot.restore_backup(
                interrupted.state.backup_path, lem_root
            )
            if restore_result.success then
                DB.clear_update_state()
                print("Restored from backup successfully.")
                return true
            else
                return false, "restore failed: " .. (restore_result.error_message or "unknown")
            end
        elseif choice == "skip" then
            DB.clear_update_state()
            print("Update state cleared.")
            return true
        end
        -- "continue" falls through to normal flow
    end

    ------------------------------------------------------------------
    -- Step 1: CHECK
    ------------------------------------------------------------------
    progress:start_step("CHECK")
    local info = M.has_update()
    if not info or not info.has_update then
        progress:complete_step()
        progress:finish()
        print("Already up to date.")
        return true
    end
    progress:complete_step()

    -- Record update start
    DB.save_update_state({
        status       = "checking",
        from_version = info.current,
        to_version   = info.latest,
        started_at   = os.date("%Y-%m-%d %H:%M:%S"),
        download_url = info.url,
    })

    print(string.format("Updating LEM: v%s -> v%s", info.current, info.latest))

    ------------------------------------------------------------------
    -- Step 2: DOWNLOAD
    ------------------------------------------------------------------
    progress:start_step("DOWNLOAD")
    DB.save_update_state({
        status       = "downloading",
        from_version = info.current,
        to_version   = info.latest,
        started_at   = os.date("%Y-%m-%d %H:%M:%S"),
        download_url = info.url,
    })

    local temp_dir = os.tmpname()
    os.remove(temp_dir)
    FS.ensure_dir(temp_dir)
    local tarball = temp_dir .. "/lem-v" .. info.latest .. ".tar.gz"

    local dl_result = Resume.download(info.url, tarball, function(downloaded, total, speed)
        progress:update(downloaded, total)
    end)

    if not dl_result.success then
        progress:finish()
        DB.save_update_state({
            status        = "failed",
            from_version  = info.current,
            to_version    = info.latest,
            started_at    = os.date("%Y-%m-%d %H:%M:%S"),
            error_message = dl_result.error or "download failed",
            download_url  = info.url,
        })
        return false, "download failed: " .. (dl_result.error or "unknown")
    end
    progress:complete_step()

    ------------------------------------------------------------------
    -- Step 3: BACKUP
    ------------------------------------------------------------------
    progress:start_step("BACKUP")
    DB.save_update_state({
        status        = "backing_up",
        from_version  = info.current,
        to_version    = info.latest,
        started_at    = os.date("%Y-%m-%d %H:%M:%S"),
        download_url  = info.url,
        bytes_downloaded = dl_result.bytes_downloaded,
        total_bytes      = dl_result.total_bytes,
    })

    local backup_result = Snapshot.create_backup(lem_root, info.current)
    if not backup_result.success then
        progress:finish()
        DB.save_update_state({
            status        = "failed",
            from_version  = info.current,
            to_version    = info.latest,
            started_at    = os.date("%Y-%m-%d %H:%M:%S"),
            error_message = "backup failed: " .. (backup_result.error_message or "unknown"),
            download_url  = info.url,
        })
        return false, "backup failed: " .. (backup_result.error_message or "unknown")
    end
    DB.save_update_state({
        status        = "backed_up",
        from_version  = info.current,
        to_version    = info.latest,
        started_at    = os.date("%Y-%m-%d %H:%M:%S"),
        backup_path   = backup_result.backup_path,
        download_url  = info.url,
        bytes_downloaded = dl_result.bytes_downloaded,
        total_bytes      = dl_result.total_bytes,
    })
    progress:complete_step()

    ------------------------------------------------------------------
    -- Step 4: EXTRACT
    ------------------------------------------------------------------
    progress:start_step("EXTRACT")
    DB.save_update_state({
        status        = "extracting",
        from_version  = info.current,
        to_version    = info.latest,
        started_at    = os.date("%Y-%m-%d %H:%M:%S"),
        backup_path   = backup_result.backup_path,
        download_url  = info.url,
        bytes_downloaded = dl_result.bytes_downloaded,
        total_bytes      = dl_result.total_bytes,
    })

    -- Extract tarball to temp directory
    local extract_dir = temp_dir .. "/extracted"
    FS.ensure_dir(extract_dir)
    local extract_result = Executor.execute(
        "tar -xzf '" .. tarball .. "' -C '" .. extract_dir .. "'"
    )
    if not extract_result.success then
        progress:finish()
        DB.save_update_state({
            status        = "failed",
            from_version  = info.current,
            to_version    = info.latest,
            started_at    = os.date("%Y-%m-%d %H:%M:%S"),
            backup_path   = backup_result.backup_path,
            error_message = "extraction failed: " .. tostring(extract_result.output),
            download_url  = info.url,
        })
        return false, "extraction failed: " .. tostring(extract_result.output)
    end

    -- Find extracted directory (GitHub tarballs have a top-level dir like LEM-owner-sha/)
    local find_result = Executor.execute("ls '" .. extract_dir .. "'")
    local extracted_dir = nil
    if find_result.success then
        for line in find_result.output:gmatch("[^\n]+") do
            line = line:match("^%s*(.-)%s*$")  -- trim
            if line ~= "" and (line:match("^LEM%-") or line:match("^lem%-")) then
                local candidate = extract_dir .. "/" .. line
                local check = Executor.execute("test -d '" .. candidate .. "'")
                if check.success then
                    extracted_dir = candidate
                    break
                end
            end
        end
    end

    if not extracted_dir then
        -- Try to find any directory in extract_dir
        if find_result.success then
            for line in (find_result.output or ""):gmatch("[^\n]+") do
                line = line:match("^%s*(.-)%s*$")
                if line ~= "" then
                    local candidate = extract_dir .. "/" .. line
                    local check = Executor.execute("test -d '" .. candidate .. "'")
                    if check.success then
                        extracted_dir = candidate
                        break
                    end
                end
            end
        end
    end

    if not extracted_dir then
        progress:finish()
        DB.save_update_state({
            status        = "failed",
            from_version  = info.current,
            to_version    = info.latest,
            started_at    = os.date("%Y-%m-%d %H:%M:%S"),
            backup_path   = backup_result.backup_path,
            error_message = "could not find extracted directory",
            download_url  = info.url,
        })
        return false, "could not find extracted directory"
    end

    -- Copy new files over, preserving user data
    -- Exclude: config/ data/ backups/ state.db and ~/.config/lem/
    local copy_result = Executor.execute(
        "rsync -a --exclude='config/' --exclude='data/' "
        .. "--exclude='backups/' --exclude='state.db' "
        .. "'" .. extracted_dir .. "/' '" .. lem_root .. "/' 2>&1 "
        .. "|| cp -r '" .. extracted_dir .. "/.' '" .. lem_root .. "/'"
    )
    if not copy_result.success then
        progress:finish()
        DB.save_update_state({
            status        = "failed",
            from_version  = info.current,
            to_version    = info.latest,
            started_at    = os.date("%Y-%m-%d %H:%M:%S"),
            backup_path   = backup_result.backup_path,
            error_message = "file copy failed",
            download_url  = info.url,
        })
        return false, "file copy failed"
    end
    progress:complete_step()

    ------------------------------------------------------------------
    -- Step 5: COMPILE
    ------------------------------------------------------------------
    progress:start_step("COMPILE")
    DB.save_update_state({
        status        = "compiling",
        from_version  = info.current,
        to_version    = info.latest,
        started_at    = os.date("%Y-%m-%d %H:%M:%S"),
        backup_path   = backup_result.backup_path,
        download_url  = info.url,
    })

    local config = M._load_config()
    local should_compile = true

    -- Check if native sources changed (skip recompilation if configured)
    -- Note: skip_unchanged_compile is reserved for future use where
    -- a pre-extract checksum comparison can be implemented.
    -- For now, always compile when gcc is available.

    if should_compile then
        local gcc_check = Executor.execute("which gcc")
        if gcc_check.success and gcc_check.output:match("gcc") then
            local makefile = lem_root .. "/native/Makefile"
            if FS.file_exists(makefile) then
                local ok = os.execute("cd '" .. lem_root .. "/native' && make clean && make 2>&1")
                if ok == true or ok == 0 then
                    Logger.info("Native modules compiled successfully.")
                else
                    Logger.warn("Native module compilation failed, using pure-Lua fallbacks.")
                end
            else
                Logger.info("No Makefile found, skipping native compilation.")
            end
        else
            Logger.info("gcc not found, skipping native module compilation.")
        end
    end
    progress:complete_step()

    ------------------------------------------------------------------
    -- Step 6: VERIFY
    ------------------------------------------------------------------
    progress:start_step("VERIFY")

    -- Verify key files exist
    local main_lua = lem_root .. "/src/main.lua"
    if not FS.file_exists(main_lua) then
        progress:finish()
        DB.save_update_state({
            status        = "failed",
            from_version  = info.current,
            to_version    = info.latest,
            started_at    = os.date("%Y-%m-%d %H:%M:%S"),
            backup_path   = backup_result.backup_path,
            error_message = "verification failed: main.lua missing",
        })
        return false, "verification failed after update (main.lua missing)"
    end

    local duration_secs = os.time() - start_time

    -- Record successful version history
    DB.add_version_history({
        version       = info.latest,
        tag           = info.tag,
        installed_at  = os.date("%Y-%m-%d %H:%M:%S"),
        backup_path   = backup_result.backup_path,
        update_source = "github",
        duration_secs = duration_secs,
        success       = 1,
    })
    DB.clear_update_state()
    progress:complete_step()

    ------------------------------------------------------------------
    -- Step 7: AUTO COMMIT
    ------------------------------------------------------------------
    progress:start_step("COMMIT")
    DB.save_update_state({
        status       = "committing",
        from_version = info.current,
        to_version   = info.latest,
        started_at   = os.date("%Y-%m-%d %H:%M:%S"),
        backup_path  = backup_result.backup_path,
        download_url = info.url,
    })

    local commit_result = M.auto_commit(info.latest)
    if commit_result.success then
        Logger.info("Changes committed to GitHub: " .. commit_result.message)
    else
        Logger.warn("Auto-commit failed: " .. (commit_result.error or "unknown"))
    end
    progress:complete_step()

    ------------------------------------------------------------------
    -- Cleanup
    ------------------------------------------------------------------
    progress:finish()

    -- Clean up temp files
    Executor.execute("rm -rf '" .. temp_dir .. "'")

    -- Prune old backups
    Snapshot.prune_old_backups(
        FS.expand_path("~/.local/share/lem/backups"),
        config.update.backup_retention,
        config.update.backup_max_age
    )

    print(string.format("Updated to v%s!", info.latest))
    return true
end

--- Show version update history.
function M.show_history()
    local history = DB.list_version_history(20)
    if not history or #history == 0 then
        print("No update history found.")
        return
    end

    print("Update History:")
    print(string.format("%-4s %-12s %-12s %-20s %-8s %s",
        "#", "Version", "From", "Date", "Result", "Source"))
    print(string.rep("-", 70))

    for i, entry in ipairs(history) do
        local result = entry.success == 1 and "OK" or "FAILED"
        print(string.format("%-4d %-12s %-12s %-20s %-8s %s",
            i, entry.version, entry.from_version or "-",
            entry.installed_at or "-", result, entry.update_source or "-"))
    end
end

--- Rollback to a specific version from backup.
-- @param target_version string  version to roll back to
-- @return boolean
function M.rollback(target_version)
    -- Find corresponding backup
    local backups = Snapshot.list_backups()
    local target_backup = nil

    for _, b in ipairs(backups) do
        if b.version == target_version then
            target_backup = b
            break
        end
    end

    if not target_backup then
        print("No backup found for version: " .. tostring(target_version))
        return false
    end

    -- Confirm
    print(string.format("Rolling back to v%s from backup: %s", target_version, target_backup.name))
    io.write("Continue? [y/N] ")
    local answer = io.read("*l")
    if answer ~= "y" and answer ~= "Y" then
        print("Cancelled.")
        return
    end

    -- Execute restore
    local lem_root = _G.LEM_ROOT or os.getenv("HOME") .. "/.local/share/lem"
    local result = Snapshot.restore_backup(target_backup.path, lem_root)
    if result.success then
        -- Record rollback in history
        DB.add_version_history({
            version       = target_version,
            installed_at  = os.date("%Y-%m-%d %H:%M:%S"),
            backup_path   = target_backup.path,
            update_source = "rollback",
            success       = 1,
            notes         = "Rollback",
        })
        print(string.format("Successfully rolled back to v%s", target_version))
        return true
    else
        print("Rollback failed: " .. (result.error_message or "unknown error"))
        return false
    end
end

--- Resume an interrupted update.
-- Delegates to apply_update() which internally detects interrupted state.
-- @return boolean
function M.resume_update()
    local interrupted = Snapshot.detect_interrupted()
    if not interrupted.interrupted then
        print("No interrupted update found.")
        return
    end
    -- apply_update() handles interrupted state internally
    return M.apply_update()
end

--- Show current update status.
function M.show_status()
    local state = DB.load_update_state()
    if not state or state.status == "idle" then
        print("No active update in progress.")
        return
    end

    print("Current update status:")
    print(string.format("  Status: %s", state.status))
    print(string.format("  From: v%s -> v%s", state.from_version or "?", state.to_version or "?"))
    print(string.format("  Started: %s", state.started_at or "?"))
    if state.error_message then
        print(string.format("  Error: %s", state.error_message))
    end
end

--- Print formatted version information.
-- @param remote_info table  result from has_update() or similar
function M.print_version_info(remote_info)
    local current = M.get_current_version()
    if not remote_info then
        print("LEM version: " .. current)
        return
    end

    print(string.format("Current version : v%s", remote_info.current or current))

    if remote_info.latest then
        print(string.format("Latest version  : v%s", remote_info.latest))
        if remote_info.has_update then
            print("")
            print("A new version is available! Run 'lem update --apply' to update.")
        else
            print("")
            print("You are up to date.")
        end
    else
        print("Latest version  : unknown (could not reach GitHub)")
    end
end

--- Auto-commit update changes to GitHub.
-- Checks if LEM_ROOT is a git repository, then stages, commits, and pushes.
-- Respects the auto_commit config flag in config/lem.lua.
-- @param version string  the new version tag (e.g. "1.2.3")
-- @return table { success=bool, message=string|nil, error=string|nil }
function M.auto_commit(version)
    -- Check config flag
    local config = M._load_config()
    if config.update and config.update.auto_commit == false then
        Logger.info("Auto-commit disabled by configuration")
        return {success = true, message = "disabled by config"}
    end

    local lem_root = _G.LEM_ROOT
    if not lem_root then
        return {success = false, error = "LEM_ROOT not set"}
    end

    -- Check if git is available
    local git_available = Executor.execute("git --version")
    if not git_available.success then
        return {success = false, error = "git not available"}
    end

    -- Check if inside a git repository
    local git_check = Executor.execute('git -C "' .. lem_root .. '" rev-parse --is-inside-work-tree')
    if not git_check.success then
        Logger.info("Not a git repository, skipping auto-commit")
        return {success = false, error = "not a git repository"}
    end

    -- Stage all changes
    local add_result = Executor.execute('git -C "' .. lem_root .. '" add -A')
    if not add_result.success then
        return {success = false, error = "git add failed"}
    end

    -- Check if there are changes to commit
    local status_check = Executor.execute('git -C "' .. lem_root .. '" status --porcelain')
    if status_check.success and status_check.output:match("%S") == nil then
        Logger.info("No changes to commit")
        return {success = true, message = "no changes"}
    end

    -- Commit with version message
    local commit_msg = string.format("chore: auto-update to v%s", version)
    local commit_result = Executor.execute(
        string.format('git -C "%s" commit -m "%s"', lem_root, commit_msg)
    )
    if not commit_result.success then
        return {success = false, error = "git commit failed"}
    end

    -- Push to remote
    local push_result = Executor.execute('git -C "' .. lem_root .. '" push')
    if not push_result.success then
        -- Push failure does not affect local commit
        Logger.warn("Git push failed, changes committed locally but not pushed")
        return {success = true, message = commit_msg .. " (push failed)"}
    end

    return {success = true, message = commit_msg}
end

return M
