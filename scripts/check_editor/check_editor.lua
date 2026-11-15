-- Verify chained LuaLS completions over the real language-server protocol: start the pinned
-- LuaLS, open a document that chains handles, and require the completions each cursor position
-- should offer (and refuse the ones its handle kind must not).
--
--   luajit scripts/check_editor/check_editor.lua
--
-- Prints one JSON line on success and exits 1 on the first missing or forbidden completion. It
-- needs the LuaLS that scripts/bootstrap/bootstrap.lua luals installs. See README.md.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local repo = require("support.repo")
repo.use_rocks()
local json = require("support.json")
local protocol = require("check_editor.protocol")
local script = require("check_editor.script")
local uv = require("support.uv")

local DEADLINE_MS = 8000

local function sorted(set)
    local names = {}
    for name in pairs(set) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

local function file_uri(path)
    return "file://" .. path
end

local function empty_object()
    return json.object({}, {})
end

local started = uv.hrtime()
local executable = repo.root .. "/.cache/tools/luals-3.19.1/bin/lua-language-server"
local stdin, stdout = uv.new_pipe(false), uv.new_pipe(false)
local null = assert(uv.fs_open("/dev/null", "w", 438))
local exit_code
local process = assert(uv.spawn(executable, {
    args = { "--logpath=" .. repo.root .. "/.cache/luals-editor" },
    stdio = { stdin, stdout, null },
}, function(code)
    exit_code = code
end))
local buffer, closed = "", false
stdout:read_start(function(failure, data)
    assert(not failure, failure)
    if data then
        buffer = buffer .. data
    else
        closed = true
    end
end)

local function send(message)
    stdin:write(protocol.frame(message))
end

local function request(identity, method, parameters)
    send({ jsonrpc = "2.0", id = identity, method = method, params = parameters })
    local timer, expired = uv.new_timer(), false
    timer:start(DEADLINE_MS, 0, function()
        expired = true
    end)
    local function finish(...)
        timer:stop()
        timer:close()
        return ...
    end
    while not expired do
        local message
        message, buffer = protocol.take(buffer)
        while message do
            if message.id == identity and message.method == nil then
                if message.error then
                    error(json.encode(message.error), 0)
                end
                return finish(message.result)
            elseif message.id ~= nil and message.method ~= nil then
                send({ jsonrpc = "2.0", id = message.id, result = json.null })
            end
            message, buffer = protocol.take(buffer)
        end
        if closed then
            error("language server exited before replying", 0)
        end
        uv.run("once")
    end
    finish()
    error("language-server response deadline: " .. method, 0)
end

local function stop()
    if exit_code == nil then
        process:kill("sigkill")
    end
end

local ok, failure = pcall(function()
    request(1, "initialize", {
        processId = uv.os_getpid(),
        rootUri = file_uri(repo.root),
        capabilities = empty_object(),
    })
    send({ jsonrpc = "2.0", method = "initialized", params = empty_object() })
    local uri = file_uri(repo.root .. "/examples/editor_query.lua")
    local lines, checks = script.build()
    send({
        jsonrpc = "2.0",
        method = "textDocument/didOpen",
        params = {
            textDocument = {
                uri = uri,
                languageId = "lua",
                version = 1,
                text = table.concat(lines, "\n"),
            },
        },
    })
    -- LuaLS waits for workspace readiness on this request, unlike completion.
    request(2, "textDocument/documentSymbol", { textDocument = { uri = uri } })
    for index, check in ipairs(checks) do
        local result = request(index + 2, "textDocument/completion", {
            textDocument = { uri = uri },
            position = { line = check.line, character = check.character },
        })
        local items = result
        if type(result) == "table" and result.items then
            items = result.items
        elseif result == json.null or result == nil then
            items = {}
        end
        local labels = {}
        for _, item in ipairs(items) do
            labels[item.label:match("^[^(]*")] = true
        end
        local missing, rejected = {}, {}
        for _, name in ipairs(check.required) do
            if not labels[name] then
                missing[#missing + 1] = name
            end
        end
        for _, name in ipairs(check.forbidden) do
            if labels[name] then
                rejected[#rejected + 1] = name
            end
        end
        if #missing > 0 then
            error(
                ("missing chained completions at line %d: [%s]; got [%s]"):format(
                    check.line + 1,
                    table.concat(missing, ", "),
                    table.concat(sorted(labels), ", ")
                ),
                0
            )
        end
        if #rejected > 0 then
            error(
                ("completions this handle kind rejects at line %d: [%s]"):format(
                    check.line + 1,
                    table.concat(rejected, ", ")
                ),
                0
            )
        end
    end
    request(#checks + 3, "shutdown", json.null)
    send({ jsonrpc = "2.0", method = "exit", params = json.null })
    stdin:shutdown()
    while exit_code == nil do
        uv.run("once")
    end
    if exit_code ~= 0 then
        error("language server exited " .. exit_code, 0)
    end
end)
stop()
if not ok then
    io.stderr:write(tostring(failure), "\n")
    os.exit(1)
end
print(('{"editor_completion":"PASS","wall_seconds":%.4f}'):format((uv.hrtime() - started) / 1e9))
os.exit(0)
