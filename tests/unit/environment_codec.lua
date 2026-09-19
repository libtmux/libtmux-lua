local t = require("luaunit")
local available, codec = pcall(require, "libtmux._internal.environment_codec")
local M = {}

local function unhex(value)
    return (
        value:gsub("%x%x", function(pair)
            return string.char(tonumber(pair, 16))
        end)
    )
end

-- Exact owned-daemon show-environment -s output for bytes 1 through 255.
local raw = unhex(
    "4c515f56414c55453d220102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e"
        .. "1f20215c22235c2425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f4041424344"
        .. "45464748494a4b4c4d4e4f505152535455565758595a5b5c5c5d5e5f5c606162636465666768696a"
        .. "6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192"
        .. "939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9ba"
        .. "bbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2"
        .. "e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff223b206578706f7274204c"
        .. "515f56414c55453b0a"
)
local vis = unhex(
    "4c515f56414c55453d225c3030315c3030325c3030335c3030345c3030355c3030365c615c62090a"
        .. "5c765c665c725c3031365c3031375c3032305c3032315c3032325c3032335c3032345c3032355c30"
        .. "32365c3032375c3033305c3033315c3033325c3033335c3033345c3033355c3033365c3033372021"
        .. "5c22235c2425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f4041424344454647"
        .. "48494a4b4c4d4e4f505152535455565758595a5b5c5c5d5e5f5c606162636465666768696a6b6c6d"
        .. "6e6f707172737475767778797a7b7c7d7e5c3137375c3230305c3230315c3230325c3230335c3230"
        .. "345c3230355c3230365c3230375c3231305c3231315c3231325c3231335c3231345c3231355c3231"
        .. "365c3231375c3232305c3232315c3232325c3232335c3232345c3232355c3232365c3232375c3233"
        .. "305c3233315c3233325c3233335c3233345c3233355c3233365c3233375c3234305c3234315c3234"
        .. "325c3234335c3234345c3234355c3234365c3234375c3235305c3235315c3235325c3235335c3235"
        .. "345c3235355c3235365c3235375c3236305c3236315c3236325c3236335c3236345c3236355c3236"
        .. "365c3236375c3237305c3237315c3237325c3237335c3237345c3237355c3237365c3237375c3330"
        .. "305c3330315c3330325c3330335c3330345c3330355c3330365c3330375c3331305c3331315c3331"
        .. "325c3331335c3331345c3331355c3331365c3331375c3332305c3332315c3332325c3332335c3332"
        .. "345c3332355c3332365c3332375c3333305c3333315c3333325c3333335c3333345c3333355c3333"
        .. "365c3333375c3334305c3334315c3334325c3334335c3334345c3334355c3334365c3334375c3335"
        .. "305c3335315c3335325c3335335c3335345c3335355c3335365c3335375c3336305c3336315c3336"
        .. "325c3336335c3336345c3336355c3336365c3336375c3337305c3337315c3337325c3337335c3337"
        .. "345c3337355c3337365c333737223b206578706f7274204c515f56414c55453b0a"
)

local function decode(text, version, hidden)
    t.assertTrue(available, "environment printer decoder is missing")
    return codec.decode(text, version or "3.7c", { hidden = hidden or false })
end

local function rejected(text, code, version)
    local rows, err = decode(text, version)
    t.assertNil(rows)
    err = assert(err)
    t.assertEquals(err.code, code)
    t.assertEquals(err.operation, "environment.decode")
    t.assertIsNumber(err.offset)
end

