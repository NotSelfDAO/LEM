-- src/core/logger.lua
-- Logging system with file and stderr output

local M = {}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local LEVELS = { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 }
local LEVEL_NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }

local current_level = LEVELS.INFO
local log_file_path = nil
local log_file_handle = nil

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

local function get_timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function write_to_file(msg)
    if not log_file_handle then return end
    log_file_handle:write(msg .. "\n")
    log_file_handle:flush()
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Initialise the logger.
-- @param data_dir string  directory where log file will be created
-- @param level string|nil "DEBUG", "INFO", "WARN", "ERROR" (default INFO)
function M.init(data_dir, level)
    if level and LEVELS[level] then
        current_level = LEVELS[level]
    end

    log_file_path = data_dir .. "/lem.log"
    -- Open in append mode
    log_file_handle = io.open(log_file_path, "a")
end

--- Log a message at the given level.
-- @param level number  one of LEVELS constants
-- @param msg string
local function log(level, msg)
    if level < current_level then return end

    local name = LEVEL_NAMES[level + 1] or "UNKNOWN"
    local line = string.format("[%s] [%s] %s", get_timestamp(), name, msg)

    -- Always write to stderr
    io.stderr:write(line .. "\n")

    -- Also write to file if available
    write_to_file(line)
end

function M.debug(msg) log(LEVELS.DEBUG, msg) end
function M.info(msg)  log(LEVELS.INFO,  msg) end
function M.warn(msg)  log(LEVELS.WARN,  msg) end
function M.error(msg) log(LEVELS.ERROR, msg) end

--- Set the minimum log level at runtime.
-- @param level string  "DEBUG", "INFO", "WARN", or "ERROR"
function M.set_level(level)
    if LEVELS[level] then
        current_level = LEVELS[level]
    end
end

--- Close the log file handle (call on shutdown).
function M.close()
    if log_file_handle then
        log_file_handle:close()
        log_file_handle = nil
    end
end

return M
