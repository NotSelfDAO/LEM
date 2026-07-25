-- src/core/fs.lua
-- Filesystem utility functions

local M = {}

------------------------------------------------------------------------
-- Path helpers
------------------------------------------------------------------------

--- Expand leading ~ to $HOME / $USERPROFILE.
-- @param path string
-- @return string
function M.expand_path(path)
    if type(path) ~= "string" then return nil, "path must be a string" end
    if path:sub(1, 1) == "~" then
        local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
        return home .. path:sub(2)
    end
    return path
end

------------------------------------------------------------------------
-- Directory operations
------------------------------------------------------------------------

--- Recursively create a directory (like mkdir -p).
-- @param path string
-- @return boolean, string|nil
function M.ensure_dir(path)
    if type(path) ~= "string" then return nil, "path must be a string" end
    path = M.expand_path(path)

    local ok, _, code = os.execute('mkdir -p "' .. path .. '" > /dev/null 2>&1')
    if ok == true or ok == 0 then
        return true
    end
    return nil, "failed to create directory: " .. path
end

------------------------------------------------------------------------
-- File queries
------------------------------------------------------------------------

--- Check whether a file exists and is readable.
-- @param path string
-- @return boolean
function M.file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Read / Write
------------------------------------------------------------------------

--- Read the entire contents of a file.
-- @param path string
-- @return string|nil, string|nil  (content, or nil + error message)
function M.read(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, "cannot open file: " .. path .. " (" .. tostring(err) .. ")"
    end
    local content = f:read("*a")
    f:close()
    return content
end

--- Write content to a file (overwrites).
-- @param path string
-- @param content string
-- @return boolean|nil, string|nil  (true, or nil + error message)
function M.write(path, content)
    local f, err = io.open(path, "w")
    if not f then
        return nil, "cannot write file: " .. path .. " (" .. tostring(err) .. ")"
    end
    f:write(content)
    f:close()
    return true
end

return M
