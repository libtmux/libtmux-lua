local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_ENVIRONMENT_CASE"))

local function must(value, err)
    assert(value ~= nil, tostring(err))
    return value
end

local function entry(rows, name)
    for _, row in ipairs(rows) do
        if row.name == name then
            return row
        end
    end
end

local function work(runtime)
    local server = must(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
            config_path = "/dev/null",
        })
        :await())
    local created =
        must(server:new_session({ name = "environment-fixture", argv = { "/bin/cat" } }):await())
    local session = created.session
    local name = "LIBTMUX_ENVIRONMENT_VALUE"
    if mode == "values" then
        local parts = {}
        for byte = 1, 255 do
            parts[#parts + 1] = string.char(byte)
        end
        local literal = table.concat(parts) .. "$TOKEN $_ ${x} \\$TOKEN\n%end 1 2 3\n"
        must(server:set_environment(name, literal):await())
        local record = must(server:get_environment(name):await())
        assert(record.state == "value" and record.value == literal and not record.hidden)
        assert(record.scope == "global" and not record.inherited)
        record = must(session:get_environment(name):await())
        assert(record.state == "absent" and record.scope == "session" and not record.inherited)
        record = must(session:get_environment(name, { inherit = true }):await())
        assert(record.value == literal and record.inherited and record.scope == "global")
        must(session:set_environment(name, "", { hidden = true }):await())
        record = must(session:get_environment(name, { inherit = true }):await())
        assert(
            record.state == "value"
                and record.value == ""
                and record.hidden
                and not record.inherited
        )
        must(session:remove_environment(name):await())
        record = must(session:get_environment(name, { inherit = true }):await())
        assert(
            record.state == "removed"
                and record.hidden
                and record.value == nil
                and not record.inherited
        )
        must(session:unset_environment(name):await())
        record = must(session:get_environment(name, { inherit = true }):await())
        assert(record.value == literal and record.inherited)
        must(session:set_environment(name, "visible", { hidden = true }):await())
        must(session:set_environment(name, "visible"):await())
        assert(not must(session:get_environment(name):await()).hidden)
        local pane = created.pane
        local value, err = pane:set_environment(name, "wrong scope"):await()
        assert(value == nil and err.code == "invalid_scope" and err.effect == "not_sent")
    elseif mode == "listing" then
        must(server:set_environment(name, "global"):await())
        must(session:set_environment(name, "hidden", { hidden = true }):await())
        local rows =
            must(session:list_environment({ inherit = true, include_hidden = false }):await())
        assert(entry(rows, name) == nil)
        rows = must(session:list_environment({ inherit = true }):await())
        local record = assert(entry(rows, name))
        assert(record.hidden and record.value == "hidden" and not record.inherited)
        must(session:remove_environment(name):await())
        rows = must(session:list_environment():await())
        record = assert(entry(rows, name))
        assert(record.state == "removed" and record.hidden)
        local raw = must(server
            :command({
                "set-environment",
                "-g",
                "-r",
                "--",
                "LIBTMUX_COLLISION_A;\nunset LIBTMUX_COLLISION_B",
            })
            :await())
        assert(raw.exit_code == 0)
        local value, err = server:list_environment():await()
        assert(
            value == nil and err.code == "inconsistent" and err.effect == "completed",
            tostring(err)
        )
    end
    must(server:close():await())
    return "public environment " .. mode .. " PASS"
end

if host then
    adapter.start(work, function(value, err)
        if not value then
            io.stderr:write(tostring(err), "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(value, "\n")
            host.cmd("qa!")
        end
    end)
else
    print(must(adapter.run(work)))
end
