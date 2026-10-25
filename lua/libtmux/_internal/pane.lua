local utf8 = require("libtmux._internal.text").valid_utf8
local errors = require("libtmux._internal.error")
local fields = require("libtmux._internal.fields")
local execution = require("libtmux._internal.execution")
local identity = require("libtmux._internal.identity")
local process = require("libtmux._internal.process")
local domain = require("libtmux._internal.domain")
local buffer = require("libtmux._internal.buffer")
local registry = require("libtmux._internal.support.capabilities")
local M, Capture = {}, {}
local commands = {
    capture = "capture-pane",
    capture_to_buffer = "capture-pane",
    clear_history = "clear-history",
    send_text = "send-keys",
    send_keys = "send-keys",
    copy_mode = "copy-mode",
    copy_command = "send-keys",
    resize = "resize-pane",
    kill = "kill-pane",
    respawn = "respawn-pane",
    select = "select-pane",
    set_title = "select-pane",
    swap = "swap-pane",
}
local allowed = {
    capture = {
        history_lines = true,
        start_line = true,
        end_line = true,
        join_lines = true,
        preserve_spaces = true,
        escape_sequences = true,
        escape_nonprintable = true,
        alternate_screen = true,
        mode_screen = true,
        trim_empty_cells = true,
        pending_escape_sequences = true,
        ignore_missing_alternate = true,
        hyperlinks_only = true,
        line_numbers = true,
        line_flags = true,
    },
    clear_history = { clear_hyperlinks = true },
    send_text = {},
    send_keys = { repeat_count = true },
    copy_mode = { page_up = true },
    copy_command = { repeat_count = true },
    resize = { width = true, height = true, direction = true, amount = true },
    kill = {},
    respawn = { kill = true, argv = true, shell = true, cwd = true, environment = true },
    select = { keep_zoom = true },
    set_title = {},
    swap = { select = true, keep_zoom = true },
}
allowed.capture_to_buffer = allowed.capture

local function failure(code, message, kind, effect, details)
    details = details or {}
    details.operation, details.effect = "pane." .. kind, effect or "not_sent"
    return errors.new(code, message, details)
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

function Capture:text()
    if not utf8(self.bytes) then
        return nil,
            failure("invalid_utf8", "capture contains invalid UTF-8", "capture", "completed")
    end
    return self.bytes
end

local keys = {}
for name in
    (
        "Enter Escape Tab BTab Space BSpace Up Down Left Right Home End Insert IC Delete DC "
        .. "NPage PageDown PgDn PPage PageUp PgUp KP/ KP* KP- KP7 KP8 KP9 KP+ KP4 "
        .. "KP5 KP6 KP1 KP2 KP3 KPEnter KP0 KP."
    ):gmatch("%S+")
do
    keys[name:lower()] = true
end
for index = 1, 12 do
    keys["f" .. index] = true
end

