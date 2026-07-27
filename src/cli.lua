-- src/cli.lua
-- CLI command parsing and routing

local Executor = require("core.executor")
local Logger   = require("core.logger")
local DB       = require("core.db")
local FS       = require("core.fs")

local M = {}

local VERSION = "1.0.0"

------------------------------------------------------------------------
-- Built-in source configuration
------------------------------------------------------------------------
local builtin_sources = {
    docker = {
        name = "docker",
        url = "https://download.docker.com/linux/ubuntu",
        distribution = "noble",
        component = "stable",
        key_url = "https://download.docker.com/linux/ubuntu/gpg",
    },
    vscode = {
        name = "vscode",
        url = "https://packages.microsoft.com/repos/code",
        distribution = "stable",
        component = "main",
        key_url = "https://packages.microsoft.com/keys/microsoft.asc",
    },
    nodejs = {
        name = "nodejs",
        url = "https://deb.nodesource.com/node_20.x",
        distribution = "nodistro",
        component = "main",
        key_url = "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key",
    },
}

local function load_source_config(name)
    -- Check built-in sources first
    if builtin_sources[name] then
        return builtin_sources[name]
    end
    -- Then check user custom config (LEM_CONFIG/sources/name.lua)
    local path = _G.LEM_CONFIG .. "/sources/" .. name .. ".lua"
    if FS.file_exists(path) then
        local ok, config = pcall(dofile, path)
        if ok and type(config) == "table" then
            return config
        end
    end
    return nil
end

------------------------------------------------------------------------
-- Command registry
------------------------------------------------------------------------
local commands = {}

function commands.install(args, flags)
    if #args == 0 then
        io.stderr:write("Usage: lem install <package1> [package2] ...\n")
        return
    end

    local PackageManager = require("package.manager")
    local manager = flags.manager or "apt"

    for _, pkg_name in ipairs(args) do
        local pkg = { name = pkg_name, manager = manager }

        io.write("Installing " .. pkg_name .. " ...\n")
        local ok, err = PackageManager.install(pkg)

        if ok then
            io.write(pkg_name .. " installed successfully.\n")
        else
            io.stderr:write("Failed to install " .. pkg_name .. ": " .. tostring(err) .. "\n")
        end
    end
end

function commands.remove(args, flags)
    if #args == 0 then
        io.stderr:write("Usage: lem remove <package1> [package2] ...\n")
        return
    end

    local PackageManager = require("package.manager")

    for _, pkg_name in ipairs(args) do
        -- Look up the manager from DB, or use default
        local record = DB.get_package(pkg_name)
        local manager = (record and record.manager) or flags.manager or "apt"
        local pkg = { name = pkg_name, manager = manager }

        io.write("Removing " .. pkg_name .. " ...\n")
        local ok, err = PackageManager.remove(pkg)

        if ok then
            io.write(pkg_name .. " removed successfully.\n")
        else
            io.stderr:write("Failed to remove " .. pkg_name .. ": " .. tostring(err) .. "\n")
        end
    end
end

function commands.status(args, flags)
    if #args > 0 then
        -- Show status of a specific package
        for _, pkg_name in ipairs(args) do
            local record = DB.get_package(pkg_name)
            if record then
                io.write(string.format(
                    "Package: %s\n  Manager : %s\n  Version : %s\n  Status  : %s\n  Installed: %s\n",
                    record.name, record.manager, record.version or "unknown",
                    record.status or "unknown", record.install_time or "unknown"
                ))
            else
                io.write(pkg_name .. ": not tracked by LEM\n")
            end
        end
    else
        -- List all managed packages
        local packages = DB.list_packages()
        if #packages == 0 then
            io.write("No packages managed by LEM.\n")
            return
        end
        io.write(string.format("%-20s %-10s %-15s %s\n", "NAME", "MANAGER", "VERSION", "STATUS"))
        io.write(string.rep("-", 60) .. "\n")
        for _, pkg in ipairs(packages) do
            io.write(string.format("%-20s %-10s %-15s %s\n",
                pkg.name, pkg.manager or "apt",
                pkg.version or "unknown", pkg.status or "unknown"))
        end
    end
