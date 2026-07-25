-- config/lem.lua
-- Global configuration file for LEM

return {
    -- Default package manager
    default_manager = "apt",

    -- Log level: "DEBUG", "INFO", "WARN", "ERROR"
    log_level = "INFO",

    -- Auto-confirm installations (skip y/n prompts)
    auto_confirm = false,

    -- Timeout in seconds
    timeout = 300,
}
