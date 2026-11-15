local test = require("luaunit")
local api = require("docs.api_examples")
local files = require("support.files")
local fs = require("support.fs")
local json = require("support.json")
local repo = require("support.repo")
local M = {}

local TARGETS = {}
for symbol in
    ([[libtmux.Runtime:connect libtmux.Server:snapshot libtmux.Snapshot.sessions
    libtmux.Snapshot.windows libtmux.Snapshot.panes libtmux.Server:new_session
    libtmux.Session:new_window libtmux.Server:query libtmux.Pane:send_text libtmux.Pane:send_keys
    libtmux.Pane:capture libtmux.Pane:wait_for_text libtmux.Error.code libtmux.Error.message
    libtmux.Entity:snapshot libtmux.Window:rename libtmux.Server:explain_panes
    libtmux.Server:group libtmux.Server:observe libtmux.Observation:watch_pane
    libtmux.Pane:resize libtmux.Window:resize libtmux.Runtime:start_server
    libtmux.Runtime:with_server libtmux.OwnedServer.server libtmux.OwnedServer.socket_path
    libtmux.OwnedServer:stop]]):gmatch("%S+")
do
    TARGETS[symbol] = true
end

-- What a launcher or a hand-made server would need. A program that names any of these is not one
-- Lua program on the library.
local OUTSIDE_THE_LIBRARY = {
    "run.sh",
    "TMUX_SOCKET",
    "os.execute",
    "io.popen",
    "perl",
    "wait-for",
    "/bin/sh -c",
    "unset",
}

local root, manifest

local function save()
    json.write(root .. "/examples/api/manifest.json", manifest, 2)
end

local function without(targets, symbol)
    local copy = {}
    for key in pairs(targets) do
        copy[key] = key ~= symbol or nil
    end
    return copy
end

local function rejects(pattern)
    local ok, failure = pcall(api.load_examples, root)
    test.assertFalse(ok, "accepted: " .. pattern)
    test.assertStrContains(tostring(failure), pattern)
end

function M.setUp()
    root = fs.mkdtemp("libtmux-lua-examples-")
    fs.copy_tree(repo.root .. "/examples/api", root .. "/examples/api")
    manifest = json.read(root .. "/examples/api/manifest.json")
end

function M.tearDown()
    fs.remove_tree(root)
end

function M.test_complete_programs_cover_their_existing_targets()
    local loaded = api.load_examples(repo.root, TARGETS)
    test.assertEquals(#loaded.examples, 16)
    local seen = {}
    for _, example in ipairs(loaded.examples) do
        for _, symbol in ipairs(example.symbols) do
            seen[symbol] = true
        end
        local source = files.read(repo.root .. "/" .. example.file)
        test.assertStrContains(source, 'require("libtmux.runtime.luv")')
        -- Each program starts its own server and ends it, or hands it to the scoped form.
        test.assertStrContains(
            source,
            example.id == "with_server" and "with_server" or "start_server"
        )
        if example.id ~= "with_server" then
            test.assertStrContains(source, "owned:stop():await()")
        end
        test.assertNil(source:find('require("tests.', 1, true))
        for _, word in ipairs(OUTSIDE_THE_LIBRARY) do
            test.assertNil(
                source:find(word, 1, true),
                example.id .. " reaches outside the library: " .. word
            )
        end
    end
    test.assertEquals(seen, TARGETS)
end

function M.test_receiver_and_collection_identities_match_native_annotations()
    local declarations = {
        {
            name = "libtmux.Server",
            fields = { { name = "snapshot", view = "fun(self: libtmux.Server):libtmux.Request" } },
        },
        {
            name = "libtmux.Snapshot",
            fields = { { name = "sessions", view = "libtmux.Selection<libtmux.SnapshotSession>" } },
        },
    }
    test.assertEquals(api.public_symbols(declarations), {
        ["libtmux.Server"] = true,
        ["libtmux.Server:snapshot"] = true,
        ["libtmux.Snapshot"] = true,
        ["libtmux.Snapshot.sessions"] = true,
    })
end

function M.test_rejects_unknown_targets_and_duplicate_ownership()
    local ok, failure = pcall(api.load_examples, root, without(TARGETS, "libtmux.Pane:capture"))
    test.assertFalse(ok)
    test.assertStrContains(tostring(failure), "unknown API target")
    table.insert(manifest.examples[2].symbols, "libtmux.Runtime:connect")
    save()
    rejects("duplicate API target")
end

function M.test_rejects_unsafe_missing_and_unlisted_files()
    local original = manifest.examples[1].file
    for _, path in ipairs({ "../capture.lua", "/tmp/capture.lua", "examples/api/other.lua" }) do
        manifest.examples[1].file = path
        save()
        rejects("file path")
    end
    manifest.examples[1].file = original
    save()
    files.write(root .. "/examples/api/extra.lua", 'print("unlisted")\n')
    rejects("unlisted Lua example")
    os.remove(root .. "/examples/api/extra.lua")
    os.remove(root .. "/examples/api/" .. original:match("[^/]+$"))
    rejects("missing or linked")
end

function M.test_rejects_unknown_fields_unpinned_versions_and_missing_output()
    local original = files.read(root .. "/examples/api/manifest.json")
    local function field(object, key, value)
        if object[key] == nil then
            local keys = json.keys(object)
            keys[#keys + 1] = key
        end
        object[key] = value
    end
    local mutations = {
        function(m)
            field(m, "extra", true)
        end,
        function(m)
            m.setup.lua = "latest"
        end,
        function(m)
            m.setup.luv = "1.52"
        end,
        function(m)
            m.examples[1].stdout = ""
        end,
        function(m)
            m.examples[1].description = ""
        end,
        function(m)
            m.examples[1].symbols = {}
        end,
        function(m)
            field(m.examples[1], "min_tmux", "3")
        end,
        function(m)
            field(m.examples[1], "minimum_tmux", "3.7")
        end,
    }
    for index, mutate in ipairs(mutations) do
        manifest = json.decode(original)
        mutate(manifest)
        save()
        local ok = pcall(api.load_examples, root)
        test.assertFalse(ok, "mutation " .. index .. " was accepted")
    end
end

function M.test_rejects_linked_and_normalized_source_bytes()
    local program = root .. "/examples/api/connect.lua"
    os.remove(program)
    local uv = require("support.uv")
    assert(uv.fs_symlink(repo.root .. "/examples/api/connect.lua", program))
    rejects("missing or linked")
    os.remove(program)
    files.write(program, 'print("changed")\r\n')
    rejects("LF endings")
end

return M
