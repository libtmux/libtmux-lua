-- Current-client selection using owned terminal attachments and native barriers.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local shell = require("support.shell")
local M = {}

local function attach(prefix, event)
    local argv = { unpack(prefix) }
    for _, word in ipairs({ "attach-session", "-E", "-t", "$0", ";", "wait-for", "-S", event }) do
        argv[#argv + 1] = word
    end
    return argv
end

local function run_case(reconnect, host)
    local directory
    fixture.with(function(f)
        directory = f.path
        local terminals, clients = {}, {}
        local ok, failure = pcall(function()
            f:run("set-option", "-g", "update-environment", "DISPLAY")
            local prefix = { f.binary, "-N", "-f", "/dev/null", "-S", f.socket }
            local env = fixture.environment({ TERM = "xterm-256color", DISPLAY = "client-display" })
            for index = 0, 1 do
                local terminal = child.openpty(24, 80)
                terminals[#terminals + 1] = terminal
                local event = "client-ready-" .. index
                clients[#clients + 1] = child.spawn(attach(prefix, event), {
                    env = env,
                    stdin = terminal.slave,
                    stdout = terminal.slave,
                    stderr = terminal.slave,
                })
                f:run("wait-for", event)
            end
            local selected, survivor = terminals[1].name, terminals[2].name
            if reconnect then
                f:run(
                    "detach-client",
                    "-t",
                    selected,
                    "-E",
                    "exec " .. shell.join(attach(prefix, "client-reconnected"))
                )
                f:run("wait-for", "client-reconnected")
                local pids = {}
                local listing = f:out("list-clients", "-F", "#{client_name}\t#{client_pid}")
                for name, pid in listing:gmatch("([^\t\n]+)\t(%d+)") do
                    pids[name] = tonumber(pid)
                end
                test.assertEquals(pids[selected], clients[1].pid)
            end
            local result = f:program(host, "client", {
                TERM = env.TERM,
                DISPLAY = env.DISPLAY,
                LIBTMUX_CLIENT_NAME = selected,
                LIBTMUX_CLIENT_SURVIVOR = survivor,
            })
            test.assertStrContains(result.stdout, "public client PASS")
            test.assertTrue(clients[1]:wait(fixture.DEADLINE))
            test.assertEquals(clients[1].code, 0)
            test.assertFalse(clients[2].exited)
            test.assertEquals(f:out("list-clients", "-F", "#{client_name}"), survivor .. "\n")
            test.assertEquals(f:pins(), {})
            f:run("detach-client", "-t", survivor)
            test.assertTrue(clients[2]:wait(fixture.DEADLINE))
            test.assertEquals(clients[2].code, 0)
        end)
        for _, client in ipairs(clients) do
            client:close()
        end
        for _, terminal in ipairs(terminals) do
            child.close_terminal(terminal)
        end
        if not ok then
            error(failure, 0)
        end
    end)
    test.assertNil(fs.stat(directory))
end

fixture.each_host(M, "switch_environment_and_detach_leave_other_terminal_alive", function(host)
    run_case(false, host)
end)
fixture.each_host(
    M,
    "same_process_reconnection_remains_addressable_by_explicit_selector",
    function(host)
        run_case(true, host)
    end
)

return M
