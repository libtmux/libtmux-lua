local errors = require("libtmux._internal.error")
local fields = require("libtmux._internal.fields")
local registry = require("libtmux._internal.support.capabilities")
local M = {}

-- Every command name and alias in tmux 3.3a through master. A caller's word
-- reaches a command by an exact alias, an exact name or a unique name prefix.
local aliases = {
    ["attach-session"] = "attach",
    ["bind-key"] = "bind",
    ["break-pane"] = "breakp",
    ["capture-pane"] = "capturep",
    ["clear-history"] = "clearhist",
    ["clear-prompt-history"] = "clearphist",
    ["confirm-before"] = "confirm",
    ["delete-buffer"] = "deleteb",
    ["detach-client"] = "detach",
    ["display-menu"] = "menu",
    ["display-message"] = "display",
    ["display-panes"] = "displayp",
    ["display-popup"] = "popup",
    ["find-window"] = "findw",
    ["has-session"] = "has",
    ["if-shell"] = "if",
    ["join-pane"] = "joinp",
    ["kill-pane"] = "killp",
    ["kill-window"] = "killw",
    ["last-pane"] = "lastp",
    ["last-window"] = "last",
    ["link-window"] = "linkw",
    ["list-buffers"] = "lsb",
    ["list-clients"] = "lsc",
    ["list-commands"] = "lscm",
    ["list-keys"] = "lsk",
    ["list-panes"] = "lsp",
    ["list-sessions"] = "ls",
    ["list-windows"] = "lsw",
    ["load-buffer"] = "loadb",
    ["lock-client"] = "lockc",
    ["lock-server"] = "lock",
    ["lock-session"] = "locks",
    ["move-pane"] = "movep",
    ["move-window"] = "movew",
    ["new-pane"] = "newp",
    ["new-session"] = "new",
    ["new-window"] = "neww",
    ["next-layout"] = "nextl",
    ["next-window"] = "next",
    ["paste-buffer"] = "pasteb",
    ["pipe-pane"] = "pipep",
    ["previous-layout"] = "prevl",
    ["previous-window"] = "prev",
    ["refresh-client"] = "refresh",
    ["rename-session"] = "rename",
    ["rename-window"] = "renamew",
    ["resize-pane"] = "resizep",
    ["resize-window"] = "resizew",
    ["respawn-pane"] = "respawnp",
    ["respawn-window"] = "respawnw",
    ["rotate-window"] = "rotatew",
    ["run-shell"] = "run",
    ["save-buffer"] = "saveb",
    ["select-layout"] = "selectl",
    ["select-pane"] = "selectp",
    ["select-window"] = "selectw",
    ["send-keys"] = "send",
    ["set-buffer"] = "setb",
    ["set-environment"] = "setenv",
    ["set-option"] = "set",
    ["set-window-option"] = "setw",
    ["show-buffer"] = "showb",
    ["show-environment"] = "showenv",
    ["show-messages"] = "showmsgs",
    ["show-options"] = "show",
    ["show-prompt-history"] = "showphist",
    ["show-window-options"] = "showw",
    ["source-file"] = "source",
    ["split-window"] = "splitw",
    ["start-server"] = "start",
    ["suspend-client"] = "suspendc",
    ["swap-pane"] = "swapp",
    ["swap-window"] = "swapw",
    ["switch-client"] = "switchc",
    ["unbind-key"] = "unbind",
    ["unlink-window"] = "unlinkw",
    ["wait-for"] = "wait",
}
local plain_names = {
    "choose-buffer",
    "choose-client",
    "choose-tree",
    "clock-mode",
    "command-prompt",
    "copy-mode",
    "customize-mode",
    "kill-server",
    "kill-session",
    "send-prefix",
    "server-access",
    "set-hook",
    "show-hooks",
    "switch-mode",
}
local names = {}
for name in pairs(aliases) do
    names[#names + 1] = name
end
for _, name in ipairs(plain_names) do
    names[#names + 1] = name
end

-- tmux's cmd_find: an exact alias wins, then an exact name, then a unique prefix.
local function resolve(word)
    if type(word) ~= "string" or word == "" then
        return nil
    end
    for name, alias in pairs(aliases) do
        if alias == word then
            return name
        end
    end
    local found
    for _, name in ipairs(names) do
        if name == word then
            return name
        elseif name:sub(1, #word) == word then
            if found then
                return nil
            end
            found = name
        end
    end
    return found
end

-- Letters that take a value, from each command's tmux argument template.
local value_flags = {
    ["break-pane"] = "Fnst",
    ["split-window"] = "ceFlmpRsSt",
    ["select-layout"] = "t",
    ["delete-buffer"] = "b",
    ["set-buffer"] = "bnt",
    ["new-session"] = "ceFfnstxy",
    ["new-window"] = "ceFnt",
    ["rename-session"] = "t",
    ["rename-window"] = "t",
    ["refresh-client"] = "ABCFft",
}
local presets = { "even-horizontal", "even-vertical", "main-horizontal", "main-vertical", "tiled" }

-- tmux stops at the first positional word; a cluster such as -dPn name or
-- -nname carries a value after its first value-taking letter.
local function parse(argv, takes)
    local flags, index = {}, 2
    while index <= #argv do
        local word = argv[index]
        if word == "--" then
            index = index + 1
            break
        elseif word:sub(1, 1) ~= "-" or #word == 1 then
            break
        end
        local position = 2
        while position <= #word do
            local letter = word:sub(position, position)
            local list = flags[letter] or {}
            flags[letter] = list
            if takes:find(letter, 1, true) then
                local value = word:sub(position + 1)
                if value == "" then
                    index = index + 1
                    value = argv[index] or ""
                end
                list[#list + 1] = value
                break
            end
            list[#list + 1] = true
            position = position + 1
        end
        index = index + 1
    end
    local positional = {}
    for item = index, #argv do
        positional[#positional + 1] = argv[item]
    end
    return flags, positional
end

-- fields.at_least ranks next-X.Y and X.Y-rcN below X.Y; a report that names no
-- release counts as below every requirement.
local function below(version, required)
    return not fields.at_least(version, required)
end

local function refuse(version, required, message)
    return errors.new("unsupported", message, {
        operation = "endpoint",
        effect = "not_sent",
        required = required,
        version = version,
    })
end

---Library-managed control acquisition needs the daemon's 3.7 initialization fixes.
---@param version string
---@return table? error
function M.control(version)
    local required = registry.since("control-mode")
    if below(version, required) then
        return refuse(
            version,
            required,
            "control observation requires tmux "
                .. required
                .. " or newer; the daemon reports "
                .. tostring(version)
        )
    end
end

local function unique_preset(word)
    local matched
    for _, name in ipairs(presets) do
        if name:sub(1, #word) == word then
            if matched then
                return false
            end
            matched = name
        end
    end
    return matched ~= nil
end

local function has_flag(flags, letter)
    return flags[letter] ~= nil
end

local function misnamed(values)
    for _, value in ipairs(values or {}) do
        if type(value) == "string" and value:find("[:.]") then
            return true
        end
    end
    return false
end

---Refuse a literal tmux command item whose native behavior is unsafe on this daemon.
---@param version string The checked daemon release.
---@param argv string[]
---@return table? error
function M.command(version, argv)
    local name = resolve(argv[1])
    local takes = name and value_flags[name]
    if not takes then
        return nil
    end
    local flags, positional = parse(argv, takes)
    local break_pane = registry.workaround("break-pane-misnames-windows")
    local split_percent = registry.workaround("split-window-percent-size")
    local separators = registry.workaround("name-separators-rejected")
    local delete_floor = registry.since("buffer-delete-named")
    local rename_floor = registry.since("buffer-rename")
    local layout_floor = registry.since("layout-without-checksum")
    local clipboard_floor = registry.since("clipboard-query")
    if name == "break-pane" and fields.exactly(version, break_pane.releases[1]) then
        return refuse(
            version,
            break_pane.required,
            "break-pane misnames windows on exactly tmux 3.7; use Pane:break_out or tmux 3.7a"
        )
    elseif
        name == "split-window"
        and fields.exactly(version, split_percent.releases[1])
        and has_flag(flags, "p")
    then
        return refuse(
            version,
            split_percent.required,
            "split-window -p is broken on tmux 3.4; use -l N%"
        )
    elseif name == "select-layout" and below(version, layout_floor) then
        local layout = positional[1]
        if
            layout ~= nil
            and not has_flag(flags, "n")
            and not has_flag(flags, "p")
            and not has_flag(flags, "E")
        then
            local header = layout:match("^%x%x%x%x,.") ~= nil
            if not header and (has_flag(flags, "o") or not unique_preset(layout)) then
                return refuse(
                    version,
                    layout_floor,
                    "tmux 3.3a crashes on an invalid layout; use a checksummed layout or a name"
                )
            end
        end
    elseif name == "delete-buffer" and below(version, delete_floor) and has_flag(flags, "b") then
        return refuse(
            version,
            delete_floor,
            "named buffer deletion requires tmux 3.4; older releases can delete another buffer"
        )
    elseif name == "set-buffer" and below(version, rename_floor) and has_flag(flags, "n") then
        return refuse(
            version,
            rename_floor,
            "buffer rename requires tmux 3.4; older releases can rename another buffer"
        )
    elseif
        name == "refresh-client"
        and below(version, clipboard_floor)
        and has_flag(flags, "l")
    then
        return refuse(
            version,
            clipboard_floor,
            "refresh-client -l requires tmux 3.6a; older tmux can stop on a clipboard query"
        )
    elseif fields.exactly(version, separators.releases[1]) then
        local bad = (name == "new-session" and (misnamed(flags.s) or misnamed(flags.n)))
            or (name == "new-window" and misnamed(flags.n))
            or (
                (name == "rename-session" or name == "rename-window")
                and misnamed({ positional[1] })
            )
        if bad then
            return refuse(
                version,
                separators.required,
                "tmux 3.7 rejects ':' and '.' in session and window names"
            )
        end
    end
end

---@param version string
---@param commands string[][]
---@return table? error
function M.commands(version, commands)
    for _, argv in ipairs(commands) do
        local err = M.command(version, argv)
        if err then
            return err
        end
    end
end

return M
