-- src/core/takeover.lua
-- Environment takeover: bring system-managed packages under LEM control
-- Two modes: symlink management and reinstall management

local FS             = require("core.fs")
local Executor       = require("core.executor")
local DB             = require("core.db")
local Logger         = require("core.logger")
local PackageManager = require("package.manager")

local M = {}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local MANAGED_DIR = "~/.local/share/lem/managed"

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Resolve the managed directory to an absolute path.
-- @return string  absolute path to managed directory
local function get_managed_dir()
    return FS.expand_path(MANAGED_DIR)
end

--- Ensure the managed directory exists.
-- @return boolean, string|nil
local function ensure_managed_dir()
    local dir = get_managed_dir()
    return FS.ensure_dir(dir)
end

------------------------------------------------------------------------
-- Symlink takeover mode
------------------------------------------------------------------------

--- Take over system packages by creating symlinks in the managed directory.
-- Each binary is linked into ~/.local/share/lem/managed/ and recorded in the
-- database with manager = "lem-symlink".
-- @param package_list table  array of { name, path, version }
-- @return table  { success = {...}, failed = {...} }
function M.symlink_takeover(package_list)
    if not package_list or #package_list == 0 then
        return { success = {}, failed = {} }
    end

    local ok_dir, err_dir = ensure_managed_dir()
    if not ok_dir then
        Logger.error("Cannot create managed directory: " .. tostring(err_dir))
        return { success = {}, failed = package_list }
    end

    local managed_dir = get_managed_dir()
    local results = { success = {}, failed = {} }

    for _, pkg in ipairs(package_list) do
        local pkg_ok, pkg_err = pcall(function()
            -- 1. Verify the binary exists
            if not pkg.path or not FS.file_exists(pkg.path) then
                error("binary not found: " .. tostring(pkg.path))
            end

            local link_path = managed_dir .. "/" .. pkg.name

            -- 2. Remove stale link if it already exists
            if FS.file_exists(link_path) then
                local rm_res = Executor.execute({ "rm", "-f", link_path })
                if not rm_res.success then
                    error("failed to remove existing link: " .. link_path)
                end
            end

            -- 3. Create symlink: managed/<name> -> /usr/bin/<name>
            local ln_res = Executor.execute({ "ln", "-s", pkg.path, link_path })
            if not ln_res.success then
                error("ln -s failed: " .. tostring(ln_res.output))
            end

            -- 4. Record in database
            DB.add_package(pkg.name, "lem-symlink", pkg.version)

            Logger.info("Symlink takeover: " .. pkg.name .. " -> " .. pkg.path)
        end)

        if pkg_ok then
            results.success[#results.success + 1] = pkg
        else
            Logger.warn("Symlink takeover failed for " .. pkg.name .. ": " .. tostring(pkg_err))
            results.failed[#results.failed + 1] = { pkg = pkg, reason = tostring(pkg_err) }
        end
    end

    return results
end

------------------------------------------------------------------------
-- Reinstall takeover mode
------------------------------------------------------------------------

--- Take over system packages by recording them in the LEM database and
-- triggering a reinstall through the unified package manager layer.
-- The actual backend (apt, docker, etc.) is resolved automatically via
-- PackageManager, so this module stays decoupled from any specific backend.
-- @param package_list table  array of { name, manager, version }
-- @return table  { success = {...}, failed = {...} }
function M.reinstall_takeover(package_list)
    if not package_list or #package_list == 0 then
        return { success = {}, failed = {} }
    end

    local results = { success = {}, failed = {} }

    for _, pkg in ipairs(package_list) do
        local pkg_ok, pkg_err = pcall(function()
            local manager = pkg.manager or "apt"

            -- 1. Record in LEM database first
            DB.add_package(pkg.name, manager, pkg.version)
            Logger.info("Reinstall takeover recorded: " .. pkg.name .. " (manager=" .. manager .. ")")

            -- 2. Reinstall through the unified package manager layer
            --    PackageManager routes to the correct backend automatically.
            local install_ok, install_err = PackageManager.install({
                name    = pkg.name,
                manager = manager,
            })
            if not install_ok then
                error("reinstall failed: " .. tostring(install_err))
            end

            Logger.info("Reinstall takeover complete: " .. pkg.name)
        end)

        if pkg_ok then
            results.success[#results.success + 1] = pkg
        else
            Logger.warn("Reinstall takeover failed for " .. pkg.name .. ": " .. tostring(pkg_err))
            results.failed[#results.failed + 1] = { pkg = pkg, reason = tostring(pkg_err) }
        end
    end

    return results
end

------------------------------------------------------------------------
-- Cleanup (called by lem remove)
------------------------------------------------------------------------

--- Remove the symlink for a package and clean up its database record.
-- @param package_name string
-- @return boolean, string|nil
function M.cleanup_symlink(package_name)
    if not package_name or package_name == "" then
        return nil, "package_name is required"
    end

    local ok, err = pcall(function()
        local managed_dir = get_managed_dir()
        local link_path = managed_dir .. "/" .. package_name

        -- 1. Remove the symlink file
        if FS.file_exists(link_path) then
            local rm_res = Executor.execute({ "rm", "-f", link_path })
            if not rm_res.success then
                error("failed to remove symlink: " .. link_path)
            end
            Logger.info("Removed symlink: " .. link_path)
        else
            Logger.warn("Symlink not found, skipping removal: " .. link_path)
        end

        -- 2. Remove database record
        DB.remove_package(package_name)
        Logger.info("Removed database record for: " .. package_name)
    end)

    if not ok then
        Logger.error("cleanup_symlink failed for " .. package_name .. ": " .. tostring(err))
        return nil, tostring(err)
    end

    return true
end

------------------------------------------------------------------------
-- Listing
------------------------------------------------------------------------

--- List all packages currently managed via symlinks.
-- Scans the managed directory for symlinks and returns their details.
-- @return table  array of { name, target, link }
function M.list_symlinks()
    local managed_dir = get_managed_dir()

    -- If the directory doesn't exist yet, nothing to list
    if not FS.file_exists(managed_dir) then
        return {}
    end

    local result = {}
    local scan_ok, scan_err = pcall(function()
        -- Use ls -la to get symlink targets; parse "name -> target" patterns
        local ls_res = Executor.execute({ "ls", "-la", managed_dir })
        if not ls_res.success then
            Logger.warn("Failed to scan managed directory: " .. tostring(ls_res.output))
            return
        end

        for line in ls_res.output:gmatch("[^\r\n]+") do
            -- Symlink lines from ls -la look like:
            --   lrwxrwxrwx 1 user group 10 Jan  1 00:00 name -> /target/path
            -- Match: permissions starting with 'l', then eventually "name -> target"
            if line:sub(1, 1) == "l" then
                local name, target = line:match("%s(%S+)%s+%-%>%s+(%S+)%s*$")
                if name and target then
                    -- Strip any trailing slash or whitespace from name
                    name = name:match("^([^/]+)")
                    if name and name ~= "." and name ~= ".." then
                        result[#result + 1] = {
                            name   = name,
                            target = target,
                            link   = MANAGED_DIR .. "/" .. name,
                        }
                    end
                end
            end
        end
    end)

    if not scan_ok then
        Logger.error("list_symlinks error: " .. tostring(scan_err))
    end

    return result
end

------------------------------------------------------------------------
-- Reporting
------------------------------------------------------------------------

--- Print a formatted takeover result report.
-- @param results table  { success = {...}, failed = {...} }
-- @param mode string    "symlink" or "reinstall"
function M.print_report(results, mode)
    mode = mode or "unknown"

    print("")
    print("=== LEM Takeover Report (mode: " .. mode .. ") ===")
    print("")

    -- Successes
    local success_count = results.success and #results.success or 0
    if success_count > 0 then
        print("Successfully taken over (" .. success_count .. "):")
        for _, pkg in ipairs(results.success) do
            local detail = pkg.name or "(unknown)"
            if pkg.version then
                detail = detail .. " (" .. pkg.version .. ")"
            end
            print("  [OK]   " .. detail)
        end
    else
        print("No packages were taken over.")
    end

    print("")

    -- Failures
    local failed_count = results.failed and #results.failed or 0
    if failed_count > 0 then
        print("Failed (" .. failed_count .. "):")
        for _, entry in ipairs(results.failed) do
            local pkg = entry.pkg or entry
            local detail = pkg.name or "(unknown)"
            local reason = entry.reason or "unknown error"
            print("  [FAIL] " .. detail .. " — " .. reason)
        end
    end

    print("")
    print("Total: " .. success_count .. " succeeded, " .. failed_count .. " failed.")
    print("")
end

return M
