local test = require("luaunit")
local protocol = require("check_editor.protocol")
local script = require("check_editor.script")
local M = {}

function M.test_a_framed_message_round_trips_and_leaves_the_rest()
    local first = protocol.frame({ jsonrpc = "2.0", id = 1, result = "é" })
    local second = protocol.frame({ jsonrpc = "2.0", id = 2, method = "ping" })
    local message, rest = protocol.take(first .. second)
    assert(message)
    test.assertEquals(message.id, 1)
    test.assertEquals(message.result, "é")
    test.assertEquals(rest, second)
    message, rest = protocol.take(rest)
    assert(message)
    test.assertEquals(message.method, "ping")
    test.assertEquals(rest, "")
end

function M.test_a_partial_message_waits_for_the_rest()
    local framed = protocol.frame({ jsonrpc = "2.0", id = 7, result = "ok" })
    for cut = 1, #framed - 1, 7 do
        local message, rest = protocol.take(framed:sub(1, cut))
        test.assertNil(message)
        test.assertEquals(rest, framed:sub(1, cut))
    end
    test.assertEquals(assert(protocol.take(framed)).id, 7)
end

function M.test_an_oversized_or_unframed_message_is_refused()
    test.assertErrorMsgContains(
        "oversized language-server response",
        protocol.take,
        "Content-Length: " .. protocol.MAX_BYTES + 1 .. "\r\n\r\n{}"
    )
    test.assertErrorMsgContains("without a Content-Length", protocol.take, "X-Other: 1\r\n\r\n{}")
end

function M.test_every_check_sits_after_the_line_it_completes()
    local lines, checks = script.build()
    test.assertTrue(#checks > 50)
    for _, check in ipairs(checks) do
        local line = lines[check.line + 1]
        test.assertNotNil(line)
        test.assertEquals(check.character, #line)
        test.assertNotNil(line:match("[:%.]$"), line)
        test.assertTrue(#check.required > 0)
        local wanted = {}
        for _, name in ipairs(check.required) do
            wanted[name] = true
        end
        for _, name in ipairs(check.forbidden) do
            test.assertNil(wanted[name], name .. " is both required and forbidden")
        end
    end
end

function M.test_both_runtime_adapters_are_exercised_through_the_same_chain()
    local lines = script.build()
    local text = table.concat(lines, "\n")
    test.assertStrContains(text, 'require("libtmux.runtime.luv")')
    test.assertStrContains(text, 'require("libtmux.runtime.nvim")')
    test.assertStrContains(text, "libtmux.Fields.WindowLink")
end

return M
