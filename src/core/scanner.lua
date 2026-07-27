-- src/core/scanner.lua
-- System scanner: detect installed packages, containers, binaries, env vars

local Executor = require("core.executor")
local Logger   = require("core.logger")

local M = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Split a multi-line string into a table of non-empty lines.
-- @param s string
-- @return table
local function lines(s)
    local result = {}
    if not s or s == "" then return result end
    for line in s:gmatch("[^\r\n]+") do
        if line ~= "" then
            result[#result + 1] = line
        end
    end
    return result
end

--- Trim leading/trailing whitespace.
-- @param s string
-- @return string
local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

------------------------------------------------------------------------
-- scan_dpkg — scan dpkg installed packages
------------------------------------------------------------------------

--- Scan packages installed via dpkg/apt.
-- Executes `dpkg --get-selections` and parses the output.
-- May require sudo on some systems.
-- @return table  array of { name=string, status=string }
function M.scan_dpkg()
    local ok_result, result = pcall(function()
        local res = Executor.execute("dpkg --get-selections")
        if not res.success then
            Logger.warn("dpkg scan failed (exit " .. tostring(res.exit_code)
                        .. "): " .. trim(res.output))
            print("[scanner] dpkg 扫描失败，可能需要 sudo 权限或 dpkg 不可用")
            return {}
        end

        local packages = {}
        for _, line in ipairs(lines(res.output)) do
            -- Format: "package_name\t\tstatus"
            local name, status = line:match("^(%S+)%s+(%S+)$")
            if name and status then
                packages[#packages + 1] = {
                    name   = name,
                    status = status,
                }
            end
        end

        Logger.info("dpkg scan found " .. #packages .. " packages")
        return packages
    end)

    if not ok_result then
        Logger.error("dpkg scan error: " .. tostring(result))
        return {}
    end
    return result
end

------------------------------------------------------------------------
-- scan_docker — scan docker containers
------------------------------------------------------------------------

--- Scan Docker containers (running and stopped).
-- Executes `docker ps -a --format`.
-- @return table  array of { name=string, image=string, status=string }
function M.scan_docker()
    local ok_result, result = pcall(function()
        -- Check if docker is available first
        local check = Executor.execute("docker info")
        if not check.success then
            Logger.debug("docker not available: " .. trim(check.output))
            return {}
        end

        local res = Executor.execute("docker ps -a --no-trunc")
        if not res.success then
            Logger.warn("docker scan failed (exit " .. tostring(res.exit_code)
                        .. "): " .. trim(res.output))
            print("[scanner] Docker 扫描失败，请确认 Docker 已安装并运行")
            return {}
        end

        local containers = {}
        local all_lines = lines(res.output)
        if #all_lines == 0 then
            return containers
        end

        -- Parse column positions from the header line
        -- Default: CONTAINER ID  IMAGE  COMMAND  CREATED  STATUS  PORTS  NAMES
        local header = all_lines[1]
        local col_start = {}
        for pos, col_name in header:gmatch("()(%S+)") do
            col_start[col_name] = pos
        end

        for i = 2, #all_lines do
            local line = all_lines[i]
            -- Extract fields by column positions
            local function extract_col(name)
                local s = col_start[name]
                if not s then return nil end
                -- Find next column start to determine end
                local next_s = #line + 1
                for other_name, other_pos in pairs(col_start) do
                    if other_pos > s and other_pos < next_s then
                        next_s = other_pos
                    end
                end
                return trim(line:sub(s, next_s - 1))
            end

            local name   = extract_col("NAMES")
            local image  = extract_col("IMAGE")
            local status = extract_col("STATUS")
            if name and image then
                containers[#containers + 1] = {
                    name   = name,
                    image  = image,
                    status = status or "unknown",
                }
            end
        end

        Logger.info("docker scan found " .. #containers .. " containers")
        return containers
    end)

    if not ok_result then
        Logger.error("docker scan error: " .. tostring(result))
        return {}
    end
    return result
end

------------------------------------------------------------------------
-- scan_binaries — scan common development tools
------------------------------------------------------------------------

-- List of common binaries to check
local COMMON_BINARIES = {
    "git", "python3", "python", "node", "npm", "npx",
    "java", "javac", "go", "rustc", "cargo",
    "gcc", "g++", "make", "cmake",
    "docker", "kubectl",
    "vim", "nano", "curl", "wget",
    "lua", "luajit",
    "ruby", "perl", "php",
    "sqlite3", "mysql", "psql",
    "ssh", "scp", "rsync",
}

--- Try to get the version of a binary using whitelisted commands.
-- Uses dpkg -s or reads version files to avoid whitelist issues.
-- @param name string  binary name
-- @return string|nil  version string or nil
local function get_version(name)
    -- Strategy 1: use dpkg -s to query package version (dpkg is whitelisted)
    local res = Executor.execute({ "dpkg", "-s", name })
    if res.success and res.output then
        for _, line in ipairs(lines(res.output)) do
            local ver = line:match("^Version:%s*(.+)$")
            if ver then return ver end
        end
    end

    -- Strategy 2: try reading a version file from standard doc path
    local paths = {
        "/usr/share/doc/" .. name .. "/changelog.Debian.gz",
        "/usr/share/doc/" .. name .. "/changelog.gz",
    }
    for _, path in ipairs(paths) do
        local res2 = Executor.execute({ "cat", path })
        if res2.success and res2.output and res2.output ~= "" then
            -- changelog is gzipped; try to extract version from filename
            -- or first line if readable
            local first = trim(lines(res2.output)[1] or "")
            if first ~= "" then return first end
        end
    end

    return nil
end

--- Scan common development binaries on the system.
-- Uses `which` to locate and `--version` to get version info.
-- @return table  array of { name=string, path=string, version=string|nil }
function M.scan_binaries()
    local ok_result, result = pcall(function()
        local found = {}

        for _, bin in ipairs(COMMON_BINARIES) do
            local ok, entry = pcall(function()
                local res = Executor.execute({ "which", bin })
                if res.success and res.output and trim(res.output) ~= "" then
                    local path = trim(lines(res.output)[1] or "")
                    if path ~= "" then
                        local version = get_version(bin)
                        return {
                            name    = bin,
                            path    = path,
                            version = version,
                        }
                    end
                end
                return nil
            end)

            if ok and entry then
                found[#found + 1] = entry
            end
        end

        Logger.info("binary scan found " .. #found .. " tools")
        return found
    end)

    if not ok_result then
        Logger.error("binary scan error: " .. tostring(result))
        return {}
    end
    return result
end

------------------------------------------------------------------------
-- scan_env_vars — scan environment variables
------------------------------------------------------------------------

-- Key environment variables to scan
local KEY_ENV_VARS = {
    "PATH", "HOME", "USER", "SHELL",
    "LANG", "LC_ALL", "LC_CTYPE",
    "JAVA_HOME", "GOPATH", "GOROOT",
    "NODE_PATH", "PYTHONPATH", "CARGO_HOME",
    "RUSTUP_HOME", "NVM_DIR",
    "XDG_CONFIG_HOME", "XDG_DATA_HOME",
    "EDITOR", "VISUAL", "PAGER",
    "TERM", "DISPLAY", "WAYLAND_DISPLAY",
}

--- Scan key environment variables from the current shell.
-- @return table  array of { name=string, value=string }
function M.scan_env_vars()
    local ok_result, result = pcall(function()
        local vars = {}

        for _, var in ipairs(KEY_ENV_VARS) do
            local ok, entry = pcall(function()
                -- Use printenv to get variable value
                local res = Executor.execute({ "grep", "^" .. var .. "=", "/proc/self/environ" })
                -- Fallback: environ file may not be readable; use shell expansion
                -- Since we can't use shell metacharacters, use a different approach
                if not res.success or trim(res.output) == "" then
                    return nil
                end
                local raw = trim(res.output)
                -- Strip the "VAR=" prefix
                local value = raw:match("^" .. var .. "=(.*)$") or raw
                return {
                    name  = var,
                    value = value,
                }
            end)

            if ok and entry then
                vars[#vars + 1] = entry
            end
        end

        -- Fallback: if /proc/self/environ didn't work, try printenv for each
        if #vars == 0 then
            for _, var in ipairs(KEY_ENV_VARS) do
                local ok, entry = pcall(function()
                    -- Use grep on the environment via a safe approach
                    -- We read from /proc/self/environ with null-byte separated values
                    local res = Executor.execute({ "cat", "/proc/self/environ" })
                    if not res.success then return nil end

                    -- environ is null-byte separated; split by null
                    for chunk in res.output:gmatch("[^%z]+") do
                        local name, value = chunk:match("^(%w+)=(.*)$")
                        if name == var then
                            return { name = var, value = value }
                        end
                    end
                    return nil
                end)

                if ok and entry then
                    vars[#vars + 1] = entry
                end
            end
        end

        Logger.info("env scan found " .. #vars .. " variables")
        return vars
    end)

    if not ok_result then
        Logger.error("env scan error: " .. tostring(result))
        return {}
    end
    return result
end

------------------------------------------------------------------------
-- scan_all — full system scan
------------------------------------------------------------------------

--- Execute a complete system scan.
-- Calls all individual scan functions and aggregates results.
-- Individual failures do not affect other scans.
-- @return table  comprehensive scan results
function M.scan_all()
    Logger.info("starting full system scan")
    local start_time = os.clock()

    local dpkg_packages     = M.scan_dpkg()
    local docker_containers = M.scan_docker()
    local binaries          = M.scan_binaries()
    local env_vars          = M.scan_env_vars()

    local elapsed = os.clock() - start_time

    local results = {
        dpkg_packages     = dpkg_packages,
        docker_containers = docker_containers,
        binaries          = binaries,
        env_vars          = env_vars,
        scan_time         = os.date("%Y-%m-%d %H:%M:%S"),
        elapsed           = elapsed,
        summary = {
            dpkg_count    = #dpkg_packages,
            docker_count  = #docker_containers,
            binary_count  = #binaries,
            env_count     = #env_vars,
        },
    }

    Logger.info("full scan completed in " .. string.format("%.2f", elapsed) .. "s")
    return results
end

------------------------------------------------------------------------
-- print_report — formatted scan report
------------------------------------------------------------------------

--- Print a formatted scan report to stdout.
-- @param results table  output from scan_all() or individual scans
function M.print_report(results)
    if not results then
        print("[scanner] 无扫描结果可显示")
        return
    end

    print("========================================")
    print("  LEM 系统扫描报告")
    print("  扫描时间: " .. (results.scan_time or os.date()))
    if results.elapsed then
        print(string.format("  耗时: %.2f 秒", results.elapsed))
    end
    print("========================================")

    -- Summary
    local summary = results.summary
    if summary then
        print("")
        print("--- 概览 ---")
        print(string.format("  dpkg 软件包:   %d 个", summary.dpkg_count or 0))
        print(string.format("  Docker 容器:   %d 个", summary.docker_count or 0))
        print(string.format("  开发工具:      %d 个", summary.binary_count or 0))
        print(string.format("  环境变量:      %d 个", summary.env_count or 0))
    end

    -- dpkg packages
    local dpkg = results.dpkg_packages
    if dpkg and #dpkg > 0 then
        print("")
        print("--- dpkg 已安装软件包 (" .. #dpkg .. ") ---")
        local display_count = math.min(#dpkg, 50)
        for i = 1, display_count do
            print(string.format("  %-40s %s", dpkg[i].name, dpkg[i].status or ""))
        end
        if #dpkg > 50 then
            print(string.format("  ... 还有 %d 个软件包未显示", #dpkg - 50))
        end
    end

    -- Docker containers
    local docker = results.docker_containers
    if docker and #docker > 0 then
        print("")
        print("--- Docker 容器 (" .. #docker .. ") ---")
        for _, c in ipairs(docker) do
            print(string.format("  %-30s %-30s %s", c.name, c.image, c.status))
        end
    end

    -- Binaries
    local bins = results.binaries
    if bins and #bins > 0 then
        print("")
        print("--- 开发工具 (" .. #bins .. ") ---")
        for _, b in ipairs(bins) do
            local ver = b.version and (" (" .. b.version .. ")") or ""
            print(string.format("  %-15s %-30s%s", b.name, b.path, ver))
        end
    end

    -- Environment variables
    local envs = results.env_vars
    if envs and #envs > 0 then
        print("")
        print("--- 环境变量 (" .. #envs .. ") ---")
        for _, e in ipairs(envs) do
            local val = e.value
            -- Truncate very long values (e.g. PATH)
            if #val > 80 then
                val = val:sub(1, 77) .. "..."
            end
            print(string.format("  %-20s = %s", e.name, val))
        end
    end

    print("")
    print("========================================")
    print("  扫描完成")
    print("========================================")
end

return M
