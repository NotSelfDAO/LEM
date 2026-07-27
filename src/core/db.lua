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
CREATE TABLE IF NOT EXISTS update_state (
    id INTEGER PRIMARY KEY DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'idle',
    from_version TEXT,
    to_version TEXT,
    progress_pct REAL DEFAULT 0,
    started_at TEXT,
    updated_at TEXT,
    error_message TEXT,
    backup_path TEXT,
    download_url TEXT,
    bytes_downloaded INTEGER DEFAULT 0,
    total_bytes INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS version_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    version TEXT NOT NULL,
    tag TEXT,
    installed_at TEXT NOT NULL,
    backup_path TEXT,
    checksum TEXT,
    update_source TEXT,
    duration_secs INTEGER,
    success INTEGER DEFAULT 1,
    notes TEXT
);
CREATE TABLE IF NOT EXISTS file_manifest (
    version TEXT NOT NULL,
    path TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    size INTEGER,
    PRIMARY KEY (version, path)
);
]]

------------------------------------------------------------------------
-- Fallback: simple line-based file storage
-- Format (one record per line, fields separated by \t):
--   packages:      P\tname\tmanager\tversion\tinstall_time\tstatus
--   sources:       S\tname\trepo\tdistribution\tcomponent\tadded_time
--   update_state:  US\tstatus\tfrom_version\tto_version\tprogress_pct\tstarted_at\tupdated_at\terror_message\tbackup_path\tdownload_url\tbytes_downloaded\ttotal_bytes
--   version_hist:  VH\tversion\ttag\tinstalled_at\tbackup_path\tchecksum\tupdate_source\tduration_secs\tsuccess\tnotes
--   file_manifest:  FM\tversion\tpath\tsha256\tsize
------------------------------------------------------------------------
local fallback_path = nil
local fallback_data = { packages = {}, sources = {}, update_state = {}, version_history = {}, file_manifest = {} }

