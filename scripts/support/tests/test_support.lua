local test = require("luaunit")
local files = require("support.files")
local json = require("support.json")
local repo = require("support.repo")
local M = {}

-- Written by Python's json.dumps(value, indent=2) and json.dumps(value, separators=(",", ":")).
local PRETTY = [[
{
  "name": "\u00e9\ud83d\ude00",
  "list": [
    1,
    2.5,
    -3,
    true,
    false,
    null,
    0.1
  ],
  "empty_list": [],
  "empty_obj": {},
  "nested": {
    "b": {
      "x": "a\"b\\c\n\t\u0001\u007f/"
    },
    "a": [
      {},
      []
    ]
  }
}]]
local COMPACT = '{"name":"\\u00e9\\ud83d\\ude00","list":[1,2.5,-3,true,false,null,0.1],'
    .. '"empty_list":[],"empty_obj":{},"nested":{"b":{"x":"a\\"b\\\\c\\n\\t\\u0001\\u007f/"},'
    .. '"a":[{},[]]}}'

local function temporary()
    local path = os.tmpname()
    os.remove(path)
    return path
end

function M.test_encode_matches_python_for_a_decoded_document()
    local value = json.decode(PRETTY)
    test.assertEquals(json.encode(value, 2), PRETTY)
    test.assertEquals(json.encode(value), COMPACT)
end

function M.test_decode_keeps_key_order_and_null()
    local value = json.decode('{"b":1,"a":{"z":null,"y":[]},"c":[1,{"x":2}],"b":3}')
    test.assertEquals(json.keys(value), { "b", "a", "c" })
    test.assertEquals(value.b, 3)
    test.assertEquals(json.keys(value.a), { "z", "y" })
    test.assertEquals(value.a.z, json.null)
    test.assertEquals(value.c[2].x, 2)
end

function M.test_decode_refuses_trailing_data_and_bad_syntax()
    test.assertEquals(json.decode(' {"a": 1}\n').a, 1)
    test.assertError(json.decode, '{"a": 1} x')
    test.assertError(json.decode, '{"a": ')
end

function M.test_plain_tables_encode_as_arrays_or_sorted_objects()
    test.assertEquals(json.encode({ 1, "two" }), '[1,"two"]')
    test.assertEquals(json.encode({ b = 1, a = 2 }), '{"a":2,"b":1}')
    test.assertEquals(json.encode({}), "[]")
    test.assertEquals(json.encode(json.object({}, {})), "{}")
    test.assertEquals(json.encode(json.object({ "z", "a" }, { a = 1, z = 2 })), '{"z":2,"a":1}')
end

function M.test_files_write_append_and_read()
    local path = temporary()
    files.append(path, "one\n")
    files.append(path, "two\n")
    test.assertEquals(files.read(path), "one\ntwo\n")
    files.write(path, "three")
    test.assertEquals(files.read(path), "three")
    os.remove(path)
    local ok, failure = pcall(files.read, path)
    test.assertFalse(ok)
    test.assertStrContains(failure, "No such file or directory")
end

function M.test_json_files_round_trip_with_a_trailing_newline()
    local path = temporary()
    json.write(path, json.decode(PRETTY), 2)
    test.assertEquals(files.read(path), PRETTY .. "\n")
    test.assertEquals(json.read(path).nested.b.x, 'a"b\\c\n\t\1\127/')
    os.remove(path)
end

function M.test_the_root_holds_the_scripts_and_the_rock_tree_is_on_the_path()
    test.assertNotNil(io.open(repo.root .. "/scripts/support/repo.lua"))
    test.assertNotNil(package.path:find(repo.root .. "/.cache/rocks/luajit-", 1, true))
end

return M
