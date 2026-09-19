local errors = require("libtmux._internal.error")
local execution = require("libtmux._internal.execution")
local identity = require("libtmux._internal.identity")
local process = require("libtmux._internal.process")
local domain = require("libtmux._internal.domain")
local M, Capture = {}, {}
local commands = {
    capture = "capture-pane",
    send_text = "send-keys",
    send_keys = "send-keys",
    copy_mode = "copy-mode",
    copy_command = "send-keys",
    resize = "resize-pane",
    kill = "kill-pane",
    respawn = "respawn-pane",
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
    },
    send_text = {},
    send_keys = { repeat_count = true },
    copy_mode = { page_up = true },
    copy_command = { repeat_count = true },
    resize = { width = true, height = true, direction = true, amount = true },
    kill = {},
    respawn = { kill = true, argv = true, shell = true, cwd = true, environment = true },
}

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

local function utf8(value)
    if type(value) ~= "string" then
        return false
    end
    local index = 1
    while index <= #value do
        local byte = value:byte(index)
        local size = byte <= 127 and 1
            or byte >= 194 and byte <= 223 and 2
            or byte >= 224 and byte <= 239 and 3
            or byte >= 240 and byte <= 244 and 4
        if not size or index + size - 1 > #value then
            return false
        end
        for offset = 1, size - 1 do
            local next_byte = value:byte(index + offset)
            if next_byte < 128 or next_byte > 191 then
                return false
            end
        end
        local second = value:byte(index + 1)
        if
            size > 1
            and (
                byte == 224 and second < 160
                or byte == 237 and second > 159
                or byte == 240 and second < 144
                or byte == 244 and second > 143
            )
        then
            return false
        end
        index = index + size
    end
    return true
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

local function prepare(state, ref, kind, data, options)
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
    local function boolean(name, argument)
        local value = options[name]
        if value ~= nil and type(value) ~= "boolean" then
            invalid(name .. " must be boolean")
        end
        if value then
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
    if kind == "capture" then
        flag("-p")
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
        local major, minor = state.version:match("^(%d+)%.(%d+)")
        for _, item in ipairs({
            { "join_lines", "-J" },
            { "preserve_spaces", "-N" },
            { "escape_sequences", "-e" },
            { "escape_nonprintable", "-C" },
            { "alternate_screen", "-a" },
            { "mode_screen", "-M", 6 },
            { "trim_empty_cells", "-T", 4 },
        }) do
            if options[item[1]] ~= nil and type(options[item[1]]) ~= "boolean" then
                invalid(item[1] .. " must be boolean")
            end
            if
                options[item[1]]
                and item[3]
                and tonumber(major) == 3
                and tonumber(minor) < item[3]
            then
                invalid(item[1] .. " is unavailable on this tmux version", "unsupported")
            end
            boolean(item[1], item[2])
        end
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

function M.run(state, owned, kind, data, options)
    local ref, validation_error = current(state, owned, kind)
    local plan
    if ref then
        local ok, value = pcall(prepare, state, ref, kind, data, options)
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
---@field bytes string Exact rendered stdout, including trailing newlines.
---@field target libtmux.Reference
---@field text fun(self:libtmux.Capture):string?,libtmux.Error? Strict UTF-8; no normalization.

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

return M