end

function commands.source(args, flags)
    local subcmd = args[1]
    if not subcmd or subcmd == "help" then
        io.write("Usage: lem source <add|list|remove|update> [options]\n")
        io.write("\n")
        io.write("Commands:\n")
        io.write("  add <name>        Add a repository (uses built-in config)\n")
        io.write("  list              List managed repositories\n")
        io.write("  remove <name>     Remove a repository\n")
        io.write("  update            Run apt update\n")
        return
    end

    local Repository = require("source.repository")

    if subcmd == "add" then
        local name = args[2]
        if not name then
            io.stderr:write("Error: repository name required\n")
            io.stderr:write("Usage: lem source add <name>\n")
            return
        end
        local config = load_source_config(name)
        if not config then
            io.stderr:write("Error: unknown repository '" .. name .. "'\n")
            io.stderr:write("Built-in repositories: docker, vscode, nodejs\n")
            return
        end
        io.write("Adding repository: " .. name .. "\n")
        local ok, err = Repository.add(config)
        if ok then
            io.write("Repository '" .. name .. "' added successfully\n")
        else
            io.stderr:write("Error: " .. tostring(err) .. "\n")
        end
    elseif subcmd == "list" then
        local sources = Repository.list()
        if not sources or #sources == 0 then
            io.write("No managed repositories\n")
        else
            io.write(string.format("%-15s %-45s %-12s %s\n", "NAME", "URL", "DISTRIBUTION", "ADDED"))
            io.write(string.rep("-", 90) .. "\n")
            for _, s in ipairs(sources) do
                io.write(string.format("%-15s %-45s %-12s %s\n",
                    s.name, s.url or "", s.distribution or "", s.added_time or ""))
            end
        end
    elseif subcmd == "remove" then
        local name = args[2]
        if not name then
            io.stderr:write("Error: repository name required\n")
            return
        end
        io.write("Removing repository: " .. name .. "\n")
        local ok, err = Repository.remove(name)
        if ok then
            io.write("Repository '" .. name .. "' removed\n")
        else
            io.stderr:write("Error removing repository: " .. tostring(err) .. "\n")
        end
    elseif subcmd == "update" then
        io.write("Updating package lists...\n")
        local ok, err = Repository.update()
        if ok then
            io.write("Package lists updated\n")
        else
            io.stderr:write("Error updating package lists: " .. tostring(err) .. "\n")
        end
    else
        io.stderr:write("Unknown source command: " .. subcmd .. "\n")
    end
end

