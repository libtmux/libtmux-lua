local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_SETTINGS_CASE"))

local function must(value, err)
    if err then
        error(tostring(err) .. " [" .. (err.code or "unknown") .. "]", 2)
    end
    return value
end

local function rejected(request, code)
    local value, err = request:await()
    assert(value == nil and err and err.code == code, tostring(err))
    assert(err.effect == "not_sent")
end

local function find(records, name)
    for _, record in ipairs(records) do
        if record.name == name then
            return record
        end
    end
    error("missing listing entry: " .. name)
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
        must(server:new_session({ name = "settings-fixture", argv = { "/bin/cat" } }):await())
    local session, window, pane = created.session, created.window, created.pane
    local sid = session:reference().id
    local global = { scope = "global_session" }
    local bytes = {}
    for byte = 1, 255 do
        bytes[#bytes + 1] = string.char(byte)
    end
    local literal = table.concat(bytes) .. " $TOKEN \\$TOKEN λ雪 %end 1 2 3\n"
    if mode == "scalar_bytes" then
        must(session:set_option("@literal", literal):await())
        local record = must(session:get_option("@literal"):await())
        assert(record.present and not record.inherited and record.value == literal)
        assert(record.scope == "session" and record.target.id == sid)
        record.value, record.target.id = "changed", "$999"
        assert(must(session:get_option("@literal"):await()).value == literal)
        must(session:set_option("@empty", ""):await())
        record = must(session:get_option("@empty"):await())
        assert(record.present and record.value == "")
        must(session:unset_option("@empty"):await())
        record = must(session:get_option("@empty", { inherit = false }):await())
        assert(not record.present and not record.inherited and record.value == nil)
        must(server:set_option("buffer-limit", 23):await())
        assert(must(server:get_option("buffer-limit"):await()).value == 23)
        local listed = must(session:list_options():await())
        assert(find(listed, "@literal").value == literal)
    elseif mode == "scalar_scopes" then
        must(server:set_option("mouse", false, global):await())
        local record = must(session:get_option("mouse"):await())
        assert(record.present and record.inherited and record.value == false)
        must(session:set_option("mouse", true):await())
        assert(must(session:get_option("mouse"):await()).value == true)
        must(session:unset_option("mouse"):await())
        record = must(session:get_option("mouse", { inherit = false }):await())
        assert(not record.present)
        rejected(pane:set_option("mouse", true), "invalid_scope")
        rejected(session:set_option("mouse", true, global), "invalid_scope")
        rejected(server:set_option("mouse", true), "invalid_scope")
        assert(must(server:get_option("mouse", global):await()).value == false)
        must(window:set_option("@level", "window"):await())
        must(pane:set_option("@level", "pane"):await())
        assert(must(window:get_option("@level"):await()).value == "window")
        assert(must(pane:get_option("@level"):await()).value == "pane")
        local listed = must(session:list_options():await())
        assert(find(listed, "mouse").value == false)
    elseif mode == "arrays" then
        local input =
            { entries = { { index = 9, value = literal }, { index = 2, value = "left" } } }
        local request = session:set_option("status-format", input)
        input.entries[1].value = "changed"
        must(request:await())
        local record = must(session:get_option("status-format"):await())
        assert(record.present and not record.inherited and #record.entries == 2)
        assert(record.entries[1].index == 2 and record.entries[1].value == "left")
        assert(record.entries[2].index == 9 and record.entries[2].value == literal)
        must(session:set_option("status-format", ":suffix", { index = 2, append = true }):await())
        record = must(session:get_option("status-format", { index = 2 }):await())
        assert(record.present and #record.entries == 1 and record.entries[1].value == "left:suffix")
        record = must(session:get_option("status-format", { index = 3 }):await())
        assert(not record.present and #record.entries == 0)
        must(session:unset_option("status-format", { index = 2 }):await())
        record = must(session:get_option("status-format"):await())
        assert(#record.entries == 1 and record.entries[1].index == 9)
        must(session:set_option("status-format", { entries = {} }):await())
        record = must(session:get_option("status-format"):await())
        assert(record.present and not record.inherited and #record.entries == 0)
        must(session:unset_option("status-format"):await())
        record = must(session:get_option("status-format", { inherit = false }):await())
        assert(not record.present and record.entries == nil)
        record = must(session:get_option("status-format"):await())
        assert(record.present and record.inherited and #record.entries > 0)
        local original =
            must(server:get_option("window-status-format", { scope = "global_window" }):await())
        must(
            server
                :set_option("window-status-format", "literal", { scope = "global_window" })
                :await()
        )
        assert(must(window:get_option("window-status-format"):await()).value == "literal")
        must(
            server
                :set_option("window-status-format", original.value, { scope = "global_window" })
                :await()
        )
    else
        local input = { commands = { { "set-option", "-t", sid, "@hook_value", literal } } }
        local request = session:set_hook("session-renamed", input, { index = 4 })
        input.commands[1][5] = "changed"
        must(request:await())
        must(session
            :set_hook("session-renamed", {
                commands = { { "set-option", "-t", sid, "@hook_appended", "yes" } },
            }, { append = true })
            :await())
        if mode == "hook_storage" then
            local record = must(session:get_hook("session-renamed"):await())
            assert(record.present and not record.inherited and #record.entries == 2)
            assert(record.entries[1].index == 0 and record.entries[2].index == 4)
            assert(record.entries[2].source:find("set-option", 1, true))
            local canonical = record.entries[2].source
            record.entries[2].source = "changed"
            record = must(session:get_hook("session-renamed", { index = 4 }):await())
            assert(#record.entries == 1 and record.entries[1].source == canonical)
            rejected(
                pane:set_hook("session-renamed", { source = "display-message bad" }),
                "invalid_scope"
            )
            assert(#find(must(session:list_hooks():await()), "session-renamed").entries == 2)
            must(session:unset_hook("session-renamed", { index = 0 }):await())
            record = must(session:get_hook("session-renamed"):await())
            assert(#record.entries == 1 and record.entries[1].index == 4)
            must(
                server
                    :set_hook(
                        "session-renamed",
                        { source = "display-message -p inherited" },
                        global
                    )
                    :await()
            )
            local inherited = must(server:get_hook("session-renamed", global):await())
            assert(inherited.present and not inherited.inherited and #inherited.entries == 1)
            must(session:unset_hook("session-renamed"):await())
            assert(
                not must(session:get_hook("session-renamed", { inherit = false }):await()).present
            )
            record = must(session:get_hook("session-renamed"):await())
            assert(record.present and record.inherited and #record.entries == 1)
            assert(record.entries[1].source == inherited.entries[1].source)
        else
            assert(mode == "hook_execution")
            rejected(
                session:run_hook("session-renamed", { scope = "global_session" }),
                "invalid_options"
            )
            must(session:run_hook("session-renamed"):await())
            assert(must(session:get_option("@hook_value"):await()).value == literal)
            assert(must(session:get_option("@hook_appended"):await()).value == "yes")
            must(session
                :set_hook("@custom_hook", {
                    commands = { { "set-option", "-t", sid, "@custom_value", "custom" } },
                })
                :await())
            local record = must(session:get_hook("@custom_hook"):await())
            assert(record.present and type(record.source) == "string")
            if os.getenv("TMUX_DAEMON_VERSION") == "3.2a" then
                rejected(session:run_hook("@custom_hook"), "unsupported")
                local absent =
                    must(session:get_option("@custom_value", { inherit = false }):await())
                assert(not absent.present)
            else
                must(session:run_hook("@custom_hook"):await())
                assert(must(session:get_option("@custom_value"):await()).value == "custom")
            end
            must(session:unset_hook("@custom_hook"):await())
            assert(not must(session:get_hook("@custom_hook", { inherit = false }):await()).present)
        end
    end
    must(server:close():await())
    return "public settings " .. mode .. " PASS"
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
