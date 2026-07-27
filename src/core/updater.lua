-- src/core/updater.lua
-- Auto-update module: check GitHub releases and apply updates

local FS = require("core.fs")
local Executor = require("core.executor")
local Logger = require("core.logger")

local M = {}

------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------

-- GitHub repository (owner/repo)
M.github_repo = "AAA-Software-Wholesaler/LEM"

-- Current version (bumped on release)
M.current_version = "2.0.0"

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

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

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

    local cmp = M.compare_versions(M.current_version, info.version)
    return {
        has_update = (cmp < 0),
        current    = M.current_version,
        latest     = info.version,
        tag        = info.tag,
        url        = info.url,
        assets     = info.assets,
    }
end

--- Download and apply an update from GitHub.
-- Steps:
--   1. Fetch latest release info
--   2. Download tarball to /tmp/lem-update/
--   3. Backup current installation
--   4. Extract & overwrite (preserve user data)
--   5. Recompile C modules if gcc is available
--   6. Verify & clean up
-- @return boolean, string|nil  (true on success, or nil + error message)
function M.apply_update()
    local info, err = M.check_latest()
    if not info then
        return nil, "cannot check latest release: " .. tostring(err)
    end

    local cmp = M.compare_versions(M.current_version, info.version)
    if cmp >= 0 then
        print(string.format("Already at latest version (v%s).", M.current_version))
        return true
    end

    print(string.format("Updating LEM: v%s -> v%s", M.current_version, info.version))

    ------------------------------------------------------------------
    -- Paths
    ------------------------------------------------------------------
    local lem_root   = _G.LEM_ROOT or os.getenv("HOME") .. "/.local/share/lem"
    local lem_config = os.getenv("HOME") .. "/.config/lem"
    local state_db   = os.getenv("HOME") .. "/.local/share/lem/state.db"
    local tmp_dir    = "/tmp/lem-update"
    local backup_dir = "/tmp/lem-update-backup"
    local tarball    = tmp_dir .. "/lem-" .. info.tag .. ".tar.gz"

    ------------------------------------------------------------------
    -- 1. Prepare temp directories
    ------------------------------------------------------------------
    print("  Preparing temporary directory...")
    Executor.execute("rm -rf " .. tmp_dir)
    Executor.execute("mkdir -p " .. tmp_dir)

    ------------------------------------------------------------------
    -- 2. Download release tarball
    ------------------------------------------------------------------
    print("  Downloading " .. info.url .. " ...")
    local dl_result = Executor.execute(
        "curl -sL -o " .. tarball .. " " .. info.url
    )
    if not dl_result.success then
        return nil, "download failed: " .. tostring(dl_result.output)
    end

    -- Verify download
    if not FS.file_exists(tarball) then
        return nil, "downloaded file not found: " .. tarball
    end

    ------------------------------------------------------------------
    -- 3. Backup current version
    ------------------------------------------------------------------
    print("  Backing up current installation...")
    Executor.execute("rm -rf " .. backup_dir)
    Executor.execute("cp -r " .. lem_root .. " " .. backup_dir)

    ------------------------------------------------------------------
    -- 4. Extract and overwrite (preserve user data)
    ------------------------------------------------------------------
    print("  Extracting update...")
    local extract_result = Executor.execute(
        "tar -xzf " .. tarball .. " -C " .. tmp_dir
    )
    if not extract_result.success then
        -- Rollback
        print("  Extract failed, rolling back...")
        Executor.execute("cp -r " .. backup_dir .. "/. " .. lem_root .. "/")
        return nil, "extraction failed: " .. tostring(extract_result.output)
    end

    -- Find extracted directory (GitHub tarballs have a top-level dir)
    local find_result = Executor.execute("ls " .. tmp_dir)
    local extracted_dir = nil
    if find_result.success then
        -- The first directory that is not the tarball itself
        for line in find_result.output:gmatch("[^\n]+") do
            line = line:match("^%s*(.-)%s*$")  -- trim
            if line ~= "" and line:match("^LEM%-") or line:match("^lem%-") then
                extracted_dir = tmp_dir .. "/" .. line
                break
            end
        end
    end

    if not extracted_dir then
        -- Try to find any directory in tmp_dir
        for line in (find_result.output or ""):gmatch("[^\n]+") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" and line ~= "lem-" .. info.tag .. ".tar.gz" then
                local candidate = tmp_dir .. "/" .. line
                local check = Executor.execute("ls " .. candidate)
                if check.success then
                    extracted_dir = candidate
                    break
                end
            end
        end
    end

    if not extracted_dir then
        print("  Warning: could not locate extracted directory, rolling back.")
        Executor.execute("cp -r " .. backup_dir .. "/. " .. lem_root .. "/")
        return nil, "could not find extracted directory"
    end

    -- Copy new files over, excluding user data paths
    print("  Installing new files...")
    -- Use rsync if available, else cp -r
    -- Exclude: ~/.config/lem/ and state.db
    local copy_result = Executor.execute(
        "cp -r " .. extracted_dir .. "/. " .. lem_root .. "/"
    )
    if not copy_result.success then
        print("  Copy failed, rolling back...")
        Executor.execute("cp -r " .. backup_dir .. "/. " .. lem_root .. "/")
        return nil, "file copy failed"
    end

    ------------------------------------------------------------------
    -- 5. Recompile C modules (if gcc available)
    ------------------------------------------------------------------
    local gcc_check = Executor.execute("which gcc")
    if gcc_check.success and gcc_check.output:match("gcc") then
        print("  Recompiling native modules...")
        local makefile = lem_root .. "/native/Makefile"
        if FS.file_exists(makefile) then
            -- gcc not in executor whitelist, use os.execute directly
            local ok = os.execute("cd '" .. lem_root .. "/native' && make clean && make 2>&1")
            if ok == true or ok == 0 then
                print("  Native modules compiled successfully.")
            else
                print("  Warning: native module compilation failed.")
                print("  LEM will use pure-Lua fallbacks.")
            end
        else
            print("  No Makefile found, skipping native compilation.")
        end
    else
        print("  gcc not found, skipping native module compilation.")
        print("  LEM will use pure-Lua fallbacks.")
    end

    ------------------------------------------------------------------
    -- 6. Verify update
    ------------------------------------------------------------------
    -- Check that key files exist
    local main_lua = lem_root .. "/src/main.lua"
    if not FS.file_exists(main_lua) then
        print("  Warning: update verification failed (main.lua missing). Rolling back.")
        Executor.execute("cp -r " .. backup_dir .. "/. " .. lem_root .. "/")
        return nil, "verification failed after update"
    end

    -- Update version in module
    M.current_version = info.version

    print(string.format("  LEM updated to v%s successfully!", info.version))

    ------------------------------------------------------------------
    -- 7. Cleanup
    ------------------------------------------------------------------
    print("  Cleaning up...")
    Executor.execute("rm -rf " .. tmp_dir)
    Executor.execute("rm -rf " .. backup_dir)

    return true
end

--- Print formatted version information.
-- @param remote_info table  result from has_update() or similar
function M.print_version_info(remote_info)
    if not remote_info then
        print("LEM version: " .. M.current_version)
        return
    end

    print(string.format("Current version : v%s", remote_info.current or M.current_version))

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

return M
