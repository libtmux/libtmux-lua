local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end

local function work(runtime)
    local server = must(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
        })
        :await())
    local where = {
        active = false,
        window = { is = { panes = { some = { active = true } } } },
    }
    local options =
        { where = where, snapshot = { fields = { panes = { "id" }, windows = { "id" } } } }
    local explained = must(server:explain_panes(options):await())
    assert(not explained.exact and explained.filter == "#{==:#{pane_active},0}")
    assert(#explained.commands == 7 and explained.commands[7].role == "candidates")
    local result = must(server:query_panes(options):await())
    local expected = result.snapshot.panes:where(where)
    assert(result.complete and #result.rows == 2 and #expected == 2)
    assert(#result.snapshot.raw.panes == 6 and #result.snapshot.panes == 3)
    for index, row in ipairs(result.rows) do
        assert(row == expected[index] and row.active == false and #row.window.panes == 3)
        assert(row.title == nil)
    end
    local unsupported, err = server:query_panes({ where = where, pushdown = "require" }):await()
    assert(not unsupported and err.code == "unsupported_pushdown" and err.effect == "not_sent")
    local native = must(server:query_panes({ native_filter = "#{pane_active}" }):await())
    assert(#native.rows == 1 and native.rows[1].active and native.plan.native_filter)
    assert(native.complete and native.plan.exact == false)
    must(server:close():await())
    return "public live query PASS"
end

if host then
    adapter.start(work, function(value, err)
        if err then
            io.stderr:write(tostring(err), "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(value, "\n")
            host.cmd("qa!")
        end
    end, { max_active = 1 })
else
    print(must(adapter.run(work, { max_active = 1 })))
end
