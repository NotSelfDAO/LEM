-- LEM Test Runner
local total = 0
local passed = 0
local failed = 0

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("  [PASS] " .. name)
    else failed = failed + 1; print("  [FAIL] " .. name .. " - " .. tostring(err)) end
end

local function assert_eq(a, e, m)
    if a ~= e then error((m or "") .. " expected " .. tostring(e) .. " got " .. tostring(a)) end
end
local function assert_true(v, m)
    if not v then error((m or "") .. " expected true") end
end
local function assert_type(v, t, m)
    if type(v) ~= t then error((m or "") .. " expected " .. t .. " got " .. type(v)) end
end

local script_dir = debug.getinfo(1, "S").source:match("@(.+)[/\\]") or "."
local root_dir = script_dir:match("(.+)[/\\]") or "."
package.path = root_dir .. "/src/?.lua;" .. package.path

print("=== LEM Test Suite ===")
print("")

print("[Module] core.fs")
local FS = require("core.fs")
test("FS.expand_path expands ~", function()
    assert_true(not FS.expand_path("~/test"):match("^~"))
end)
test("FS.file_exists returns false for nonexistent", function()
    assert_eq(FS.file_exists("/nonexistent/file.txt"), false)
end)
test("FS.write and FS.read roundtrip", function()
    local tmp = "/tmp/lem_test_" .. os.time()
    assert_true(FS.write(tmp, "hello"))
    assert_eq(FS.read(tmp), "hello")
    os.remove(tmp)
end)

print("")
print("[Module] core.executor")
local Executor = require("core.executor")
test("execute returns correct structure", function()
    local r = Executor.execute("echo hello")
    assert_type(r, "table"); assert_type(r.success, "boolean"); assert_type(r.exit_code, "number")
end)
test("execute succeeds for valid command", function()
    local r = Executor.execute("echo hello")
    assert_eq(r.success, true); assert_eq(r.exit_code, 0)
end)
test("execute fails for invalid command", function()
    assert_eq(Executor.execute("false").success, false)
end)

print("")
print("[Module] core.logger")
local Logger = require("core.logger")
test("Logger.init does not error", function() Logger.init("/tmp", "DEBUG") end)
test("Logger functions exist", function()
    assert_type(Logger.info, "function"); assert_type(Logger.error, "function")
end)

print("")
print("[Module] recipe.loader")
local Recipe = require("recipe.loader")
test("validate accepts valid recipe", function()
    assert_true(Recipe.validate({ name = "t", packages = { { name = "g", manager = "apt" } } }))
end)
test("validate rejects missing name", function()
    assert_eq(Recipe.validate({ packages = {} }), false)
end)
test("validate rejects missing packages", function()
    assert_eq(Recipe.validate({ name = "t" }), false)
end)

print("")
print("[Module] package.manager")
local PkgManager = require("package.manager")
test("get_backend returns apt", function()
    local b = PkgManager.get_backend("apt")
    assert_type(b, "table"); assert_type(b.install, "function")
end)
test("get_backend returns nil for unknown", function()
    assert_eq(PkgManager.get_backend("unknown"), nil)
end)

print("")
print("=== Results ===")
print(string.format("Total: %d | Passed: %d | Failed: %d", total, passed, failed))
if failed > 0 then os.exit(1) else print("All tests passed!") os.exit(0) end
