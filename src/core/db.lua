-- src/core/db.lua
-- State database: SQLite via C module or plain-file fallback

local M = {}

------------------------------------------------------------------------
-- Try to load C native SQLite module
------------------------------------------------------------------------
local ok, native_db = pcall(require, "native.lem_db")
if not ok then native_db = nil end

local db_path  = nil
local db_conn  = nil

------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS packages (
    name         TEXT PRIMARY KEY,
    manager      TEXT NOT NULL DEFAULT 'apt',
    version      TEXT,
    install_time TEXT,
    status       TEXT DEFAULT 'installed'
);
CREATE TABLE IF NOT EXISTS sources (
    name         TEXT PRIMARY KEY,
    repo         TEXT,
    distribution TEXT,
    component    TEXT,
    added_time   TEXT
);
]]

------------------------------------------------------------------------
-- Fallback: simple line-based file storage
-- Format (one record per line, fields separated by \t):
--   packages:  P\tname\tmanager\tversion\tinstall_time\tstatus
--   sources:   S\tname\trepo\tdistribution\tcomponent\tadded_time
------------------------------------------------------------------------
local fallback_path = nil
local fallback_data = { packages = {}, sources = {} }

local function fallback_load()
    local f = io.open(fallback_path, "r")
    if not f then return end

    fallback_data = { packages = {}, sources = {} }

    for line in f:lines() do
        local parts = {}
        for field in line:gmatch("[^\t]*") do
            parts[#parts + 1] = field
        end

        if parts[1] == "P" and parts[2] then
            fallback_data.packages[parts[2]] = {
                name         = parts[2],
                manager      = parts[3] or "apt",
                version      = parts[4],
                install_time = parts[5],
                status       = parts[6] or "installed",
            }
        elseif parts[1] == "S" and parts[2] then
            fallback_data.sources[parts[2]] = {
                name         = parts[2],
                repo         = parts[3],
                distribution = parts[4],
                component    = parts[5],
                added_time   = parts[6],
            }
        end
    end
    f:close()
end

local function fallback_save()
    local f, err = io.open(fallback_path, "w")
    if not f then return nil, err end

    for _, pkg in pairs(fallback_data.packages) do
        f:write(table.concat({
            "P",
            pkg.name         or "",
            pkg.manager      or "apt",
            pkg.version      or "",
            pkg.install_time or "",
            pkg.status       or "installed",
        }, "\t") .. "\n")
    end

    for _, src in pairs(fallback_data.sources) do
        f:write(table.concat({
            "S",
            src.name         or "",
            src.repo         or "",
            src.distribution or "",
            src.component    or "",
            src.added_time   or "",
        }, "\t") .. "\n")
    end

    f:close()
    return true
end

------------------------------------------------------------------------
-- SQL helpers (native mode)
------------------------------------------------------------------------

local function sql_escape(s)
    if s == nil then return "NULL" end
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Initialise the database.
-- @param data_dir string  directory where state files are stored
function M.init(data_dir)
    db_path = data_dir .. "/state.db"

    if native_db then
        db_conn = native_db.open(db_path)
        native_db.exec(db_conn, "PRAGMA journal_mode=WAL")
        native_db.exec(db_conn, SCHEMA)
    else
        -- Fallback: plain file storage
        fallback_path = data_dir .. "/state.db.json"
        fallback_load()
    end
end

------------------------------------------------------------------------
-- Packages
------------------------------------------------------------------------

--- Record a package installation.
function M.add_package(name, manager, version)
    manager = manager or "apt"
    local now = os.date("%Y-%m-%d %H:%M:%S")

    if native_db then
        local sql = string.format(
            "INSERT OR REPLACE INTO packages (name, manager, version, install_time, status) "
            .. "VALUES (%s, %s, %s, %s, %s)",
            sql_escape(name), sql_escape(manager), sql_escape(version),
            sql_escape(now), sql_escape("installed")
        )
        native_db.exec(db_conn, sql)
    else
        fallback_data.packages[name] = {
            name         = name,
            manager      = manager,
            version      = version,
            install_time = now,
            status       = "installed",
        }
        fallback_save()
    end
    return true
end

--- Remove a package record.
function M.remove_package(name)
    if native_db then
        local sql = "DELETE FROM packages WHERE name = " .. sql_escape(name)
        native_db.exec(db_conn, sql)
    else
        fallback_data.packages[name] = nil
        fallback_save()
    end
    return true
end

--- Get a single package record.
-- @return table|nil  { name, manager, version, install_time, status }
function M.get_package(name)
    if native_db then
        local sql = "SELECT * FROM packages WHERE name = " .. sql_escape(name)
        local rows = native_db.query(db_conn, sql)
        if rows and rows[1] then return rows[1] end
        return nil
    else
        local pkg = fallback_data.packages[name]
        if pkg then
            -- Return a copy
            return {
                name         = pkg.name,
                manager      = pkg.manager,
                version      = pkg.version,
                install_time = pkg.install_time,
                status       = pkg.status,
            }
        end
        return nil
    end
end

--- List all tracked packages.
-- @return table  array of package tables
function M.list_packages()
    if native_db then
        return native_db.query(db_conn, "SELECT * FROM packages ORDER BY name")
    else
        local result = {}
        for _, pkg in pairs(fallback_data.packages) do
            result[#result + 1] = {
                name         = pkg.name,
                manager      = pkg.manager,
                version      = pkg.version,
                install_time = pkg.install_time,
                status       = pkg.status,
            }
        end
        table.sort(result, function(a, b) return a.name < b.name end)
        return result
    end
end

--- Batch import package records.
-- @param packages table  array of {name, manager, version}
-- @return number  count of successfully imported packages
function M.import_package(packages)
    if not packages or #packages == 0 then
        return 0
    end

    local count = 0
    for _, pkg in ipairs(packages) do
        local ok, err = pcall(function()
            M.add_package(
                pkg.name,
                pkg.manager or "apt",
                pkg.version or "system"
            )
        end)
        if ok then
            count = count + 1
        end
    end

    return count
end

------------------------------------------------------------------------
-- Sources
------------------------------------------------------------------------

--- Record an APT source.
function M.add_source(name, repo, distribution, component)
    local now = os.date("%Y-%m-%d %H:%M:%S")

    if native_db then
        local sql = string.format(
            "INSERT OR REPLACE INTO sources (name, repo, distribution, component, added_time) "
            .. "VALUES (%s, %s, %s, %s, %s)",
            sql_escape(name), sql_escape(repo), sql_escape(distribution),
            sql_escape(component), sql_escape(now)
        )
        native_db.exec(db_conn, sql)
    else
        fallback_data.sources[name] = {
            name         = name,
            repo         = repo,
            distribution = distribution,
            component    = component,
            added_time   = now,
        }
        fallback_save()
    end
    return true
end

--- Remove a source record.
function M.remove_source(name)
    if native_db then
        local sql = "DELETE FROM sources WHERE name = " .. sql_escape(name)
        native_db.exec(db_conn, sql)
    else
        fallback_data.sources[name] = nil
        fallback_save()
    end
    return true
end

--- List all tracked sources.
-- @return table  array of source tables
function M.list_sources()
    if native_db then
        return native_db.query(db_conn, "SELECT * FROM sources ORDER BY name")
    else
        local result = {}
        for _, src in pairs(fallback_data.sources) do
            result[#result + 1] = {
                name         = src.name,
                repo         = src.repo,
                distribution = src.distribution,
                component    = src.component,
                added_time   = src.added_time,
            }
        end
        table.sort(result, function(a, b) return a.name < b.name end)
        return result
    end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

--- Close the database connection.
function M.close()
    if native_db and db_conn then
        native_db.close(db_conn)
        db_conn = nil
    end
end

return M