local function fallback_load()
    local f = io.open(fallback_path, "r")
    if not f then return end

    fallback_data = { packages = {}, sources = {}, update_state = {}, version_history = {}, file_manifest = {} }

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
        elseif parts[1] == "US" then
            fallback_data.update_state = {
                status           = parts[2]  or "idle",
                from_version     = parts[3],
                to_version       = parts[4],
                progress_pct     = tonumber(parts[5]) or 0,
                started_at       = parts[6],
                updated_at       = parts[7],
                error_message    = parts[8],
                backup_path      = parts[9],
                download_url     = parts[10],
                bytes_downloaded = tonumber(parts[11]) or 0,
                total_bytes      = tonumber(parts[12]) or 0,
            }
        elseif parts[1] == "VH" and parts[2] then
            fallback_data.version_history[#fallback_data.version_history + 1] = {
                version       = parts[2],
                tag           = parts[3],
                installed_at  = parts[4],
                backup_path   = parts[5],
                checksum      = parts[6],
                update_source = parts[7],
                duration_secs = tonumber(parts[8]),
                success       = tonumber(parts[9]) or 1,
                notes         = parts[10],
            }
        elseif parts[1] == "FM" and parts[2] then
            local key = parts[2] .. "\0" .. parts[3]
            fallback_data.file_manifest[key] = {
                version = parts[2],
                path    = parts[3],
                sha256  = parts[4],
                size    = tonumber(parts[5]),
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

    -- update_state (single row)
    local us = fallback_data.update_state
    if us and us.status then
        f:write(table.concat({
            "US",
            us.status           or "idle",
            us.from_version     or "",
            us.to_version       or "",
            tostring(us.progress_pct     or 0),
            us.started_at       or "",
            us.updated_at       or "",
            us.error_message    or "",
            us.backup_path      or "",
            us.download_url     or "",
            tostring(us.bytes_downloaded or 0),
            tostring(us.total_bytes      or 0),
        }, "\t") .. "\n")
    end

    for _, vh in ipairs(fallback_data.version_history) do
        f:write(table.concat({
            "VH",
            vh.version       or "",
            vh.tag           or "",
            vh.installed_at  or "",
            vh.backup_path   or "",
            vh.checksum      or "",
            vh.update_source or "",
            tostring(vh.duration_secs or ""),
            tostring(vh.success       or 1),
            vh.notes         or "",
        }, "\t") .. "\n")
    end

    for _, fm in pairs(fallback_data.file_manifest) do
        f:write(table.concat({
            "FM",
            fm.version or "",
            fm.path    or "",
            fm.sha256  or "",
            tostring(fm.size or ""),
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
-- Update State
------------------------------------------------------------------------

--- Save (INSERT OR REPLACE) the current update state.
-- @param state table  {status, from_version, to_version, progress_pct,
--              started_at, updated_at, error_message, backup_path,
--              download_url, bytes_downloaded, total_bytes}
function M.save_update_state(state)
    if not state then return nil, "state is nil" end

    if native_db then
        local sql = string.format(
            "INSERT OR REPLACE INTO update_state "
            .. "(id, status, from_version, to_version, progress_pct, "
            .. "started_at, updated_at, error_message, backup_path, "
            .. "download_url, bytes_downloaded, total_bytes) "
            .. "VALUES (1, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
            sql_escape(state.status),
            sql_escape(state.from_version),
            sql_escape(state.to_version),
            sql_escape(state.progress_pct),
            sql_escape(state.started_at),
            sql_escape(state.updated_at),
            sql_escape(state.error_message),
            sql_escape(state.backup_path),
            sql_escape(state.download_url),
            sql_escape(state.bytes_downloaded),
            sql_escape(state.total_bytes)
        )
        native_db.exec(db_conn, sql)
    else
        fallback_data.update_state = {
            status           = state.status,
            from_version     = state.from_version,
            to_version       = state.to_version,
            progress_pct     = state.progress_pct,
            started_at       = state.started_at,
            updated_at       = state.updated_at,
            error_message    = state.error_message,
            backup_path      = state.backup_path,
            download_url     = state.download_url,
            bytes_downloaded = state.bytes_downloaded,
            total_bytes      = state.total_bytes,
        }
        fallback_save()
    end
    return true
end

--- Load the current update state.
-- @return table|nil  update state table or nil
function M.load_update_state()
    if native_db then
        local rows = native_db.query(db_conn,
            "SELECT * FROM update_state WHERE id = 1")
        if rows and rows[1] then return rows[1] end
        return nil
    else
        local us = fallback_data.update_state
        if us and us.status then
            return {
                id               = 1,
                status           = us.status,
                from_version     = us.from_version,
                to_version       = us.to_version,
                progress_pct     = us.progress_pct,
                started_at       = us.started_at,
                updated_at       = us.updated_at,
                error_message    = us.error_message,
                backup_path      = us.backup_path,
                download_url     = us.download_url,
                bytes_downloaded = us.bytes_downloaded,
                total_bytes      = us.total_bytes,
            }
        end
        return nil
    end
end

--- Clear the update state (reset to idle).
function M.clear_update_state()
    if native_db then
        native_db.exec(db_conn,
            "DELETE FROM update_state")
    else
        fallback_data.update_state = {}
        fallback_save()
    end
    return true
end

------------------------------------------------------------------------
-- Version History
------------------------------------------------------------------------

--- Add a version history entry.
-- @param entry table  {version, tag, installed_at, backup_path, checksum,
--              update_source, duration_secs, success, notes}
function M.add_version_history(entry)
    if not entry then return nil, "entry is nil" end

    local now = entry.installed_at or os.date("%Y-%m-%d %H:%M:%S")

    if native_db then
        local sql = string.format(
            "INSERT INTO version_history "
            .. "(version, tag, installed_at, backup_path, checksum, "
            .. "update_source, duration_secs, success, notes) "
            .. "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            sql_escape(entry.version),
            sql_escape(entry.tag),
            sql_escape(now),
            sql_escape(entry.backup_path),
            sql_escape(entry.checksum),
            sql_escape(entry.update_source),
            sql_escape(entry.duration_secs),
            sql_escape(entry.success),
            sql_escape(entry.notes)
        )
        native_db.exec(db_conn, sql)
    else
        fallback_data.version_history[#fallback_data.version_history + 1] = {
            version       = entry.version,
            tag           = entry.tag,
            installed_at  = now,
            backup_path   = entry.backup_path,
            checksum      = entry.checksum,
            update_source = entry.update_source,
            duration_secs = entry.duration_secs,
            success       = entry.success,
            notes         = entry.notes,
        }
        fallback_save()
    end
    return true
end

--- List version history entries.
-- @param limit number|nil  max rows to return (default 50)
-- @return table  array of version history tables
function M.list_version_history(limit)
    limit = limit or 50

    if native_db then
        local sql = string.format(
            "SELECT * FROM version_history ORDER BY installed_at DESC LIMIT %d",
            tonumber(limit) or 50
        )
        return native_db.query(db_conn, sql)
    else
        local result = {}
        for _, vh in ipairs(fallback_data.version_history) do
            result[#result + 1] = {
                id            = #result + 1,
                version       = vh.version,
                tag           = vh.tag,
                installed_at  = vh.installed_at,
                backup_path   = vh.backup_path,
                checksum      = vh.checksum,
                update_source = vh.update_source,
                duration_secs = vh.duration_secs,
                success       = vh.success,
                notes         = vh.notes,
            }
        end
        table.sort(result, function(a, b)
            return (a.installed_at or "") > (b.installed_at or "")
        end)
        -- Apply limit
        if #result > limit then
            local trimmed = {}
            for i = 1, limit do trimmed[i] = result[i] end
            return trimmed
        end
        return result
    end
end

------------------------------------------------------------------------
-- File Manifest
------------------------------------------------------------------------

--- Save a file manifest for a version (batch insert).
-- @param version string  version identifier
-- @param manifest table  array of {path, sha256, size}
function M.save_file_manifest(version, manifest)
    if not version or not manifest then
        return nil, "version or manifest is nil"
    end

    if native_db then
        local parts = {}
        for _, fm in ipairs(manifest) do
            parts[#parts + 1] = string.format(
                "INSERT OR REPLACE INTO file_manifest (version, path, sha256, size) "
                .. "VALUES (%s, %s, %s, %s);",
                sql_escape(version),
                sql_escape(fm.path),
                sql_escape(fm.sha256),
                sql_escape(fm.size)
            )
        end
        native_db.exec(db_conn, table.concat(parts))
    else
        for _, fm in ipairs(manifest) do
            local key = version .. "\0" .. fm.path
            fallback_data.file_manifest[key] = {
                version = version,
                path    = fm.path,
                sha256  = fm.sha256,
                size    = fm.size,
            }
        end
        fallback_save()
    end
    return true
end

--- Load the file manifest for a version.
-- @param version string  version identifier
-- @return table  array of {version, path, sha256, size}
function M.load_file_manifest(version)
    if not version then return {} end

    if native_db then
        local sql = string.format(
            "SELECT * FROM file_manifest WHERE version = %s ORDER BY path",
            sql_escape(version)
        )
        return native_db.query(db_conn, sql)
    else
        local result = {}
        for _, fm in pairs(fallback_data.file_manifest) do
            if fm.version == version then
                result[#result + 1] = {
                    version = fm.version,
                    path    = fm.path,
                    sha256  = fm.sha256,
                    size    = fm.size,
                }
            end
        end
        table.sort(result, function(a, b) return a.path < b.path end)
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