local function deferred_key(base)
    base = base:lower()
    if base:match("^user%d+$") or #base == 1 then
        return true
    end
    for _, suffix in ipairs({
        "pane",
        "status",
        "statusleft",
        "statusright",
        "statusdefault",
        "border",
        "scrollbarup",
        "scrollbarslider",
        "scrollbardown",
        "control0",
        "control1",
        "control2",
        "control3",
        "control4",
        "control5",
        "control6",
        "control7",
        "control8",
        "control9",
    }) do
        if base:sub(-#suffix) == suffix then
            local prefix = base:sub(1, -#suffix - 1)
            if prefix == "wheelup" or prefix == "wheeldown" then
                return true
            end
            for _, action in ipairs({
                "mousedown",
                "mouseup",
                "mousedrag",
                "mousedragend",
                "secondclick",
                "doubleclick",
                "tripleclick",
            }) do
                local number = prefix:match("^" .. action .. "(%d+)$")
                local button = tonumber(number)
                if button and (button >= 1 and button <= 3 or button >= 6 and button <= 11) then
                    return true
                end
            end
        end
    end
    return false
end

local actions = {}
for name in
    (
        "cancel begin-selection clear-selection stop-selection select-line select-word "
        .. "cursor-up cursor-down cursor-left cursor-right start-of-line end-of-line "
        .. "back-to-indentation "
        .. "page-up page-down halfpage-up halfpage-down history-top history-bottom "
        .. "top-line bottom-line "
        .. "middle-line scroll-up scroll-down next-word next-word-end previous-word "
        .. "next-space next-space-end "
        .. "previous-space next-paragraph previous-paragraph other-end rectangle-on rectangle-off "
        .. "rectangle-toggle set-mark jump-to-mark search-again search-reverse refresh-from-pane"
    ):gmatch("%S+")
do
    actions[name] = 0
end
for name in
    (
        "search-forward search-backward search-forward-text search-backward-text "
        .. "jump-forward jump-backward jump-to-forward jump-to-backward goto-line"
    ):gmatch("%S+")
do
    actions[name] = 1
end
local deferred_actions = {}
for name in
    (
        "append-selection append-selection-and-cancel copy-end-of-line copy-line "
        .. "copy-pipe-no-clear "
        .. "copy-pipe copy-pipe-and-cancel copy-selection-no-clear copy-selection "
        .. "copy-selection-and-cancel "
        .. "cursor-down-and-cancel halfpage-down-and-cancel page-down-and-cancel "
        .. "pipe-no-clear pipe pipe-and-cancel "
        .. "scroll-down-and-cancel search-backward-incremental "
        .. "search-forward-incremental jump-again jump-reverse "
        .. "next-matching-bracket previous-matching-bracket "
        .. "copy-end-of-line-and-cancel copy-pipe-end-of-line "
        .. "copy-pipe-end-of-line-and-cancel copy-line-and-cancel copy-pipe-line "
        .. "copy-pipe-line-and-cancel "
        .. "cursor-centre-vertical cursor-centre-horizontal next-prompt "
        .. "previous-prompt recentre-top-bottom "
        .. "scroll-bottom scroll-exit-on scroll-exit-off scroll-exit-toggle "
        .. "scroll-middle scroll-to-mouse "
        .. "scroll-top selection-mode toggle-position"
    ):gmatch("%S+")
do
    deferred_actions[name] = true
end

local function current(state, owned, kind)
    if state.closed then
        return nil, failure("closed", "server handle is closed", kind)
    end
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    local ref
    ref, err = identity.inspect(generation, owned)
    if not ref then
        return nil, err
    end
    if ref.kind ~= "pane" then
        return nil, failure("invalid_target", "operation requires a pane handle", kind)
    end
    return ref
end

local function prepare(state, ref, kind, data, options, inspect)
    local function invalid(message, code)
        error(failure(code or "invalid_options", message, kind), 0)
    end
    if options == nil then
        options = {}
    end
    if not plain(options) then
        invalid("pane options must be a plain record")
    end
    for key in next, options do
        if key ~= "process" and not allowed[kind][key] then
            invalid("unknown pane option")
        end
    end
    local argv = { commands[kind], "-t", ref.id }
    local function flag(name, value)
        argv[#argv + 1] = name
        if value ~= nil then
            argv[#argv + 1] = tostring(value)
        end
    end
    local function boolean(name, argument, minimum)
        local value = options[name]
        if value ~= nil and type(value) ~= "boolean" then
            invalid(name .. " must be boolean")
        end
        if value then
            if minimum and not fields.at_least(state.version, minimum) then
                invalid(name .. " is unavailable on this tmux version", "unsupported")
            end
            flag(argument)
        end
    end
    local function string_value(value, maximum)
        if type(value) ~= "string" or #value > maximum or value:find("\000", 1, true) then
            invalid("arguments must be bounded NUL-free strings", "invalid_argument")
        end
        return value
    end
    local function sequence(value, maximum)
        if not plain(value) then
            invalid("arguments must be a plain dense sequence", "invalid_argument")
        end
        local count = 0
        for key in next, value do
            count = count + 1
            if not integer(key, 1, maximum) or count > maximum then
                invalid("argument sequence exceeds its limit", "invalid_argument")
            end
        end
        local copied = {}
        for index = 1, count do
            copied[index] = string_value(rawget(value, index), 65536)
        end
        return copied
    end
    local function repeat_count()
        if options.repeat_count ~= nil then
            if not integer(options.repeat_count, 1, 1000) then
                invalid("repeat_count must be an integer from 1 to 1000")
            end
            flag("-N", options.repeat_count)
        end
    end
    if kind == "capture" or kind == "capture_to_buffer" then
        if kind == "capture" then
            flag("-p")
        else
            if not buffer.valid_creation_name(data) then
                invalid(
                    "buffer name needs UTF-8 without controls or backslashes (1 to 4096 bytes)",
                    "unsupported_name"
                )
            end
            flag("-b", data)
        end
        if options.pending_escape_sequences then
            for key, value in next, options do
                if
                    key ~= "pending_escape_sequences"
                    and key ~= "escape_nonprintable"
                    and key ~= "process"
                    and value ~= false
                then
                    invalid("pending_escape_sequences accepts only escape_nonprintable and process")
                end
            end
        end
        if options.ignore_missing_alternate and not options.alternate_screen then
            invalid("ignore_missing_alternate requires alternate_screen")
        end
        if options.hyperlinks_only then
            for _, name in ipairs({
                "escape_sequences",
                "escape_nonprintable",
                "preserve_spaces",
                "trim_empty_cells",
            }) do
                if options[name] then
                    invalid("hyperlinks_only cannot be combined with " .. name)
                end
            end
        end
        if options.history_lines ~= nil then
            if
                not integer(options.history_lines, 0, 1000000)
                or options.start_line ~= nil
                or options.end_line ~= nil
            then
                invalid(
                    "history_lines must be bounded and cannot be combined with an explicit range"
                )
            end
            flag("-S", -options.history_lines)
        else
            for _, range in ipairs({ { "start_line", "-S" }, { "end_line", "-E" } }) do
                local value = options[range[1]]
                if value ~= nil then
                    if value ~= "-" and not integer(value, -2147483647, 32767) then
                        invalid("capture range must be an integer or '-'")
                    end
                    flag(range[2], value)
                end
            end
        end
        if
            options.alternate_screen
            and (
                options.mode_screen
                or options.history_lines ~= nil
                or options.start_line ~= nil
                or options.end_line ~= nil
            )
        then
            invalid("alternate_screen cannot be combined with history, ranges or mode_screen")
        end
        for _, item in ipairs({
            { "join_lines", "-J" },
            { "preserve_spaces", "-N" },
            { "escape_sequences", "-e" },
            { "escape_nonprintable", "-C" },
            { "alternate_screen", "-a" },
            { "mode_screen", "-M", "3.6" },
            { "trim_empty_cells", "-T", registry.since("capture-trim-blank-cells") },
            { "pending_escape_sequences", "-P" },
            { "ignore_missing_alternate", "-q" },
            { "hyperlinks_only", "-H", "3.7" },
            { "line_numbers", "-L", "3.7" },
            { "line_flags", "-F", registry.since("capture-line-flags") },
        }) do
            boolean(item[1], item[2], item[3])
        end
    elseif kind == "clear_history" then
        boolean("clear_hyperlinks", "-H", "3.4")
    elseif kind == "send_text" then
        string_value(data, 65536)
        if not utf8(data) then
            invalid("send_text requires valid UTF-8", "invalid_utf8")
        end
        flag("-l")
        flag("--")
        flag(data)
    elseif kind == "send_keys" then
        local names = sequence(data, 1024)
        if #names == 0 then
            invalid("send_keys needs at least one key", "invalid_key")
        end
        for _, name in ipairs(names) do
            if #name > 64 then
                invalid("key name exceeds 64 bytes", "invalid_key")
            end
            local base, modified = name, false
            while base:match("^[CMScms]%-") do
                base, modified = base:sub(3), true
            end
            if
                not keys[base:lower()]
                and not (modified and #base == 1 and base:byte() >= 32 and base:byte() <= 126)
            then
                if deferred_key(base) then
                    invalid("this native key category is not implemented", "unsupported")
                end
                invalid("unrecognized named key", "invalid_key")
            end
        end
        repeat_count()
        flag("--")
        for _, name in ipairs(names) do
            flag(name)
        end
    elseif kind == "copy_mode" then
        boolean("page_up", "-u")
    elseif kind == "copy_command" then
        local action = data.action
        if type(action) ~= "string" or not actions[action] then
            if deferred_actions[action] then
                invalid("copy-mode action is not implemented", "unsupported")
            end
            invalid("unrecognized copy-mode action", "invalid_copy_command")
        end
        local args = sequence(data.args == nil and {} or data.args, 16)
        if #args ~= actions[action] then
            invalid("copy-mode action has the wrong argument count", "invalid_copy_command")
        end
        if
            action == "goto-line"
            and (not args[1]:match("^%d+$") or not integer(tonumber(args[1]), 0, 2147483647))
        then
            invalid("goto-line needs a nonnegative decimal line number", "invalid_copy_command")
        end
        flag("-X")
        repeat_count()
        flag("--")
        flag(action)
        for _, arg in ipairs(args) do
            flag(arg)
        end
    elseif kind == "select" then
        boolean("keep_zoom", "-Z")
    elseif kind == "set_title" then
        string_value(data, 65536)
        if not utf8(data) then
            invalid("pane title requires valid UTF-8", "invalid_utf8")
        end
        if data:find("[%z\001-\031\127]") then
            invalid("pane title cannot contain ASCII control bytes", "invalid_argument")
        end
        if data == "" and fields.exactly(state.version, "3.7") then
            invalid("tmux 3.7 silently ignores an empty pane title", "unsupported")
        end
        flag("-T", (data:gsub("#", "##")))
    elseif kind == "swap" then
        local target, err = inspect(state, data, "pane")
        if not target then
            error(err, 0)
        end
        if target.id == ref.id then
            invalid("swap requires two different panes", "invalid_target")
        end
        if options.select ~= nil and type(options.select) ~= "boolean" then
            invalid("select must be boolean")
        end
        argv[3] = target.id
        flag("-s", ref.id)
        if not options.select then
            flag("-d")
        end
        boolean("keep_zoom", "-Z")
    elseif kind == "respawn" then
        boolean("kill", "-k")
        domain.append_launch(argv, options, invalid)
    elseif kind == "resize" then
        local directions = { left = "-L", right = "-R", up = "-U", down = "-D" }
        if options.direction ~= nil then
            if
                not directions[options.direction]
                or options.width ~= nil
                or options.height ~= nil
            then
                invalid("resize direction cannot be combined with dimensions")
            end
            local amount = options.amount == nil and 1 or options.amount
            if not integer(amount, 1, 65535) then
                invalid("resize amount must be a positive bounded integer")
            end
            flag(directions[options.direction], amount)
        else
            if options.amount ~= nil or options.width == nil and options.height == nil then
                invalid("resize needs dimensions or a direction")
            end
            for _, item in ipairs({ { "width", "-x" }, { "height", "-y" } }) do
                local value = options[item[1]]
                if value ~= nil then
                    if not integer(value, 1, 65535) then
                        invalid("pane dimensions must be positive bounded integers")
                    end
                    flag(item[2], value)
                end
            end
        end
    end
    if options.process ~= nil then
        if not plain(options.process) then
            invalid("process options must be a plain record")
        end
        local permitted = {
            timeout = true,
            deadline = true,
            max_output_bytes = true,
            kill_timeout = true,
            drain_timeout = true,
        }
        for key in next, options.process do
            if not permitted[key] then
                invalid("unsupported pane process option")
            end
        end
    end
    local copied, configured, bytes =
        execution.prepare(state.runtime, { argv }, options.process, false)
    if not copied then
        error(configured, 0)
    end
    if bytes > 1048576 then
        invalid("pane operation input exceeds one MiB")
    end
    return { argv = copied[1], options = configured, bytes = bytes, cwd = options.cwd }
end

function M.run(state, owned, kind, data, options, inspect)
    local ref, validation_error = current(state, owned, kind)
    local plan
    if ref then
        local ok, value = pcall(prepare, state, ref, kind, data, options, inspect)
        if ok then
            plan = value
        else
            validation_error = value
        end
    end
    local request = state.runtime:_operation(function(_, operation)
        if not plan or not ref then
            return nil, validation_error
        end
        local now, err = current(state, owned, kind)
        if not now then
            return nil, err
        end
        if not rawequal(ref.generation, now.generation) then
            return nil,
                failure("stale_generation", "server generation changed before pane operation", kind)
        end
        if plan.cwd then
            local valid
            valid, err = domain.directory(state, plan.cwd, "pane.respawn.cwd"):await()
            if not valid then
                return nil, err
            end
        end
        operation:_set_effect("unknown")
        local result
        result, err = state.bound:execute(plan.argv, plan.options):await()
        result, err = process.retain_output(operation, result, err, "pane." .. kind)
        if not result then
            return nil, err
        end
        operation:_set_effect("completed")
        local still_current, cause = current(state, owned, kind)
        if not still_current then
            assert(cause)
            return nil,
                failure(cause.code, cause.message, kind, "completed", {
                    cause = cause,
                    partial = result,
                    target = now,
                })
        end
        if kind == "capture" then
            return setmetatable({ bytes = result.stdout, target = now }, { __index = Capture })
        end
        return true
    end, { operation = "pane." .. kind, effect = "not_sent", target = ref })
    if plan and not request:is_settled() then
        local accepted, cause = request:_retain(plan.bytes)
        if not accepted then
            request:cancel(
                failure(
                    "queue_full",
                    "pane input exceeds runtime byte capacity",
                    kind,
                    nil,
                    { cause = cause }
                )
            )
        end
    end
    return request
end

---@class libtmux.Capture
---@field bytes string Exact capture stdout, including trailing newlines.
---@field target libtmux.Reference
---@field text fun(self:libtmux.Capture):string?,libtmux.Error? Strict UTF-8; no normalization.

---@class libtmux.WaitTextOptions
---@field interval? number Milliseconds between reads, from 1; defaults to 100.
---@field timeout? number Milliseconds from the call; expiry returns `deadline_exceeded`.
---@field deadline? number Absolute time on the runtime driver clock.

---@class libtmux.TextWait
---@field text string The visible screen that matched.
---@field matched_at_entry boolean True when the first read matched.

---@class libtmux.PaneOptions
---@field process? libtmux.CreationProcessOptions

---@class libtmux.CaptureOptions: libtmux.PaneOptions
---@field history_lines? integer Additional history rows; defaults to visible screen only.
---@field start_line? integer|"-" Mutually exclusive with history_lines.
---@field end_line? integer|"-" Mutually exclusive with history_lines.
---@field join_lines? boolean
---@field preserve_spaces? boolean
---@field escape_sequences? boolean
---@field escape_nonprintable? boolean
---@field alternate_screen? boolean
---@field mode_screen? boolean Requires tmux 3.6.
---@field trim_empty_cells? boolean Requires tmux 3.4.
---@field pending_escape_sequences? boolean Capture incomplete input instead of screen cells.
---@field ignore_missing_alternate? boolean Suppress the missing alternate-grid error.
---@field hyperlinks_only? boolean List native URLs instead of cell text; requires tmux 3.7.
---@field line_numbers? boolean Prefix rows with their native offsets; requires tmux 3.7.
---@field line_flags? boolean Prefix rows with native flags; requires tmux 3.7.

---@class libtmux.ClearHistoryOptions: libtmux.PaneOptions
---@field clear_hyperlinks? boolean Also clear hyperlink storage; requires tmux 3.4.

---@class libtmux.KeyOptions: libtmux.PaneOptions
---@field repeat_count? integer From 1 to 1000.

---@class libtmux.CopyModeOptions: libtmux.PaneOptions
---@field page_up? boolean

---@class libtmux.ResizePaneOptions: libtmux.PaneOptions
---@field width? integer
---@field height? integer
---@field direction? "left"|"right"|"up"|"down" Mutually exclusive with dimensions.
---@field amount? integer Defaults to 1 when direction is given.

---@class libtmux.RespawnOptions: libtmux.CreationOptions
---@field kill? boolean Replace an active program; defaults to false.

---@class libtmux.SelectPaneOptions: libtmux.PaneOptions
---@field keep_zoom? boolean Preserve zoom while selecting; defaults to false.

---@class libtmux.SwapPaneOptions: libtmux.SelectPaneOptions
---@field select? boolean Defaults to false (native -d); active selection can still change.

local WAIT_INTERVAL = 100
local WAIT_OPTIONS = { interval = true, timeout = true, deadline = true }
local MAX_DELAY = 2147483647
local GONE = { "no server running", "error connecting to", "server exited unexpectedly" }

local marker_count = 0

-- A fresh marker per read keeps pane output from forging the state line.
-- Without /dev/urandom the bytes mix clock, address and a counter instead of
-- the caller's math.random state, which this must not reseed.
local function wait_marker()
    local bytes
    local urandom = io.open("/dev/urandom", "rb")
    if urandom then
        bytes = urandom:read(8)
        urandom:close()
    end
    if not bytes or #bytes ~= 8 then
        marker_count = marker_count + 1
        local state = os.time() * 1000003 + math.floor(os.clock() * 1e6) + marker_count
        for digit in tostring({}):gmatch("%x") do
            state = (state * 31 + tonumber(digit, 16)) % 2147483629
        end
        local out = {}
        for index = 1, 8 do
            state = (state * 1103515245 + 12345) % 2147483648
            out[index] = string.char(math.floor(state / 65536) % 256)
        end
        bytes = table.concat(out)
    end
    local parts = {}
    for index = 1, 8 do
        parts[index] = string.format("%02x", bytes:byte(index))
    end
    return "libtmux-pane-" .. table.concat(parts) .. "-"
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function wait_arguments(text, options)
    local function invalid(message)
        return nil, failure("invalid_argument", message, "wait_for_text")
    end
    if type(text) ~= "string" or text == "" then
        return invalid("wait_for_text needs a non-empty string")
    end
    if options == nil then
        options = {}
    end
    if not plain(options) then
        return invalid("wait options must be a plain table")
    end
    for key in next, options do
        if not WAIT_OPTIONS[key] then
            return invalid("unknown wait option")
        end
    end
    local interval = options.interval == nil and WAIT_INTERVAL or options.interval
    if not finite(interval) or interval < 1 or interval > MAX_DELAY then
        return invalid("interval must be a number of milliseconds from 1")
    end
    if
        options.timeout ~= nil
        and (not finite(options.timeout) or options.timeout < 0 or options.timeout > MAX_DELAY)
    then
        return invalid("timeout must be from 0 to 2147483647 milliseconds")
    end
    if options.deadline ~= nil and not finite(options.deadline) then
        return invalid("deadline must be a finite driver-clock time in milliseconds")
    end
    return {
        text = text,
        interval = interval,
        timeout = options.timeout,
        deadline = options.deadline,
    }
end

local function server_gone(stderr)
    for _, phrase in ipairs(GONE) do
        if stderr:find(phrase, 1, true) then
            return true
        end
    end
    return false
end

local function pane_missing(stderr)
    for line in stderr:gmatch("[^\n]+") do
        for _, kind in ipairs({ "pane", "window", "session" }) do
            if line:sub(1, #kind + 11) == "can't find " .. kind then
                return true
            end
        end
    end
    return false
end

-- The marker is a deliberate parse error, so it arrives on stderr as
-- "unknown command: <marker><pane id>-<pane_dead>|".
local function read_marker(stderr, marker)
    local start = stderr:find(marker, 1, true)
    if not start then
        return nil
    end
    return stderr:match("^([^|\n]-)%-([^|\n]*)|", start + #marker)
end

--- Poll the visible screen for literal text until it matches, the pane or
--- server ends, or the request is cancelled or reaches its deadline.
function M.wait_for_text(state, owned, text, options)
    local kind = "wait_for_text"
    local rt = state.runtime
    local function rejected(err)
        return rt:_operation(function()
            return nil, err
        end, { operation = "pane." .. kind, effect = "not_sent" })
    end
    local arguments, argument_error = wait_arguments(text, options)
    if not arguments then
        return rejected(argument_error)
    end
    local ref, current_error = current(state, owned, kind)
    if not ref then
        return rejected(current_error)
    end
    local driver = rt._driver
    local deadline = arguments.deadline
    if arguments.timeout ~= nil then
        deadline = driver.now() + arguments.timeout
    end
    if deadline ~= nil and deadline - driver.now() > MAX_DELAY then
        return rejected(
            failure("invalid_argument", "deadline is more than 2147483647 ms away", kind)
        )
    end
    local function ended(reason, message, seen)
        local details = { operation = "pane." .. kind, effect = "not_sent", reason = reason }
        if seen ~= nil then
            details.partial = { text = seen }
        end
        return errors.new("pane_died", message, details)
    end
    return rt:_logical_request({
        deadline = deadline,
        operation = "pane." .. kind,
        effect = "not_sent",
        start = function(settle, retire, request)
            local done, seen, reads = false, nil, 0
            local cancel_pause, inflight
            local read_once, pause
            local function finish(value, err)
                if done then
                    return
                end
                done = true
                if err and rawget(err, "partial") == nil and seen ~= nil then
                    err.partial = { text = seen }
                end
                settle(value, err)
                retire()
            end
            local function expired()
                return deadline ~= nil and driver.now() >= deadline
            end
            local function expire()
                finish(nil, errors.new("deadline_exceeded", "request deadline expired"))
            end
            local function gone()
                finish(
                    nil,
                    ended("server_gone", "tmux server ended before the text appeared", seen)
                )
            end
            -- One read: a verdict ends the wait, anything else pauses.
            local function judge(marker, result, err)
                local output = result
                if err then
                    local cause = rawget(err, "cause")
                    local stderr = type(cause) == "table"
                        and type(rawget(cause, "partial")) == "table"
                        and rawget(cause, "partial").stderr
                    if err.code == "deadline_exceeded" then
                        return expire()
                    elseif err.code == "stale_generation" then
                        -- kill-server poisons the handle; its stderr names the cause.
                        if type(stderr) ~= "string" or server_gone(stderr) then
                            return gone()
                        end
                    elseif
                        err.code == "exit_failed" and type(rawget(err, "partial")) == "table"
                    then
                        output = err.partial
                    end
                    if output == nil then
                        return finish(nil, err)
                    end
                end
                local stdout, stderr = output.stdout, output.stderr
                if type(stdout) ~= "string" or type(stderr) ~= "string" then
                    return finish(
                        nil,
                        err or errors.new("unexpected_output", "tmux read had no output")
                    )
                end
                local complete = stdout:sub(-1) == "\n"
                if complete then
                    seen = stdout
                    request:_set_partial({ text = seen })
                    if seen:find(arguments.text, 1, true) then
                        if expired() then
                            return expire()
                        end
                        return finish({ text = seen, matched_at_entry = reads == 1 })
                    end
                end
                if expired() then
                    return expire()
                end
                local id, dead = read_marker(stderr, marker)
                if id ~= nil then
                    if id ~= ref.id then
                        return finish(nil, ended("pane_gone", "pane no longer exists", seen))
                    elseif dead == "1" then
                        return finish(nil, ended("pane_exited", "pane program exited", seen))
                    elseif dead == "0" and complete then
                        return pause()
                    end
                elseif pane_missing(stderr) then
                    return finish(nil, ended("pane_gone", "pane no longer exists", seen))
                elseif server_gone(stderr) then
                    return gone()
                end
                return finish(
                    nil,
                    errors.new("unexpected_output", "tmux read did not report the pane state", {
                        operation = "pane." .. kind,
                        effect = "not_sent",
                        partial = { text = seen, stderr = stderr },
                    })
                )
            end
            function read_once()
                if done or request:is_settled() then
                    return
                end
                if expired() then
                    return expire()
                end
                local marker = wait_marker()
                local process_options
                if deadline ~= nil then
                    process_options = { timeout = deadline - driver.now() }
                end
                reads = reads + 1
                local call = execution.group(rt, state.bound, {
                    { "capture-pane", "-p", "-J", "-t", ref.id },
                    {
                        "run-shell",
                        "-C",
                        "-t",
                        ref.id,
                        marker .. "#{q:pane_id}-#{q:pane_dead}|",
                    },
                }, process_options)
                inflight = call
                call:on_complete(function(result, err)
                    if done or inflight ~= call then
                        return
                    end
                    inflight = nil
                    local ok, cause = pcall(judge, marker, result, err)
                    if not ok then
                        finish(nil, errors.wrap(cause, "wait_failed"))
                    end
                end)
            end
            -- The pause is one one-shot timer, cancelled with the request.
            function pause()
                local delay = arguments.interval
                if deadline ~= nil then
                    delay = math.min(delay, deadline - driver.now())
                end
                if delay <= 0 then
                    return expire()
                end
                local ok, cancel = pcall(driver.timer, delay, function()
                    cancel_pause = nil
                    read_once()
                end)
                if not ok then
                    return finish(nil, errors.wrap(cancel, "host_error"))
                end
                cancel_pause = cancel
            end
            read_once()
            return function()
                done = true
                if cancel_pause then
                    pcall(cancel_pause)
                    cancel_pause = nil
                end
                if inflight then
                    inflight:cancel(errors.new("cancelled", "wait cancelled"))
                    inflight = nil
                end
                retire()
            end
        end,
    })
end

return M