function commands.apply(args, flags)
    local name = args[1]
    if not name then
        print("Usage: lem apply <recipe>")
        print("")
        print("Apply a recipe to set up an environment.")
        print("")
        print("Available recipes:")
        -- List built-in recipes
        local recipe_dir = _G.LEM_ROOT .. "/recipes"
        local handle = io.popen("ls " .. recipe_dir .. "/*.lua 2>/dev/null")
        if handle then
            for line in handle:lines() do
                local rname = line:match("([^/]+)%.lua$")
                if rname then
                    print("  " .. rname)
                end
            end
            handle:close()
        end
        return
    end

    local Recipe = require("recipe.loader")
    local PkgManager = require("package.manager")

    -- 1. Load recipe
    print("Loading recipe: " .. name)
    local recipe, err = Recipe.load(name)
    if not recipe then
        print("Error: " .. err)
        return
    end

    print("Recipe: " .. recipe.name)
    if recipe.description then
        print("Description: " .. recipe.description)
    end
    print("")

    -- 2. Check and install missing packages
    local installed = 0
    local skipped = 0
    local failed = 0

    for _, pkg in ipairs(recipe.packages) do
        local pkg_info = { name = pkg.name, manager = pkg.manager or "apt" }

        -- Check if already installed
        local is_installed = PkgManager.is_installed(pkg_info)
        if is_installed then
            print("  [skip] " .. pkg.name .. " (already installed)")
            skipped = skipped + 1
        else
            print("  [install] " .. pkg.name .. " (" .. pkg_info.manager .. ")")
            local ok, install_err = PkgManager.install(pkg_info)
            if ok then
                installed = installed + 1
            else
                print("    Error: " .. (install_err or "unknown error"))
                failed = failed + 1
            end
        end
    end

    -- 3. Start services (Docker containers)
    local services_started = 0
    local services_failed = 0

    if recipe.services and #recipe.services > 0 then
        local Docker = require("package.docker")
        print("")
        print("Starting services...")
        for _, svc in ipairs(recipe.services) do
            local opts = {
                image  = svc.image,
                port   = svc.port,
                env    = svc.env,
                volume = svc.volume,
            }
            print("  [service] " .. svc.name .. " (" .. (svc.image or svc.name) .. ")")
            local ok, svc_err = Docker.install(svc.name, opts)
            if ok then
                services_started = services_started + 1
            else
                print("    Error: " .. tostring(svc_err))
                services_failed = services_failed + 1
            end
        end
    end

    -- 4. Output summary
    print("")
    print("Summary:")
    print("  Installed: " .. installed)
    print("  Skipped:   " .. skipped)
    print("  Failed:    " .. failed)
    print("  Total:     " .. #recipe.packages)
    if recipe.services and #recipe.services > 0 then
        print("  Services started: " .. services_started)
        print("  Services failed : " .. services_failed)
    end

    if failed > 0 or services_failed > 0 then
        print("")
        print("Some packages or services failed to install.")
    else
        print("")
        print("Recipe '" .. recipe.name .. "' applied successfully!")
    end

    -- 处理环境变量
    if recipe.env and next(recipe.env) then
        local Variable = require("environment.variable")
        local ok, err = Variable.generate(recipe.env)
        if ok then
            print("")
            print("Environment variables updated: ~/.config/lem/env.sh")
            print("Run: source ~/.config/lem/env.sh")
        end
    end
end

function commands.env(args, flags)
    local Variable = require("environment.variable")
    if args[1] == "show" or not args[1] then
        local content, err = Variable.show()
        if content then
            print("Current LEM environment variables:")
            print("")
            print(content)
            print("Source this file: source ~/.config/lem/env.sh")
        else
            print("No environment configuration found.")
        end
    else
        print("Usage: lem env [show]")
    end
end

function commands.backup(args, flags)
    local EnvManager = require("environment.manager")
    local configs = (#args > 0) and args or nil
    EnvManager.backup(configs)
end

function commands.restore(args, flags)
    local EnvManager = require("environment.manager")
    local configs = (#args > 0) and args or nil
    EnvManager.restore(configs)
end

commands.deps = function(args, flags)
    local Deps = require("core.deps")
    local subcmd = args[1] or "status"
    
    if subcmd == "status" or subcmd == "check" then
        Deps.report()
    elseif subcmd == "install" then
        Deps.install_missing()
    elseif subcmd == "list" then
        for _, dep in ipairs(Deps.dependencies) do
            local type_str = dep.type == "required" and "[required]" or "[optional]"
            print(string.format("  %-10s %-20s %s", type_str, dep.name, dep.description))
        end
    else
        print("Unknown deps subcommand: " .. subcmd)
        print("Available: status, install, list")
    end
end

function commands.help(args, flags)
    io.write([[
LEM - Lua Environment Manager (v]] .. VERSION .. [[)

Usage: lem <command> [options] [arguments]

Commands:
  install <pkg...>    Install one or more packages
  remove  <pkg...>    Remove one or more packages
  status  [pkg...]    Show package status (all or specific)
  source  <sub>       Manage APT repositories (add|list|remove|update)
  apply   <recipe>    Apply a recipe to set up an environment
  env     [show]      Show LEM environment variables
  backup  [configs]   Backup configuration files
  restore [configs]   Restore configuration files from backup
  deps   [status]     Check dependency status
  deps   install      Install missing dependencies
  deps   list         List all dependencies
  update  [target]    Update package lists and upgrade (all|system|lem)
  lem update               Check for available updates
  lem update --check       Check version only
  lem update --apply       Download and apply update
  lem update --history     Show update history
  lem update --rollback [version]  Rollback to a previous version
  lem update --resume      Resume interrupted update
  lem update --status      Show current update status
  init    [--force]   Initialize LEM environment
  check               Check LEM init state (exit 0=complete, 1=partial, 2=uninitialized)
  report  [--verbose] Show LEM environment report
  scan                Scan system packages (requires system_takeover=true)
  scan --import       Import scanned packages into LEM
  scan --dry-run      Scan without making changes
  scan --import --mode=symlink|reinstall  Choose takeover mode

Init Options:
  --force             Force reinitialize even if already done
  --skip-shell        Skip shell integration (don't modify .bashrc/.zshrc)
  --skip-db           Skip database initialization
  --skip-compile      Skip C native module compilation
  --dry-run           Show what would be done without making changes
  help                Show this help message
  version             Show version number

Global Options:
  --help, -h          Show help
  --version, -v       Show version
  --verbose           Enable verbose/debug output
  --manager=<name>    Specify package manager (default: apt)
]])
end

function commands.update(args, flags)
    local target = args[1] or "all"

    -- Handle --check and --apply flags for LEM self-update
    local check_only = flags["check"] or false
    local apply_flag = flags["apply"] or false

    -- --history: 显示版本历史
    if flags["history"] then
        local Updater = require("core.updater")
        Updater.show_history()
        return
    end

    -- --rollback [version]: 回滚
    if flags["rollback"] then
        local Updater = require("core.updater")
        local target_ver = args[1]  -- 可选的版本号参数
        if target_ver then
            Updater.rollback(target_ver)
        else
            -- 无参数时显示最近版本让用户选择
            local history = require("core.db").list_version_history(5)
            if not history or #history == 0 then
                print("No version history available for rollback.")
                return
            end
            print("Available versions for rollback:")
            for i, entry in ipairs(history) do
                print(string.format("  %d) v%s (%s)", i, entry.version, entry.installed_at or ""))
            end
            io.write("Select version number: ")
            local choice = io.read("*n")
            if choice and history[choice] then
                Updater.rollback(history[choice].version)
            else
                print("Invalid selection.")
            end
        end
        return
    end

    -- --resume: 恢复中断的更新
    if flags["resume"] then
        local Updater = require("core.updater")
        Updater.resume_update()
        return
    end

    -- --status: 显示更新状态
    if flags["status"] then
        local Updater = require("core.updater")
        Updater.show_status()
        return
    end

    if check_only or apply_flag or target == "lem" then
        local Updater = require("core.updater")

        if check_only or (not apply_flag and target == "lem") then
            -- Check version only
            print("Checking for updates...")
            local info, err = Updater.has_update()
            if info then
                Updater.print_version_info(info)
            else
                print("Unable to check for updates. Check your network connection.")
                if err then Logger.warn("update check error: " .. err) end
            end
            return
        end

        if apply_flag then
            -- Perform update
            print("Checking for updates...")
            local info, err = Updater.has_update()
            if not info then
                print("Unable to check for updates.")
                if err then Logger.warn("update check error: " .. err) end
                return
            end

            if not info.has_update then
                print(string.format("Already up to date (v%s).", info.current))
                return
            end

            print(string.format("New version available: v%s -> v%s", info.current, info.latest))
            io.write("Update? [y/N] ")
            local answer = io.read("*l")
            if answer ~= "y" and answer ~= "Y" then
                print("Cancelled.")
                return
            end

            local ok, update_err = Updater.apply_update()
            if ok then
                print("Update complete.")
            else
                print("Update failed: " .. tostring(update_err))
            end
        end
        return
    end

    -- Original behaviour for all / system targets
    if target == "all" or target == "system" then
        print("Updating package lists...")
        local result = Executor.execute_sudo("apt update")
        if result.success then
            print("Package lists updated successfully.")
        else
            print("Failed to update package lists.")
            return
        end
        if target == "all" then
            print("")
            print("Upgrading installed packages...")
            local upgrade_result = Executor.execute_sudo("apt upgrade -y")
            if upgrade_result.success then
                print("Packages upgraded successfully.")
            else
                print("Some packages failed to upgrade.")
            end
        end
    else
        print("Usage: lem update [all|system|lem]")
        print("       lem update --check       Check for LEM updates")
        print("       lem update --apply       Download and apply LEM update")
    end
end

function commands.version(args, flags)
    io.write("LEM version " .. VERSION .. "\n")
end

function commands.init(args, flags)
    local Init = require("core.init")
    local force = flags.force or false
    local opts = {
        skip_shell   = flags["skip-shell"] or false,
        skip_db      = flags["skip-db"] or false,
        skip_compile = flags["skip-compile"] or false,
        dry_run      = flags["dry-run"] or false,
    }
    Init.initialize(force, opts)
end

function commands.check(args, flags)
    local Init = require("core.init")
    local status = Init.check()
    
    if status.init_state == "complete" then
        io.write("LEM environment: OK\n")
        os.exit(0)
    elseif status.init_state == "partial" then
        io.write("LEM environment: PARTIAL (" .. status.missing_count .. " items missing)\n")
        for _, item in ipairs(status.missing) do
            io.write("  - " .. item.name .. "\n")
        end
        io.write("Run 'lem init' to fix.\n")
        os.exit(1)
    else
        io.write("LEM environment: NOT INITIALIZED\n")
        io.write("Run 'lem init' to initialize.\n")
        os.exit(2)
    end
end

function commands.report(args, flags)
    local Init = require("core.init")
    local verbose = flags.verbose or false
    Init.report(verbose)
end

commands.scan = function(args, flags)
    -- 检查 system_takeover 配置是否开启
    local config_path = (_G.LEM_ROOT or ".") .. "/config/lem.lua"
    local config = {}
    if io.open(config_path) then
        local ok, cfg = pcall(dofile, config_path)
        if ok then config = cfg end
    end

    if not config.system_takeover then
        print("System takeover is disabled.")
        print("Enable it in config/lem.lua: system_takeover = true")
        return
    end

    local Scanner = require("core.scanner")
    local Takeover = require("core.takeover")

    -- 解析 flags
    local do_import = flags["import"] or false
    local dry_run = flags["dry-run"] or false
    local mode = flags["mode"] or "symlink"  -- default mode

    -- 执行扫描
    print("Scanning system environment...")
    print("")
    local results = Scanner.scan_all()
    Scanner.print_report(results)

    if dry_run then
        print("")
        print("[Dry run] No changes made.")
        return
    end

    if not do_import then
        return
    end

    -- 导入确认
    local total = results.summary.dpkg_count + results.summary.docker_count
    print("")
    print(string.format("Found %d packages to import.", total))
    io.write("Continue? [y/N] ")
    local answer = io.read("*l")
    if answer ~= "y" and answer ~= "Y" then
        print("Cancelled.")
        return
    end

    -- 执行导入
    print("")
    print(string.format("Importing with mode: %s", mode))

    if mode == "symlink" then
        -- 构建 package_list 用于 symlink 模式
        local pkg_list = {}
        for _, pkg in ipairs(results.dpkg_packages or {}) do
            if pkg.status == "install" then
                -- 查找二进制路径
                local which_result = Executor.execute("which " .. pkg.name)
                local path = which_result.success and which_result.stdout:match("(%S+)") or nil
                if path then
                    table.insert(pkg_list, {name=pkg.name, path=path, version="system"})
                end
            end
        end
        for _, bin in ipairs(results.binaries or {}) do
            table.insert(pkg_list, {name=bin.name, path=bin.path, version=bin.version or "system"})
        end

        local takeover_results = Takeover.symlink_takeover(pkg_list)
        Takeover.print_report(takeover_results, "symlink")
    elseif mode == "reinstall" then
        -- 构建 package_list 用于 reinstall 模式
        local pkg_list = {}
        for _, pkg in ipairs(results.dpkg_packages or {}) do
            if pkg.status == "install" then
                table.insert(pkg_list, {name=pkg.name, manager="apt", version="system"})
            end
        end
        for _, container in ipairs(results.docker_containers or {}) do
            table.insert(pkg_list, {name=container.name, manager="docker", version=container.image})
        end

        local takeover_results = Takeover.reinstall_takeover(pkg_list)
        Takeover.print_report(takeover_results, "reinstall")
    end
end

------------------------------------------------------------------------
-- Argument parser
------------------------------------------------------------------------
local function parse_args(arg)
    local command = nil
    local positional = {}
    local flags = {}

    local i = 0
    while arg[i] ~= nil do i = i - 1 end
    i = i + 1  -- now arg[i] is the first element (arg[0] is script name)

    -- Skip arg[0] (script path)
    if arg[0] then
        i = 1
    end

    while arg[i] ~= nil do
        local a = arg[i]

        if a == "--help" or a == "-h" then
            flags.help = true
        elseif a == "--version" or a == "-v" then
            flags.version = true
        elseif a == "--verbose" then
            flags.verbose = true
        elseif a:match("^%-%-") then
            -- Handle --key=value flags
            local key, value = a:match("^%-%-([^=]+)=(.*)$")
            if key then
                flags[key] = value
            else
                -- Boolean flag: --flag-name  →  flags["flag-name"] = true
                local flag_name = a:match("^%-%-(.+)$")
                if flag_name then
                    flags[flag_name] = true
                end
            end
        elseif not command then
            command = a
        else
            positional[#positional + 1] = a
        end

        i = i + 1
    end

    return command, positional, flags
end

------------------------------------------------------------------------
-- Main entry
------------------------------------------------------------------------
function M.run(arg)
    -- Initialise logger and DB using globals set by main.lua
    local data_dir = _G.LEM_DATA or "/tmp/lem"
    local log_level = "INFO"

    -- Parse early to check for --verbose before init
    local _, _, early_flags = parse_args(arg)
    if early_flags.verbose then
        log_level = "DEBUG"
    end

    Logger.init(data_dir, log_level)

    local command, args, flags = parse_args(arg)

    -- Handle global flags that short-circuit
    if flags.help and not command then
        commands.help(args, flags)
        return
    end
    if flags.version and not command then
        commands.version(args, flags)
        return
    end

    -- Override verbose after full parse
    if flags.verbose then
        Logger.set_level("DEBUG")
    end

    -- Route to command
    if not command then
        commands.help(args, flags)
        return
    end

    -- If --help was passed alongside a command, show help for that command
    if flags.help then
        commands.help(args, flags)
        return
    end

    -- Auto-initialization detection (must happen before DB.init)
    -- If not initialized, Init.initialize() handles DB.init internally.
    -- For init/help/version commands, skip auto-init check.
    local auto_initialized = false
    if command ~= "init" and command ~= "help" and command ~= "version"
       and command ~= "check" and command ~= "report" then
        local Init = require("core.init")
        if not Init.is_initialized() then
            print("LEM environment not initialized. Running init...")
            print("")
            Init.initialize(false, { skip_shell = true })  -- auto-init: skip shell rc modification
            print("")
            auto_initialized = true
        end
    end

    -- Initialise DB for the current command
    -- (skip if Init.initialize just ran, as it already set up the DB)
    if not auto_initialized then
        DB.init(data_dir)
    end

    local handler = commands[command]
    if handler then
        handler(args, flags)
    else
        io.stderr:write("Unknown command: " .. command .. "\n")
        io.stderr:write("Run 'lem help' for usage.\n")
        os.exit(1)
    end

    -- Cleanup
    DB.close()
    Logger.close()
end

return M
