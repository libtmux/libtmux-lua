local test = require("luaunit")
local available, parser = pcall(require, "libtmux._internal.control_parser")
local M = {}

local function create(options)
    test.assertTrue(available, "control byte parser is not implemented")
    return assert(parser.new(options))
end

local function collect(chunks, options)
    local decoder, events = create(options), {}
    for _, chunk in ipairs(chunks) do
        local batch, err = decoder:feed(chunk)
        test.assertNil(err)
        for _, event in ipairs(batch) do
            events[#events + 1] = event
        end
    end
    local batch, err = decoder:finish()
    test.assertNil(err)
    for _, event in ipairs(batch) do
        events[#events + 1] = event
    end
    return events
end

local corpus = table.concat({
    "%begin 1789828965 285 0\n%end 1789828965 285 0\n",
    "%session-changed $0 fixture\n",
    "%begin 1789828965 290 1\n",
    "%output %0 body, not a notification\n",
    "%begin 1 2 3\n%end 1789828965 290 0\n%error 1789828965 291 1\n",
    "raw\r\255\n%end 1789828965 290 1\n",
    "%output %0 A\\000\\012\\015\\134\\377\255\n",
    "%extended-output %12 18446744073709551615 future=1 x : \\001 : tail\n",
    "%future-event untouched \\001\n",
    "LATE_OUTPUT\n",
    "%begin 1789828965 291 1\nmissing target\n%error 1789828965 291 1\n",
    "%exit detached\n",
})

function M.test_every_fragment_boundary_preserves_blocks_and_notifications()
    local expected = collect({ corpus }, { bootstrap = true })
    test.assertEquals(expected[1].phase, "bootstrap")
    test.assertEquals(expected[1].guard, { time = "1789828965", number = "285", flags = "0" })
    test.assertEquals(expected[3].phase, "command")
    test.assertEquals(
        expected[3].body,
        table.concat({
            "%output %0 body, not a notification\n",
            "%begin 1 2 3\n%end 1789828965 290 0\n%error 1789828965 291 1\n",
            "raw\r\255\n",
        })
    )
    test.assertEquals(expected[4].data, "A\000\n\r\\\255\255")
    test.assertEquals(expected[5].age, "18446744073709551615")
    test.assertEquals(expected[5].metadata, "future=1 x")
    test.assertEquals(expected[5].data, "\001 : tail")
    test.assertEquals(expected[6].kind, "unknown")
    test.assertEquals(expected[7], { kind = "raw", raw = "LATE_OUTPUT" })
    test.assertEquals(expected[8].ending, "error")
    test.assertEquals(expected[9].name, "exit")
    test.assertEquals(expected[10].kind, "eof")
    for split = 0, #corpus do
        test.assertEquals(
            collect({ corpus:sub(1, split), corpus:sub(split + 1) }, {
                bootstrap = true,
            }),
            expected,
            "split at byte " .. split
        )
    end
    local bytes = {}
    for index = 1, #corpus do
        bytes[index] = corpus:sub(index, index)
    end
    test.assertEquals(collect(bytes, { bootstrap = true }), expected)
end

function M.test_bootstrap_requires_explicit_context_not_zero_flags()
    local events = collect({ "%begin 1 2 0\n%end 1 2 0\n" })
    test.assertEquals(events[1].phase, "command")
end

function M.test_exact_matching_body_guard_is_indistinguishable_on_the_wire()
    local decoder = create()
    local events, err = decoder:feed("%begin 1 2 1\n%end 1 2 1\nstill body\n%end 1 2 1\n")
    test.assertEquals(events[1].body, "")
    test.assertEquals(events[2], { kind = "raw", raw = "still body" })
    test.assertEquals(assert(err).code, "invalid_frame")
    test.assertEquals(events[3].kind, "error")
end

function M.test_malformed_output_and_outer_guards_fail_terminally()
    for _, wire in ipairs({
        "%begin invalid\n",
        "%end 1 2 3\n",
        "%error 1 2 3\n",
        "%output %x bad\n",
        "%output %0 \\8\n",
        "%output %0 \\400\n",
        "%output %0 \\00\n",
        "%output %0 \\000\\\n",
        "%extended-output %0 nope : bad\n",
        "%extended-output %0 1 missing\n",
    }) do
        local decoder = create()
        local events, err = decoder:feed(wire)
        test.assertEquals(assert(err).code, "invalid_frame", wire)
        test.assertEquals(events[#events].kind, "error")
        test.assertEquals(decoder:stats().retained_bytes, 0)
        local later, same = decoder:feed("%sessions-changed\n")
        test.assertEquals(later, {})
        test.assertIs(same, err)
    end
end

function M.test_truncated_eof_and_transport_failure_are_not_clean_eof()
    for _, wire in ipairs({ "%beg", "%begin 1 2 1\n", "%begin 1 2 1\nbody" }) do
        local decoder = create()
        assert(decoder:feed(wire))
        local events, err = decoder:finish()
        test.assertEquals(assert(err).code, "truncated_frame")
        test.assertEquals(events[1].kind, "error")
        test.assertEquals(decoder:stats().retained_bytes, 0)
        test.assertEquals(decoder:finish(), {})
    end
    local decoder = create()
    local cause = { code = "read_failed" }
    local events, err = decoder:finish(cause)
    test.assertEquals(assert(err).code, "read_failed")
    test.assertIs(assert(err).cause, cause)
    test.assertEquals(events[1].kind, "error")
    decoder = create()
    test.assertEquals(decoder:finish(), { { kind = "eof" } })
    local _, closed = decoder:feed("late")
    test.assertEquals(assert(closed).code, "closed")
end

function M.test_limits_bound_input_lines_blocks_events_and_decoded_retention()
    local cases = {
        { { max_input_bytes = 3 }, { "four" }, "input" },
        { { max_line_bytes = 3 }, { "ab", "cd" }, "line" },
        { { max_block_bytes = 3 }, { "%begin 1 2 1\na\nb\n" }, "block" },
        { { max_block_lines = 1 }, { "%begin 1 2 1\na\nb\n" }, "block_lines" },
        { { max_events = 1 }, { "%sessions-changed\n%sessions-changed\n" }, "events" },
        { { max_event_bytes = 30 }, { "%output %0 \\000\\000\\000\n" }, "event_bytes" },
    }
    for _, case in ipairs(cases) do
        local decoder = create(case[1])
        local events, err
        for _, chunk in ipairs(case[2]) do
            events, err = decoder:feed(chunk)
        end
        test.assertEquals(assert(err).code, "frame_limit")
        test.assertEquals(assert(err).limit, case[3])
        test.assertEquals(events[#events].kind, "error")
        test.assertEquals(decoder:stats().retained_bytes, 0)
    end
end

function M.test_decimal_guards_do_not_round_through_lua_numbers()
    local tuple = "18446744073709551615 9007199254740993 12345"
    local events = collect({ "%begin " .. tuple .. "\n%end " .. tuple .. "\n" })
    test.assertEquals(events[1].guard.number, "9007199254740993")
    local decoder = create()
    decoder:feed("%begin 1 9007199254740993 1\n%end 1 9007199254740992 1\n")
    local _, err = decoder:finish()
    test.assertEquals(assert(err).code, "truncated_frame")
end

return M
