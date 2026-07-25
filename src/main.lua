-- LEM - Lua Environment Manager
-- Main entry point

------------------------------------------------------------------------
-- Compute LEM_ROOT from arg[0]
------------------------------------------------------------------------
local script_path = arg[0] or "./src/main.lua"

-- Make path absolute
if not script_path:match("^/") then
    local pwd = io.popen("pwd")
    if pwd then
        local cwd = pwd:read("*l")
        pwd:close()
        if cwd then
            script_path = cwd .. "/" .. script_path
        end
    end
end

-- Resolve any remaining ".." or "." components via a simple normalisation
local function normalise_path(p)
    local parts = {}
    for part in p:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            else
                parts[#parts + 1] = part
            end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

-- Strip trailing filename to get directory, then go up one level from src/
local src_dir = script_path:match("(.+)/[^/]+$") or "."
local LEM_ROOT = normalise_path(src_dir .. "/..")

------------------------------------------------------------------------
-- Path constants
------------------------------------------------------------------------
local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"

LEM_ROOT   = LEM_ROOT
LEM_CONFIG = os.getenv("LEM_CONFIG") or (home .. "/.config/lem")
LEM_DATA   = os.getenv("LEM_DATA")   or (home .. "/.local/share/lem")
LEM_CACHE  = os.getenv("LEM_CACHE")  or (home .. "/.cache/lem")

-- Export as globals so other modules can access them
_G.LEM_ROOT   = LEM_ROOT
_G.LEM_CONFIG = LEM_CONFIG
_G.LEM_DATA   = LEM_DATA
_G.LEM_CACHE  = LEM_CACHE

------------------------------------------------------------------------
-- Configure package paths
------------------------------------------------------------------------
package.path = LEM_ROOT .. "/src/?.lua;"
            .. LEM_ROOT .. "/src/?/init.lua;"
            .. package.path

package.cpath = LEM_ROOT .. "/native/?.so;"
             .. LEM_ROOT .. "/native/?.dll;"
             .. package.cpath

------------------------------------------------------------------------
-- Ensure required directories exist
------------------------------------------------------------------------
local function ensure_dir(path)
    os.execute('mkdir -p "' .. path .. '" > /dev/null 2>&1')
end

ensure_dir(LEM_DATA)
ensure_dir(LEM_CONFIG)
ensure_dir(LEM_CACHE)

------------------------------------------------------------------------
-- Load and run CLI
------------------------------------------------------------------------
local ok, cli = pcall(require, "cli")
if not ok then
    io.stderr:write("FATAL: cannot load cli module: " .. tostring(cli) .. "\n")
    os.exit(1)
end

cli.run(arg)
