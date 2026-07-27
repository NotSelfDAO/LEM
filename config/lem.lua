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

    -- System takeover (scan and import existing system packages)
    system_takeover = false,

    -- Self-update configuration
    update = {
        -- Backup retention: keep last N backups
        backup_retention = 3,
        -- Delete backups older than N days
        backup_max_age = 30,
        -- Enable resume download (HTTP Range)
        resume_download = true,
        -- Skip recompilation if native sources unchanged
        skip_unchanged_compile = true,
        -- Download timeout in seconds
        download_timeout = 600,
        -- Auto commit after update (requires git)
        auto_commit = true,
    },
}
