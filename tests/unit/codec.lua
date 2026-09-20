local test = require("luaunit")
local available, codec = pcall(require, "libtmux._internal.codec")
local M = {}
local marker = "LQ1\r$a;"

function M.test_metadata_codec_preserves_bytes_rows_and_delimiters()
    test.assertTrue(available, "metadata codec is not implemented")
    test.assertEquals(
        codec.format({ "session_id", "session_name" }),
        marker .. "#{q:session_id};#{q:session_name};."
    )
    local value = "semi;slash\\\n%begin 1 2 3\r\n\t\255tail"
    local encoded = value:gsub("([;\\])", "\\%1")
    local rows, err = codec.decode(marker .. "$0;" .. encoded .. ";.\n" .. marker .. "$1;;.\n", 2)
    test.assertNil(err)
    test.assertEquals(rows, { { "$0", value }, { "$1", "" } })
    test.assertEquals(codec.decode("", 2), {})
    test.assertEquals(codec.decode(marker .. "\n;.\n", 1), { { "\n" } })
end

function M.test_printer_dialects_preserve_literal_escapes_and_control_bytes()
    local expected = "\r\001\255\\r\\001\\$NAME;$NAME;${NAME};$0;\a\b\f\v"
    local fields = {
        marker .. "\r\001\255\\\\r\\\\001\\\\\\$NAME\\;\\$NAME\\;\\${NAME}\\;\\$0\\;\a\b\f\v;.\n",
        "LQ1\\r$a;\\r\\001\\377\\\\r\\\\001\\\\\\$NAME\\;"
            .. "\\$NAME\\;\\${NAME}\\;\\$0\\;\\a\\b\\f\\v;.\n",
        "LQ1\\r\\$a;\\r\\001\\377\\\\r\\\\001\\\\\\\\$NAME\\;"
            .. "\\\\$NAME\\;\\\\${NAME}\\;\\$0\\;\\a\\b\\f\\v;.\n",
    }
    for _, data in ipairs(fields) do
        local rows, err = codec.decode(data, 1)
        test.assertNil(err)
        test.assertEquals(rows, { { expected } })
        test.assertEquals(codec.decode(data .. data, 1), { { expected }, { expected } })
        test.assertEquals(codec.decode(data, 1, { max_bytes = #data }), { { expected } })
        local limited, failure = codec.decode(data, 1, { max_bytes = #data - 1 })
        test.assertNil(limited)
        test.assertEquals(assert(failure).code, "frame_limit")
        limited, failure = codec.decode(data .. data, 1, { max_rows = 1 })
        test.assertNil(limited)
        test.assertEquals(assert(failure).code, "frame_limit")
    end
end

function M.test_metadata_codec_rejects_truncation_and_invalid_framing()
    test.assertTrue(available, "metadata codec is not implemented")
    for _, value in ipairs({ "one;two;.\n", "one;.", "one;!\n", "one\\", "one\000;.\n" }) do
        local rows, err = codec.decode(marker .. value, 1)
        test.assertNil(rows)
        test.assertIsTable(err)
        test.assertEquals(assert(err).code, "invalid_frame")
        test.assertIsNumber(assert(err).offset)
    end
    local rows, err = codec.decode(marker .. "four;.\n", 1, { max_bytes = 3 })
    test.assertNil(rows)
    test.assertEquals(assert(err).code, "frame_limit")
    rows, err = codec.decode(marker .. "a;.\n" .. marker .. "b;.\n", 1, { max_rows = 1 })
    test.assertNil(rows)
    test.assertEquals(assert(err).code, "frame_limit")
end

function M.test_invalid_mixed_markers_and_unknown_escapes_fail_closed()
    for _, data in ipairs({
        "value;.\n",
        "LQ2\r$a;value;.\n",
        marker,
        marker .. "value;.\nLQ1\\r$a;next;.\n",
        marker .. "\\r;.\n",
        marker .. "\\z;.\n",
        "LQ1\\r$a;\\z;.\n",
        "LQ1\\r$a;\\00;.\n",
        "LQ1\\r$a;\\000;.\n",
        "LQ1\\r$a;\\400;.\n",
        "LQ1\\r$a;\\078;.\n",
    }) do
        local rows, err = codec.decode(data, 1)
        test.assertNil(rows)
        test.assertEquals(assert(err).code, "invalid_frame")
    end
end

function M.test_metadata_format_rejects_expression_injection()
    test.assertTrue(available, "metadata codec is not implemented")
    for _, fields in ipairs({
        {},
        { "#{pane_id}" },
        { "pane_id};#{version}" },
        { "line\n" },
        { "pane_id", false },
    }) do
        local value, err = codec.format(fields)
        test.assertNil(value)
        test.assertEquals(assert(err).code, "invalid_format")
    end
end

return M
