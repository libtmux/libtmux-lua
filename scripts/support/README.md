# Support modules

Helpers the scripts share. Each script finds them with a three-line preamble
that puts `scripts/` on `package.path`, so `require("support.json")` works from
any directory.

| Module | Does |
| --- | --- |
| `repo` | The repository root, and the rock tree of the running LuaJIT on the search path. |
| `files` | Read, write and append whole files. |
| `json` | Decode keeping key order; encode like Python's `json.dumps`, compact or indented. |
| `shell` | Run a program with quoted arguments before luv exists: the bootstrap. |
| `runtime` | Identify an interpreter's ABI and name its rock tree. |
| `run_tests.lua` | Run luaunit suites: `luajit scripts/support/run_tests.lua scripts/*/tests/test_*.lua`. |

A script's tests live in `scripts/<name>/tests/` and return a table of luaunit
test functions, as `tests/unit` does.
