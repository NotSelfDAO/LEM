-- src/core/executor.lua
-- Command execution with whitelist validation and argument sanitisation

local M = {}

------------------------------------------------------------------------
-- Try to load C native module
------------------------------------------------------------------------
local ok, native_exec = pcall(require, "native.lem_executor")
if not ok then native_exec = nil end

------------------------------------------------------------------------
-- Command whitelist
------------------------------------------------------------------------
local ALLOWED_COMMANDS = {
    "apt", "apt-get", "dpkg", "apt-cache", "apt-key",
    "systemctl", "docker", "git", "wget", "curl",
    "gpg", "mkdir", "cp", "mv", "rm", "ls", "cat",
    "chmod", "chown", "touch", "ln", "tar", "gzip",
    "which", "find", "grep", "head", "tail", "wc",
    "sudo",
}

local allowed_set = {}
for _, cmd in ipairs(ALLOWED_COMMANDS) do
    allowed_set[cmd] = true
end

------------------------------------------------------------------------
-- Argument sanitisation
------------------------------------------------------------------------

--- Check whether arg is a safe string (no shell metacharacters).
-- @param arg string
-- @return string|nil, string|nil  (sanitised arg, or nil + error message)
local function sanitize(arg)
    if type(arg) ~= "string" then
        return nil, "argument must be string"
    end
    if arg:match("[;|&`$]") then
        return nil, "argument contains forbidden shell metacharacters"
    end
    return arg
end

------------------------------------------------------------------------
-- Command validation
------------------------------------------------------------------------

--- Extract the base command name from a command string or table.
-- @param cmd string|table
-- @return string base command name
local function get_base_command(cmd)
    local cmd_str
    if type(cmd) == "table" then
        cmd_str = cmd[1] or ""
    elseif type(cmd) == "string" then
        cmd_str = cmd:match("^(%S+)") or cmd
    else
        return nil
    end
    -- Take only the filename part (strip any path prefix)
    return cmd_str:match("[^/]+$") or cmd_str
end

--- Validate that the command is in the whitelist.
-- @param cmd string|table
-- @return boolean, string|nil
local function validate_command(cmd)
    local base = get_base_command(cmd)
    if not base then
        return false, "invalid command type"
    end
    if not allowed_set[base] then
        return false, "command not in whitelist: " .. base
    end
    return true
end

------------------------------------------------------------------------
-- Build command string
------------------------------------------------------------------------

--- Convert cmd to a shell-safe string.
-- @param cmd string|table
-- @return string|nil, string|nil
local function build_command_string(cmd)
    if type(cmd) == "string" then
        return cmd
    elseif type(cmd) == "table" then
        local parts = {}
        for i, arg in ipairs(cmd) do
            local safe, err = sanitize(arg)
            if not safe then return nil, err end
            -- Quote arguments that contain spaces
            if safe:match("%s") then
                safe = "'" .. safe .. "'"
            end
            parts[i] = safe
        end
        return table.concat(parts, " ")
    else
        return nil, "cmd must be string or table"
    end
end

------------------------------------------------------------------------
-- Execute via io.popen (fallback)
------------------------------------------------------------------------

local function execute_popen(cmd_str, opts)
    opts = opts or {}

    local full_cmd = cmd_str
    -- Redirect stderr to stdout so we capture both
    full_cmd = full_cmd .. " 2>&1"

    if opts.cwd then
        full_cmd = "cd '" .. opts.cwd .. "' && " .. full_cmd
    end

    local pipe = io.popen(full_cmd)
    if not pipe then
        return { success = false, output = "failed to open pipe", exit_code = -1 }
    end

    local output = pipe:read("*a") or ""
    local ok_flag, exit_reason, exit_code = pipe:close()

    -- io.popen close returns: ok, "exit", code  OR  nil, "exit", code
    local code = exit_code or 0
    local success = (ok_flag == true) or (exit_reason == "exit" and code == 0)

    return {
        success    = success,
        output     = output,
        exit_code  = code,
    }
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Execute a whitelisted command.
-- @param cmd string|table  command to execute
-- @param opts table|nil    { timeout:number, cwd:string }
-- @return table { success=bool, output=string, exit_code=number }
function M.execute(cmd, opts)
    opts = opts or {}

    -- Validate command against whitelist
    local valid, err = validate_command(cmd)
    if not valid then
        return { success = false, output = err, exit_code = -1 }
    end

    -- Build command string (sanitises table args)
    local cmd_str, build_err = build_command_string(cmd)
    if not cmd_str then
        return { success = false, output = build_err, exit_code = -1 }
    end

    -- Prefer native C module if available
    if native_exec then
        local cmd_table
        if type(cmd) == "string" then
            cmd_table = {}
            for token in cmd:gmatch("%S+") do
                cmd_table[#cmd_table + 1] = token
            end
        else
            cmd_table = cmd
        end
        local ok_result, result = pcall(native_exec.exec, cmd_table, opts)
        if ok_result then
            return result
        end
        -- fallback to io.popen if native call fails
    end

    -- Fallback to io.popen
    return execute_popen(cmd_str, opts)
end

--- Execute a command with sudo prefix.
-- @param cmd string|table
-- @param opts table|nil
-- @return table { success=bool, output=string, exit_code=number }
function M.execute_sudo(cmd, opts)
    if type(cmd) == "table" then
        local new_cmd = { "sudo" }
        for i, v in ipairs(cmd) do
            new_cmd[i + 1] = v
        end
        return M.execute(new_cmd, opts)
    elseif type(cmd) == "string" then
        return M.execute("sudo " .. cmd, opts)
    else
        return { success = false, output = "invalid command type", exit_code = -1 }
    end
end

return M
