-- src/recipe/loader.lua
-- Recipe loading, parsing, and validation

local FS = require("core.fs")
local Logger = require("core.logger")

local M = {}

-- Load a recipe by name
-- Search paths: LEM_ROOT/recipes/ -> ~/.config/lem/recipes/ -> current directory
function M.load(name)
    local search_paths = {
        _G.LEM_ROOT .. "/recipes/" .. name .. ".lua",
        FS.expand_path("~/.config/lem/recipes/" .. name .. ".lua"),
        "./" .. name .. ".lua",
    }

    for _, path in ipairs(search_paths) do
        if FS.file_exists(path) then
            return M.load_from_file(path)
        end
    end

    return nil, "recipe not found: " .. name
end

-- Load a recipe from a file path
function M.load_from_file(path)
    Logger.debug("Loading recipe from: " .. path)

    local ok, recipe = pcall(dofile, path)
    if not ok then
        return nil, "failed to load recipe: " .. tostring(recipe)
    end

    -- Validate recipe structure
    local valid, err = M.validate(recipe)
    if not valid then
        return nil, "invalid recipe: " .. err
    end

    return recipe
end

-- Validate recipe structure completeness
function M.validate(recipe)
    if type(recipe) ~= "table" then
        return false, "recipe must be a table"
    end
    if not recipe.name then
        return false, "recipe must have a 'name' field"
    end
    if not recipe.packages or type(recipe.packages) ~= "table" then
        return false, "recipe must have a 'packages' table"
    end
    for i, pkg in ipairs(recipe.packages) do
        if not pkg.name then
            return false, "package #" .. i .. " missing 'name' field"
        end
        if not pkg.manager then
            return false, "package #" .. i .. " missing 'manager' field"
        end
    end
    return true
end

return M
