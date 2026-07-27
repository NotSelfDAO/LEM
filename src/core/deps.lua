-- src/core/deps.lua
-- LEM self-dependency management module
-- Tracks and manages the dependencies that LEM itself requires

local FS = require("core.fs")
local Logger = require("core.logger")

local M = {}

------------------------------------------------------------------------
-- LEM dependency definitions
------------------------------------------------------------------------
M.dependencies = {
    {
        name = "lua5.4",
        type = "required",
        description = "Lua 5.4 interpreter (core runtime)",
        check_cmd = "lua5.4 -v 2>/dev/null || lua -v 2>/dev/null",
        install_hint = "sudo apt install lua5.4",
        category = "runtime",
    },
    {
        name = "libsqlite3-dev",
        type = "optional",
        description = "SQLite3 development headers (C native module)",
        check_cmd = "pkg-config --exists sqlite3 2>/dev/null || dpkg -l libsqlite3-dev 2>/dev/null | grep -q '^ii'",
        install_hint = "sudo apt install libsqlite3-dev",
        category = "build",
    },
    {
        name = "gcc",
        type = "optional",
        description = "GCC compiler (C native modules)",
        check_cmd = "gcc --version >/dev/null 2>&1",
        install_hint = "sudo apt install gcc",
        category = "build",
    },
    {
        name = "make",
        type = "optional",
        description = "Make build tool (C native modules)",
        check_cmd = "make --version >/dev/null 2>&1",
        install_hint = "sudo apt install make",
        category = "build",
    },
    {
        name = "sqlite3",
        type = "required",
        description = "SQLite3 CLI tool (fallback database)",
        check_cmd = "sqlite3 --version >/dev/null 2>&1",
        install_hint = "sudo apt install sqlite3",
        category = "runtime",
    },
    {
        name = "docker",
        type = "optional",
        description = "Docker engine (Docker container backend)",
        check_cmd = "docker --version >/dev/null 2>&1",
        install_hint = "sudo apt install docker.io",
        category = "backend",
    },
    {
        name = "gpg",
        type = "optional",
        description = "GPG tool (source keyring management)",
        check_cmd = "gpg --version >/dev/null 2>&1",
        install_hint = "sudo apt install gnupg",
        category = "source",
    },
}

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

-- Run a shell command and return success boolean.
-- Uses io.popen directly because dependency check commands (lua5.4, gcc,
-- pkg-config, etc.) are NOT in the Executor whitelist.
local function shell_check(cmd)
    local pipe = io.popen(cmd .. " 2>/dev/null")
    if not pipe then return false end
    local ok, _, code = pipe:close()
    return (ok == true) or (code == 0)
end

------------------------------------------------------------------------
-- Check a single dependency
------------------------------------------------------------------------
function M.check_dep(dep)
    return shell_check(dep.check_cmd)
end

------------------------------------------------------------------------
-- Check all dependencies
------------------------------------------------------------------------
function M.check_all()
    local results = {
        required_ok = true,
        required = {},
        optional = {},
        all_ok = true,
    }

    for _, dep in ipairs(M.dependencies) do
        local available = M.check_dep(dep)
        local entry = {
            name = dep.name,
            description = dep.description,
            available = available,
            type = dep.type,
            category = dep.category,
            install_hint = dep.install_hint,
        }

        if dep.type == "required" then
            table.insert(results.required, entry)
            if not available then
                results.required_ok = false
                results.all_ok = false
            end
        else
            table.insert(results.optional, entry)
        end
    end

    return results
end

------------------------------------------------------------------------
-- Print dependency report
------------------------------------------------------------------------
function M.report()
    local results = M.check_all()

    print("LEM Dependency Status")
    print("=====================")
    print("")

    -- Required
    print("Required:")
    for _, dep in ipairs(results.required) do
        local icon = dep.available and "+" or "!"
        print(string.format("  [%s] %-20s %s", icon, dep.name, dep.description))
        if not dep.available then
            print(string.format("       Install: %s", dep.install_hint))
        end
    end

    print("")

    -- Optional
    print("Optional:")
    for _, dep in ipairs(results.optional) do
        local icon = dep.available and "+" or "-"
        print(string.format("  [%s] %-20s %s", icon, dep.name, dep.description))
        if not dep.available then
            print(string.format("       Install: %s", dep.install_hint))
        end
    end

    print("")

    -- Summary
    if results.all_ok then
        print("All required dependencies are satisfied.")
    else
        print("WARNING: Some required dependencies are missing!")
        print("Run 'lem deps install' to install missing dependencies.")
    end

    -- Native module status
    print("")
    print("Native modules:")
    local native_dir = (_G.LEM_ROOT or ".") .. "/native"
    for _, mod in ipairs({"lem_executor", "lem_db", "lem_fs"}) do
        local so_path = native_dir .. "/" .. mod .. ".so"
        if FS.file_exists(so_path) then
            print(string.format("  [+] %-20s loaded", mod .. ".so"))
        else
            print(string.format("  [-] %-20s Lua fallback", mod .. ".so"))
        end
    end

    return results
end

------------------------------------------------------------------------
-- Install missing dependencies (requires sudo)
------------------------------------------------------------------------
function M.install_missing()
    local results = M.check_all()
    local missing = {}

    for _, dep in ipairs(results.required) do
        if not dep.available then
            table.insert(missing, dep)
        end
    end
    for _, dep in ipairs(results.optional) do
        if not dep.available then
            table.insert(missing, dep)
        end
    end

    if #missing == 0 then
        print("All dependencies are already satisfied.")
        return true
    end

    print("Missing dependencies:")
    for _, dep in ipairs(missing) do
        print(string.format("  - %s (%s)", dep.name, dep.description))
    end
    print("")

    -- Detect package manager
    local pkg_cmd = nil
    if shell_check("which apt-get") then
        pkg_cmd = "sudo apt-get install -y"
        os.execute("sudo apt-get update -qq 2>/dev/null")
    elseif shell_check("which dnf") then
        pkg_cmd = "sudo dnf install -y"
    elseif shell_check("which pacman") then
        pkg_cmd = "sudo pacman -S --noconfirm"
    end

    if not pkg_cmd then
        print("Error: No supported package manager found.")
        print("Please install dependencies manually:")
        for _, dep in ipairs(missing) do
            print("  " .. dep.install_hint)
        end
        return false
    end

    -- Build package list
    local packages = {}
    for _, dep in ipairs(missing) do
        table.insert(packages, dep.name)
    end

    local install_cmd = pkg_cmd .. " " .. table.concat(packages, " ")
    print("Running: " .. install_cmd)
    local ok = os.execute(install_cmd)

    if ok == true or ok == 0 then
        print("")
        print("Dependencies installed successfully.")
        M.report()
        return true
    else
        print("")
        print("Error: Installation failed. Try manually:")
        for _, dep in ipairs(missing) do
            print("  " .. dep.install_hint)
        end
        return false
    end
end

------------------------------------------------------------------------
-- Record dependencies into LEM state database
------------------------------------------------------------------------
function M.record_to_db()
    local DB = require("core.db")

    for _, dep in ipairs(M.dependencies) do
        local available = M.check_dep(dep)
        if available then
            DB.add_package("lem-dep:" .. dep.name, "lem-internal", "system")
        end
    end

    Logger.info("LEM dependencies recorded to state database")
end

return M
