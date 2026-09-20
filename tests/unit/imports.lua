local tests = {}

local function copy(values)
    local result = {}
    for key, value in pairs(values) do
        result[key] = value
    end
    return result
end

local function same_entries(actual, expected, label)
    for key, value in pairs(expected) do
        assert(actual[key] == value, label .. " changed " .. tostring(key))
    end
    for key in pairs(actual) do
        assert(expected[key] ~= nil, label .. " added " .. tostring(key))
    end
end

local function restore(actual, expected)
    for key in pairs(actual) do
        actual[key] = expected[key]
    end
    for key, value in pairs(expected) do
        actual[key] = value
    end
end

-- The import guard replaces I/O entry points and restores them before returning.
-- luacheck: push ignore 122
local function pure_imports(names)
    local original_require = require
    local original_globals = copy(_G)
    local original_package = copy(package)
    local original_loaded = copy(package.loaded)
    local original_io, original_os = copy(io), copy(os)
    local original_path, original_cpath = package.path, package.cpath
    local function forbidden()
        error("package import attempted I/O or environment access", 2)
    end

    for _, name in ipairs({
        "open",
        "input",
        "output",
        "lines",
        "popen",
        "tmpfile",
        "read",
        "write",
    }) do
        io[name] = forbidden
    end
    for _, name in ipairs({
        "execute",
        "getenv",
        "setlocale",
        "remove",
        "rename",
        "tmpname",
        "exit",
    }) do
        os[name] = forbidden
    end
    _G.dofile, _G.loadfile = forbidden, forbidden
    _G.require = function(name)
        assert(name == "libtmux" or name:match("^libtmux[._]"), "unexpected dependency: " .. name)
        return original_require(name)
    end
    for name in pairs(package.loaded) do
        if name == "libtmux" or name:match("^libtmux[._]") then
            package.loaded[name] = nil
        end
    end
    local guarded_globals, guarded_io, guarded_os = copy(_G), copy(io), copy(os)
    local ok, err = pcall(function()
        for _, name in ipairs(names) do
            assert(type(require(name)) == "table", "package must return a table: " .. name)
        end
        same_entries(_G, guarded_globals, "globals")
        same_entries(io, guarded_io, "io")
        same_entries(os, guarded_os, "os")
        same_entries(package, original_package, "package")
        assert(package.path == original_path, "package.path changed")
        assert(package.cpath == original_cpath, "package.cpath changed")
    end)

    restore(_G, original_globals)
    restore(io, original_io)
    restore(os, original_os)
    restore(package, original_package)
    restore(package.loaded, original_loaded)
    assert(ok, err)
end
-- luacheck: pop

function tests.test_core_and_query_import_without_effects()
    pure_imports({ "libtmux", "libtmux.query", "libtmux.runtime.luv", "libtmux.runtime.nvim" })
end

function tests.test_mcp_import_without_effects()
    pure_imports({ "libtmux_mcp" })
    assert(require("libtmux_mcp")._VERSION == "scm")
end

function tests.test_workspace_import_without_effects()
    pure_imports({ "libtmux_workspace" })
    assert(require("libtmux_workspace")._VERSION == "scm")
end

return tests
