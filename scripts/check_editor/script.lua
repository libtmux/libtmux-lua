-- The program the editor check types into a LuaLS document, and the completions it expects at each
-- cursor position. Each `complete` call records where the cursor sits after the line it adds.
local M = {}

---@class check_editor.Check
---@field line integer zero-based
---@field character integer
---@field required string[]
---@field forbidden string[]

---@class check_editor.Document
---@field lines string[]
---@field checks check_editor.Check[]
local Document = {}
Document.__index = Document

--- Adds lines to the document.
---@param ... string
function Document:add(...)
    for _, line in ipairs({ ... }) do
        self.lines[#self.lines + 1] = line
    end
end

--- Adds a line that ends at the cursor, and the completions expected after it.
---@param line string
---@param required string[]
---@param forbidden? string[]
function Document:complete(line, required, forbidden)
    self.checks[#self.checks + 1] = {
        line = #self.lines,
        character = #line,
        required = required,
        forbidden = forbidden or {},
    }
    self.lines[#self.lines + 1] = line
end

--- The lines and checks that come before the adapter programs: the query builder and the field
--- types.
---@return check_editor.Document
local function query_document()
    return setmetatable({
        lines = {
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
        },
        checks = {
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
        },
    }, Document)
end

--- Opens an adapter's program and connects to a server.
---@param doc check_editor.Document
---@param adapter string
---@param entry string
local function connect(doc, adapter, entry)
    doc:add(
        ('local %s = require("libtmux.runtime.%s")'):format(adapter, adapter),
        ("%s%s.%s(function(runtime)"):format(
            adapter == "luv" and "local run_result = " or "",
            adapter,
            entry
        )
    )
    doc:complete("  runtime:", { "connect", "close", "spawn", "stats" })
    doc:add(
        '  local pending = runtime:connect({binary="/usr/bin/tmux",'
            .. 'socket_path="/tmp/owned.sock"})'
    )
    doc:complete("  pending:", { "await", "cancel", "result", "on_complete" })
    doc:add("  local server = assert(pending:await())")
    doc:complete("  server:", {
        "capabilities",
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
    doc:add("  local discovery = server:capabilities()")
    doc:complete("  discovery:", { "await", "cancel", "result", "on_complete" })
    doc:add("  local capabilities = assert(discovery:await())")
    doc:complete("  capabilities.", { "version", "features", "workarounds" })
    doc:add('  local feature = capabilities.features["layout-json"]')
    doc:complete("  feature.", { "id", "since", "except", "supported", "apis", "commands" })
    doc:add('  local workaround = capabilities.workarounds["name-separators-rejected"]')
    doc:complete("  workaround.", { "id", "releases", "required", "active", "handling" })
end

--- A buffer, a created session and the objects it holds: session, window and window link.
---@param doc check_editor.Document
local function created_objects(doc)
    doc:add('  local buffer_value = assert(server:show_buffer("clipboard"):await())')
    doc:complete("  buffer_value.", { "name", "bytes", "text" })
    doc:add('  local created = assert(server:new_session({argv={"/bin/cat"}}):await())')
    doc:complete("  created.", { "session", "window", "pane", "window_link", "created" })
    doc:add("  local created_session = created.session")
    doc:complete("  created_session:", {
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
    doc:add("  local created_window = created.window")
    doc:complete(
        "  created_window:",
        { "rename", "kill", "resize", "layout", "respawn" },
        { "new_window", "send_keys", "get_environment", "unlink" }
    )
    doc:add("  local created_link = created.window_link")
    doc:complete(
        "  created_link:",
        { "select", "link", "move", "swap", "unlink", "reference" },
        { "get_option", "rename", "kill", "send_keys" }
    )
end

--- The option, hook and environment records of the created session.
---@param doc check_editor.Document
local function records(doc)
    doc:add('  local option_record = assert(created_session:get_option("mouse"):await())')
    doc:complete(
        "  option_record.",
        { "name", "present", "inherited", "value", "entries", "target" }
    )
    doc:add('  local hook_record = assert(created_session:get_hook("session-renamed"):await())')
    doc:complete("  hook_record.", { "present", "inherited", "source", "entries" })
    doc:add('  local environment_record = assert(created_session:get_environment("APP"):await())')
    doc:complete(
        "  environment_record.",
        { "name", "state", "hidden", "value", "scope", "inherited" }
    )
end

--- An observation of the session: its coverage, a pane watch and an event.
---@param doc check_editor.Document
local function observation(doc)
    doc:add("  local observation = assert(server:observe(created_session):await())")
    doc:complete(
        "  observation:",
        { "watch_pane", "watch_notifications", "subscribe_format", "coverage", "close" }
    )
    doc:add("  local coverage = assert(observation:coverage())")
    doc:complete("  coverage.", { "session_id", "panes", "generation", "ready" })
    doc:add("  local watch = assert(observation:watch_pane(created.pane):await())")
    doc:complete("  watch:", { "next", "close" })
    doc:add("  local event = assert(watch:next():await())")
    doc:complete("  event.", { "kind", "data", "generation", "sequence" })
end

--- The created pane, a capture of it and the text of the capture.
---@param doc check_editor.Document
local function pane_calls(doc)
    doc:add("  local created_pane = created.pane")
    doc:complete("  created_pane:", {
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
    doc:add("  local pane_capture_request = created_pane:capture({history_lines=20})")
    doc:complete("  pane_capture_request:", { "await", "cancel", "result", "on_complete" })
    doc:add("  local pane_capture = assert(pane_capture_request:await())")
    doc:complete("  pane_capture.", { "bytes", "target", "text" })
    doc:add("  local pane_text = assert(pane_capture:text())")
    doc:complete("  pane_text:", { "byte", "sub", "find" })
end

--- A pane query, a snapshot and a handle to one of its panes, then a raw command.
---@param doc check_editor.Document
local function query_and_snapshot(doc)
    doc:add("  local queried = assert(server:query_panes({where={active=true}}):await())")
    doc:complete("  queried.", { "rows", "snapshot", "plan", "complete", "races", "acquisition" })
    doc:add("  local match = queried.rows:first()", "  if match then")
    doc:complete("    match.", { "id", "active", "current_path", "window" })
    doc:add("  end", "  local capture = server:snapshot()")
    doc:complete("  capture:", { "await", "cancel", "result", "on_complete" })
    doc:add("  local snapshot = assert(capture:await())")
    doc:complete("  snapshot.", { "panes", "windows", "window_links", "sessions", "complete" })
    doc:add("  local pane = snapshot.panes:where({active=true}):first()", "  if pane then")
    doc:complete("    pane.", { "id", "active", "current_path", "window" })
    doc:add("    local window = pane.window", "    if window then")
    doc:complete("      window.", { "id", "name", "panes", "window_links" })
    doc:add("    end", "    local handle = assert(server:handle(snapshot, pane))")
    doc:complete(
        "    handle:",
        { "snapshot", "reference", "send_keys", "capture", "split" },
        { "new_window", "unlink", "get_environment" }
    )
    doc:add("    local refreshed = assert(handle:snapshot():await())")
    doc:complete("    refreshed.", { "id", "title", "window_id", "window" })
    doc:add(
        "  end",
        '  local command = assert(server:command({"display-message", "-p", "ok"}):await())'
    )
    doc:complete("  command.", { "stdout", "stderr", "exit_code", "signal" })
    doc:add("  return snapshot")
end

--- Closes an adapter's program; the luv one also checks what its loop returned.
---@param doc check_editor.Document
---@param adapter string
local function close_program(doc, adapter)
    if adapter == "nvim" then
        doc:add("end, function(value, err) end)")
    else
        doc:add("end)", "if run_result then")
        doc:complete("  run_result.", { "panes", "sessions", "complete" })
        doc:add("end")
    end
end

--- Builds the document's lines and the checks over them.
---@return string[] lines
---@return check_editor.Check[] checks
function M.build()
    local doc = query_document()
    for _, host in ipairs({ { "luv", "run" }, { "nvim", "start" } }) do
        connect(doc, host[1], host[2])
        created_objects(doc)
        records(doc)
        observation(doc)
        pane_calls(doc)
        query_and_snapshot(doc)
        close_program(doc, host[1])
    end
    return doc.lines, doc.checks
end

return M