function M.test_native_printer_vectors_preserve_every_non_nul_byte_and_visibility()
    local bytes = {}
    for byte = 1, 255 do
        bytes[#bytes + 1] = string.char(byte)
    end
    local expected = table.concat(bytes)
    for _, version in ipairs({
        "3.2a",
        "3.3",
        "3.3a",
        "3.4",
        "3.5",
        "3.5a",
        "3.6",
        "3.6a",
        "3.6b",
        "3.7",
        "3.7a",
        "3.7b",
        "3.7c",
    }) do
        local wire = (version == "3.4" or version == "3.5" or version == "3.5a") and vis or raw
        local rows, err = decode(wire .. 'EMPTY=""; export EMPTY;\nunset REMOVED;\n', version, true)
        t.assertNil(err)
        t.assertEquals(rows, {
            { name = "LQ_VALUE", state = "value", hidden = true, value = expected },
            { name = "EMPTY", state = "value", hidden = true, value = "" },
            { name = "REMOVED", state = "removed", hidden = true },
        })
    end
    t.assertEquals(decode(""), {})
end

function M.test_literal_backslashes_and_printer_escapes_use_one_combined_grammar()
    local expected = '\r\001\255\\r\\001\\$NAME;$NAME;${NAME};`cmd`"\n'
    local modern = 'VALUE="\r\001\255\\\\r\\\\001\\\\\\$NAME;'
        .. '\\$NAME;\\${NAME};\\`cmd\\`\\"\n"; export VALUE;\n'
    local printed = 'VALUE="\\r\\001\\377\\\\r\\\\001\\\\\\$NAME;'
        .. '\\$NAME;\\${NAME};\\`cmd\\`\\"\n"; export VALUE;\n'
    t.assertEquals(assert(decode(modern))[1].value, expected)
    for _, version in ipairs({ "3.4", "3.5", "3.5a" }) do
        local wire = version == "3.4" and printed:gsub("(%$[A-Za-z_{])", "\\%1") or printed
        local rows, err = decode(wire, version)
        t.assertNil(err)
        t.assertEquals(assert(rows)[1].value, expected)
    end
    rejected('VALUE="\\r"; export VALUE;\n', "invalid_frame")
end

function M.test_truncation_injection_duplicate_records_and_invalid_escapes_fail_closed()
    for _, data in ipairs({
        'A="value"; export B;\n',
        'A="value"; export A;',
        'A="value"; export A;\ntrailing',
        'A="$(command)"; export A;\n',
        'A="`command`"; export A;\n',
        'A="\\z"; export A;\n',
        'A="unfinished\\',
        'A="\000"; export A;\n',
        'A=""; export A;\nunset A;\n',
        "unset A;\nunset A;\n",
        "unset A;",
    }) do
        rejected(data, "invalid_frame")
    end
    for _, escape in ipairs({ "\\000", "\\400", "\\078", "\\00", "\\z" }) do
        rejected('A="' .. escape .. '"; export A;\n', "invalid_frame", "3.4")
    end
    for _, name in ipairs({ "A B", "A-B", "A\nB", "A\255", "1A", "" }) do
        rejected(name .. '=""; export ' .. name .. ";\n", "unsupported_name")
    end
end

function M.test_removal_rows_remain_unverified_and_do_not_claim_complete_names()
    -- One native removed name "A;\nunset B" produces this same valid stream.
    local rows = assert(decode("unset A;\nunset B;\n"))
    t.assertEquals(rows, {
        { name = "A", state = "removed", hidden = false },
        { name = "B", state = "removed", hidden = false },
    })
    t.assertNil(rows.complete)
    rejected("unset A;\nunset B;\nunset A;\n", "invalid_frame")
    rejected('unset A;\nB="value"; export unset A;\nB;\n', "invalid_frame")
end

function M.test_input_row_name_and_decoded_payload_budgets_are_bounded()
    local name = string.rep("A", 256)
    t.assertEquals(assert(decode(name .. '=""; export ' .. name .. ";\n"))[1].name, name)
    rejected(name .. 'A=""; export ' .. name .. "A;\n", "frame_limit")
    local records = {}
    for index = 1, 4096 do
        records[index] = "unset A" .. index .. ";\n"
    end
    local wire = table.concat(records)
    t.assertEquals(#assert(decode(wire)), 4096)
    rejected(wire .. "unset EXTRA;\n", "frame_limit")
    local prefix, suffix = 'A="', '"; export A;\n'
    local value = string.rep("x", 1048576 - #prefix - #suffix)
    t.assertEquals(assert(decode(prefix .. value .. suffix))[1].value, value)
    rejected(prefix .. value .. "x" .. suffix, "frame_limit")
end

function M.test_version_and_view_validation_do_not_run_caller_metamethods()
    t.assertTrue(available, "environment printer decoder is missing")
    local unknown = { "3.2", "3.5b", "3.7d", "3.8", "4.0", "next-3.7", "3.7c\n", false }
    for _, version in ipairs(unknown) do
        local rows, err = codec.decode("", version, { hidden = false })
        t.assertNil(rows)
        t.assertEquals(assert(err).code, "unsupported_version")
    end
    for _, options in ipairs({
        {},
        false,
        { hidden = "false" },
        { hidden = false, other = true },
        setmetatable({}, {
            __index = function()
                error("metamethod ran")
            end,
        }),
    }) do
        local rows, err = codec.decode("", "3.7c", options)
        t.assertNil(rows)
        t.assertEquals(assert(err).code, "invalid_options")
    end
    local rows, err = codec.decode("", "3.7c")
    t.assertNil(rows)
    t.assertEquals(assert(err).code, "invalid_options")
    rows, err = codec.decode({}, "3.7c", { hidden = false })
    t.assertNil(rows)
    t.assertEquals(assert(err).code, "invalid_frame")
end

return M
