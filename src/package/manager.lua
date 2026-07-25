-- src/package/manager.lua
-- Package abstraction layer: routes to backend managers (apt, etc.)

local M = {}

------------------------------------------------------------------------
-- Backend registry
------------------------------------------------------------------------
local backends = {}

function M.register(name, backend)
    backends[name] = backend
end

function M.get_backend(name)
    return backends[name]
end

------------------------------------------------------------------------
-- Unified interface
------------------------------------------------------------------------

function M.install(pkg)
    -- pkg = { name = "git", manager = "apt" }
    local backend = backends[pkg.manager]
    if not backend then
        return nil, "unknown package manager: " .. pkg.manager
    end
    return backend.install(pkg.name)
end

function M.remove(pkg)
    local backend = backends[pkg.manager]
    if not backend then
        return nil, "unknown package manager: " .. pkg.manager
    end
    return backend.remove(pkg.name)
end

function M.is_installed(pkg)
    local backend = backends[pkg.manager]
    if not backend then
        return nil, "unknown package manager: " .. pkg.manager
    end
    return backend.is_installed(pkg.name)
end

function M.status(pkg)
    local backend = backends[pkg.manager]
    if not backend then
        return nil, "unknown package manager: " .. pkg.manager
    end
    return backend.is_installed(pkg.name)
end

------------------------------------------------------------------------
-- Auto-register backends
------------------------------------------------------------------------
local function init()
    local apt = require("package.apt")
    M.register("apt", apt)

    local docker = require("package.docker")
    M.register("docker", docker)
end

init()

return M
