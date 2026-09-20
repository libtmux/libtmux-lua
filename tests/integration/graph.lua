local command = require("libtmux._internal.command")
local metadata = require("libtmux._internal.metadata")
local fields = require("libtmux._internal.fields")
local graph = require("libtmux._internal.graph")
local identity = require("libtmux._internal.identity")
local adapter = require("libtmux.runtime.luv")
local endpoint = {
    binary = assert(os.getenv("TMUX_BIN")),
    socket = assert(os.getenv("TMUX_SOCKET")),
    config = "/dev/null",
}

local result, failure = adapter.run(function(runtime)
    ---@cast runtime libtmux.TestRuntime
    local function execute(argv)
        local value, err = command.execute(runtime, endpoint, argv):await()
        assert(value, tostring(err))
        return value.stdout
    end
    local window =
        execute({ "display-message", "-p", "-t", "fixture", "#{window_id}" }):gsub("\n$", "")
    execute({ "new-session", "-d", "-s", "second", "exec /bin/cat" })
    execute({ "link-window", "-s", window, "-t", "second:7" })
    execute({ "set-buffer", "-b", "graph-buffer", "bytes;" })
    local server_projection = assert(metadata.projection("server", "3.2a", {
        "pid",
        "start_time",
        "socket_path",
        "version",
    }))
    local server_rows = assert(metadata.decode(
        execute({
            "display-message",
            "-p",
            assert(metadata.format(server_projection)),
        }),
        server_projection
    ))
    local server = server_rows[1]
    local generation = assert(identity.generation({
        pid = string.format("%.0f", server.pid),
        started = string.format("%.0f", server.start_time),
        socket = server.socket_path,
        version = server.version,
    }))
    local specs = {
        { "session", "sessions", "list-sessions" },
        { "window", "windows", "list-windows", "-a" },
        { "pane", "panes", "list-panes", "-a" },
        { "window_link", "window_links", "list-windows", "-a" },
        { "client", "clients", "list-clients" },
        { "buffer", "buffers", "list-buffers" },
    }
    local listings = {}
    local started = runtime._driver.now()
    for _, spec in ipairs(specs) do
        local schema = assert(fields.schema(spec[1], server.version))
        local names = {}
        for name, definition in pairs(schema.fields) do
            if definition.supported then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        local projection = assert(metadata.projection(spec[1], server.version, names))
        local argv = { spec[3] }
        if spec[4] then
            argv[#argv + 1] = spec[4]
        end
        argv[#argv + 1], argv[#argv + 2] = "-F", assert(metadata.format(projection))
        local rows, err = metadata.decode(execute(argv), projection)
        assert(rows, tostring(err))
        listings[spec[2]] = rows
    end
    local snapshot, err = graph.build(generation, listings, {
        started = started,
        finished = runtime._driver.now(),
        strict = true,
    })
    assert(snapshot, tostring(err))
    assert(snapshot.complete and #snapshot.sessions == 2)
    assert(#snapshot.windows == 2 and #snapshot.raw.windows == 3)
    assert(#snapshot.panes == 2 and #snapshot.raw.panes == 3)
    assert(#snapshot.window_links == 3 and #snapshot.buffers == 1)
    local shared = assert(snapshot.windows:where({ id = window }):one())
    assert(#shared.window_links == 2 and #shared.panes == 1)
    assert(#snapshot.sessions:where({ window_links = { some = { window_id = window } } }) == 2)
    assert(snapshot.buffers[1].name == "graph-buffer" and snapshot.buffers[1].size == 6)
    local pane = shared.panes[1]
    local original_id = pane.id
    pane.id, pane.ref.id = "%999", "%998"
    local handle = assert(graph.handle(snapshot, pane))
    assert(identity.inspect(generation, handle).id == original_id)
    return "graph integration PASS " .. server.version
end)
assert(result, tostring(failure))
io.stdout:write(result, "\n")
