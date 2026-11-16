local test = require("luaunit")
local files = require("support.files")
local json = require("support.json")
local fs = require("support.fs")
local proc = require("support.proc")
local repo = require("support.repo")
local runtime = require("support.runtime")
local uv = require("support.uv")
local M = {}

-- The same document in the indented and the compact layout.
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

function M.test_encode_writes_a_decoded_document_in_both_layouts()
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

function M.test_executable_path_takes_the_first_executable_file_on_path()
    local directory = fs.mkdtemp("libtmux-lua-path-")
    assert(uv.fs_mkdir(directory .. "/first", 448))
    assert(uv.fs_mkdir(directory .. "/first/tool", 448))
    assert(uv.fs_mkdir(directory .. "/second", 448))
    files.write(directory .. "/second/tool", "")
    assert(uv.fs_chmod(directory .. "/second/tool", 493))
    local original = os.getenv("PATH")
    assert(uv.os_setenv("PATH", directory .. "/first:" .. directory .. "/second:" .. original))
    local ok, found = pcall(runtime.executable_path, "tool")
    local missing_ok, missing = pcall(runtime.executable_path, "libtmux-no-such-tool")
    assert(uv.os_setenv("PATH", original))
    fs.remove_tree(directory)
    test.assertTrue(ok, found)
    test.assertEquals(found, directory .. "/second/tool")
    test.assertFalse(missing_ok)
    test.assertEquals(missing, "Missing executable: libtmux-no-such-tool")
end

-- A write to a pipe whose reader has gone raises SIGPIPE, which ends a process that does not
-- ignore it. A child that exits at once, such as the stand-in the sandbox stops, is the usual one.
function M.test_a_child_that_never_reads_its_input_does_not_kill_the_writer()
    local input = ("x"):rep(1048576)
    for _ = 1, 100 do
        test.assertEquals(proc.run({ "true" }, { stdin = input }).code, 0)
    end
end

-- A descendant that holds the output pipe open used to keep the call waiting for the descendant,
-- not for the timeout: `sleep 8 & sleep 8` returned after eight seconds.
function M.test_a_timeout_bounds_the_call_when_a_descendant_holds_the_output_open()
    local started = uv.hrtime()
    local result = proc.run({ "/bin/sh", "-c", "sleep 3 & sleep 3" }, { timeout = 0.3 })
    local elapsed = (uv.hrtime() - started) / 1e9
    test.assertTrue(result.timed_out)
    test.assertTrue(elapsed < 1.5, ("the call took %.2f seconds"):format(elapsed))
end

-- The timeout ends the whole process group, so the descendant does not outlive the call.
function M.test_a_timeout_kills_the_descendants_of_the_child()
    local started = uv.hrtime()
    local result = proc.run({ "/bin/sh", "-c", "sleep 30 & echo $!; wait" }, { timeout = 0.3 })
    local elapsed = (uv.hrtime() - started) / 1e9
    local pid = assert(tonumber(result.stdout:match("^(%d+)")), result.stdout)
    local gone = false
    for _ = 1, 100 do
        if not uv.kill(pid, 0) then
            gone = true
            break
        end
        uv.sleep(10)
    end
    test.assertTrue(result.timed_out)
    test.assertTrue(elapsed < 1.5, ("the call took %.2f seconds"):format(elapsed))
    test.assertTrue(gone, "the backgrounded sleep is still running")
    if not gone then
        uv.kill(pid, "sigkill")
    end
end

return M
