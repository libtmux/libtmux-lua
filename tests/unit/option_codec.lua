local t = require("luaunit")
local available, codec = pcall(require, "libtmux._internal.option_codec")
local M = {}
local versions = {
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
}

local function decode(text, version)
    t.assertTrue(available, "option printer decoder is missing")
    return codec.decode_string(text, version or "3.7c")
end

local function rejected(text, code, version)
    local value, err = decode(text, version)
    t.assertNil(value)
    assert(err)
    t.assertEquals(err.code, code)
    t.assertEquals(err.operation, "option.decode")
end

function M.test_strings_decode_quotes_controls_octal_and_literal_backslashes()
    local vectors = {
        { "''", "" },
        { "plain", "plain" },
        { "'a\"b'", 'a"b' },
        { '"a b\\"c\'d"', "a b\"c'd" },
        { "\\~home", "~home" },
        { '"\\~ home"', "~ home" },
        { "'~\"'", '~"' },
        { "\\a\\b\\f\\n\\r\\t\\v", "\a\b\f\n\r\t\v" },
        { "\\001\\177\\200\\377", "\001\127\128\255" },
        { "\\\\n\\\\001", "\\n\\001" },
        { '"%begin 1 2 3\\n%end 1 2 3"', "%begin 1 2 3\n%end 1 2 3" },
        { "caf\195\169", "caf\195\169" },
    }
    for _, version in ipairs(versions) do
        for _, vector in ipairs(vectors) do
            local value, err = decode(vector[1], version)
            t.assertNil(err)
            t.assertEquals(value, vector[2])
        end
        for special in ("#';${}%~\""):gmatch(".") do
            t.assertEquals(decode("\\" .. special, version), special)
        end
    end
end

function M.test_34_removes_exactly_one_outer_dollar_escape_and_preserves_program_spelling()
    for count = 0, 5 do
        local literal = string.rep("\\", count) .. "$HOME $9 $ ${x} $_x"
        local canonical = '"' .. string.rep("\\", count * 2) .. '\\$HOME $9 $ \\${x} \\$_x"'
        local printed = canonical:gsub("(%$[A-Za-z_{])", "\\%1")
        t.assertEquals(decode(printed, "3.4"), literal)
        for _, version in ipairs({ "3.2a", "3.5a", "3.7c" }) do
            t.assertEquals(decode(canonical, version), literal)
        end
        local source = "set-option -g @x " .. canonical .. " ; display-message -p \\n"
        t.assertEquals(codec.command_source(source:gsub("(%$[A-Za-z_{])", "\\%1"), "3.4"), source)
        t.assertEquals(codec.command_source(source, "3.7c"), source)
    end
    t.assertEquals(codec.command_source("", "3.4"), "")
    t.assertEquals(
        codec.command_source("not-a-command { native grammar }", "3.7c"),
        "not-a-command { native grammar }"
    )
end

function M.test_malformed_tokens_are_rejected_without_guessing_or_trailing_text()
    for _, text in ipairs({
        "",
        "'",
        '"',
        "'closed' extra",
        '"closed"extra',
        "two words",
        "x'quote",
        'x"quote',
        "\\",
        "\\q",
        "\\0",
        "\\01",
        "\\000",
        "\\400",
        "\\777",
        "actual\nnewline",
        "actual\rreturn",
        "actual\ttab",
        "nul\000",
        "control\001",
    }) do
        rejected(text, "invalid_frame")
    end
    rejected(false, "invalid_frame")
    for _, version in ipairs({ "3.2", "3.8", "next-3.7c", "tmux 3.7c", false }) do
        local value, err = decode("value", version)
        if version == false then
            value, err = codec.decode_string("value", false)
        end
        t.assertNil(value)
        t.assertEquals(assert(err).code, "unsupported_version")
    end
    for _, text in ipairs({ "nul\000", "line\n", "carriage\r", "tab\t" }) do
        local source, err = codec.command_source(text, "3.7c")
        t.assertNil(source)
        t.assertEquals(assert(err).code, "invalid_frame")
    end
end

-- Captured normal show-options output for bytes 1 through 255 is identical
-- across all thirteen releases; this is printer data, not executable source.
function M.test_native_printer_vector_preserves_every_non_nul_byte()
    local wire = '"\\001\\002\\003\\004\\005\\006\\a\\b\\t\\n\\v\\f\\r\\016\\017\\020\\021\\022\\'
        .. "023\\024\\025\\026\\027\\030\\031\\032\\033\\034\\035\\036\\037 !\\\"#$%&'"
        .. "()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\\\]^_`ab"
        .. "cdefghijklmnopqrstuvwxyz{|}~\\177\\200\\201\\202\\203\\204\\205\\206"
        .. "\\207\\210\\211\\212\\213\\214\\215\\216\\217\\220\\221\\222\\223\\224\\225"
        .. "\\226\\227\\230\\231\\232\\233\\234\\235\\236\\237\\240\\241\\242\\243\\244"
        .. "\\245\\246\\247\\250\\251\\252\\253\\254\\255\\256\\257\\260\\261\\262\\263"
        .. "\\264\\265\\266\\267\\270\\271\\272\\273\\274\\275\\276\\277\\300\\301\\302"
        .. "\\303\\304\\305\\306\\307\\310\\311\\312\\313\\314\\315\\316\\317\\320\\321"
        .. "\\322\\323\\324\\325\\326\\327\\330\\331\\332\\333\\334\\335\\336\\337\\340"
        .. "\\341\\342\\343\\344\\345\\346\\347\\350\\351\\352\\353\\354\\355\\356\\357"
        .. "\\360\\361\\362\\363\\364\\365\\366\\367\\370\\371\\372\\373\\374\\375\\376"
        .. '\\377"'
    local bytes = {}
    for byte = 1, 255 do
        bytes[#bytes + 1] = string.char(byte)
    end
    for _, version in ipairs(versions) do
        t.assertEquals(decode(wire, version), table.concat(bytes))
    end
end

function M.test_wire_size_is_bounded_before_decoding_or_normalizing()
    local limit = string.rep("a", 1048576)
    t.assertEquals(decode(limit), limit)
    rejected(limit .. "a", "frame_limit")
    t.assertEquals(codec.command_source(limit, "3.4"), limit)
    local source, err = codec.command_source(limit .. "a", "3.4")
    t.assertNil(source)
    t.assertEquals(assert(err).code, "frame_limit")
end

return M
