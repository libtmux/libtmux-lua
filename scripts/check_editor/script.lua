-- The program the editor check types into a LuaLS document, and the completions it expects at each
-- cursor position. Each `complete` call records where the cursor sits after the line it adds.
local M = {}

---@class check_editor.Check
---@field line integer zero-based
---@field character integer
---@field required string[]
---@field forbidden string[]

--- Builds the document's lines and the checks over them.
---@return string[] lines
---@return check_editor.Check[] checks
function M.build()
    local lines = {
        'local query = require("libtmux.query")',
        'local rows = {{id="%1", active=true}}',
        'local schema = {fields={id={type="string"},active={type="boolean"}}}',
        "local selected = query.select(rows, schema):where({active=true})",
        "selected:",
        "local first = selected:first()",
        "if first then",
        "  first.",
        "end",
        "---@type libtmux.Fields.Pane",
        "local pane = {}",
        "pane.",
        "---@type libtmux.Fields.WindowLink",
        "local link = {}",
        "link.",
    }
    local checks = {
        {
            line = 4,
            character = 9,
            required = { "where", "filter", "first", "one", "count" },
            forbidden = {},
        },
        { line = 7, character = 8, required = { "id", "active" }, forbidden = {} },
        {
            line = 11,
            character = 5,
            required = { "id", "active", "current_path", "dead_status" },
            forbidden = {},
        },
        {
            line = 14,
            character = 5,
            required = { "session_id", "window_id", "index", "active" },
            forbidden = {},
        },
    }
    local function add(...)
        for _, line in ipairs({ ... }) do
            lines[#lines + 1] = line
        end
    end
    local function complete(line, required, forbidden)
        checks[#checks + 1] = {
            line = #lines,
            character = #line,
            required = required,
            forbidden = forbidden or {},
        }
        lines[#lines + 1] = line
    end
    for _, host in ipairs({ { "luv", "run" }, { "nvim", "start" } }) do
        local adapter, entry = host[1], host[2]
        add(
            ('local %s = require("libtmux.runtime.%s")'):format(adapter, adapter),
            ("%s%s.%s(function(runtime)"):format(
                adapter == "luv" and "local run_result = " or "",
                adapter,
                entry
            )
        )
        complete("  runtime:", { "connect", "close", "spawn", "stats" })
        add(
            '  local pending = runtime:connect({binary="/usr/bin/tmux",'
                .. 'socket_path="/tmp/owned.sock"})'
        )
        complete("  pending:", { "await", "cancel", "result", "on_complete" })
        add("  local server = assert(pending:await())")
        complete("  server:", {
            "snapshot",
            "close",
            "handle",
            "command",
            "group",
            "batch",
            "new_session",
            "query_panes",
            "explain_panes",
            "get_option",
            "list_options",
            "set_option",
            "get_hook",
            "set_hook",
            "get_environment",
            "list_environment",
            "set_buffer",
            "show_buffer",
            "delete_buffer",
        })
        add('  local buffer_value = assert(server:show_buffer("clipboard"):await())')
        complete("  buffer_value.", { "name", "bytes", "text" })
        add('  local created = assert(server:new_session({argv={"/bin/cat"}}):await())')
        complete("  created.", { "session", "window", "pane", "window_link", "created" })
        add("  local created_session = created.session")
        complete("  created_session:", {
            "new_window",
            "reference",
            "get_option",
            "set_hook",
            "run_hook",
            "get_environment",
            "rename",
            "kill",
            "navigate_window",
            "renumber_windows",
        }, { "send_keys", "split", "capture", "layout", "unlink" })
        add("  local created_window = created.window")
        complete(
            "  created_window:",
            { "rename", "kill", "resize", "layout", "respawn" },
            { "new_window", "send_keys", "get_environment", "unlink" }
        )
        add("  local created_link = created.window_link")
        complete(
            "  created_link:",
            { "select", "link", "move", "swap", "unlink", "reference" },
            { "get_option", "rename", "kill", "send_keys" }
        )
        add('  local option_record = assert(created_session:get_option("mouse"):await())')
        complete(
            "  option_record.",
            { "name", "present", "inherited", "value", "entries", "target" }
        )
        add('  local hook_record = assert(created_session:get_hook("session-renamed"):await())')
        complete("  hook_record.", { "present", "inherited", "source", "entries" })
        add('  local environment_record = assert(created_session:get_environment("APP"):await())')
        complete(
            "  environment_record.",
            { "name", "state", "hidden", "value", "scope", "inherited" }
        )
        add("  local observation = assert(server:observe(created_session):await())")
        complete(
            "  observation:",
            { "watch_pane", "watch_notifications", "subscribe_format", "coverage", "close" }
        )
        add("  local coverage = assert(observation:coverage())")
        complete("  coverage.", { "session_id", "panes", "generation", "ready" })
        add("  local watch = assert(observation:watch_pane(created.pane):await())")
        complete("  watch:", { "next", "close" })
        add("  local event = assert(watch:next():await())")
        complete("  event.", { "kind", "data", "generation", "sequence" })
        add("  local created_pane = created.pane")
        complete("  created_pane:", {
            "split",
            "reference",
            "capture",
            "send_text",
            "send_keys",
            "copy_mode",
            "copy_command",
            "resize",
            "kill",
            "respawn",
            "select",
            "set_title",
            "swap",
            "paste_buffer",
            "move_to",
            "break_out",
        }, { "new_window", "rename", "layout", "get_environment", "link" })
        add("  local pane_capture_request = created_pane:capture({history_lines=20})")
        complete("  pane_capture_request:", { "await", "cancel", "result", "on_complete" })
        add("  local pane_capture = assert(pane_capture_request:await())")
        complete("  pane_capture.", { "bytes", "target", "text" })
        add("  local pane_text = assert(pane_capture:text())")
        complete("  pane_text:", { "byte", "sub", "find" })
        add("  local queried = assert(server:query_panes({where={active=true}}):await())")
        complete("  queried.", { "rows", "snapshot", "plan", "complete", "races", "acquisition" })
        add("  local match = queried.rows:first()", "  if match then")
        complete("    match.", { "id", "active", "current_path", "window" })
        add("  end", "  local capture = server:snapshot()")
        complete("  capture:", { "await", "cancel", "result", "on_complete" })
        add("  local snapshot = assert(capture:await())")
        complete("  snapshot.", { "panes", "windows", "window_links", "sessions", "complete" })
        add("  local pane = snapshot.panes:where({active=true}):first()", "  if pane then")
        complete("    pane.", { "id", "active", "current_path", "window" })
        add("    local window = pane.window", "    if window then")
        complete("      window.", { "id", "name", "panes", "window_links" })
        add("    end", "    local handle = assert(server:handle(snapshot, pane))")
        complete(
            "    handle:",
            { "snapshot", "reference", "send_keys", "capture", "split" },
            { "new_window", "unlink", "get_environment" }
        )
        add("    local refreshed = assert(handle:snapshot():await())")
        complete("    refreshed.", { "id", "title", "window_id", "window" })
        add(
            "  end",
            '  local command = assert(server:command({"display-message", "-p", "ok"}):await())'
        )
        complete("  command.", { "stdout", "stderr", "exit_code", "signal" })
        add("  return snapshot")
        if adapter == "nvim" then
            add("end, function(value, err) end)")
        else
            add("end)", "if run_result then")
            complete("  run_result.", { "panes", "sessions", "complete" })
            add("end")
        end
    end
    return lines, checks
end

return M
