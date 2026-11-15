# Gate runner

`check.lua` runs the development gates. It first makes the tmux sandbox
([sandbox_host.lua](../../tests/support/sandbox_host.lua)), so nothing a gate
starts can reach a server of the developer's, and it fails the run when a
socket is left in the sandbox, even when every test passed. Each command prints
one JSON line with its exit code and wall time, and each gate prints its own
and fails when it exceeds its loop budget from
[CONTRIBUTING.md](../../.github/CONTRIBUTING.md#test-loops).

| Gate | Runs |
| --- | --- |
| `unit` | The unit suites under the selected Lua, or the ones named. |
| `mid` | The script tests, actionlint, then `unit`, `format`, `lint`, `generated` and `docs`. |
| `format`, `lint` | StyLua and luacheck over `lua`, `tests`, `examples` and `scripts`. |
| `generated` | The catalog generators' `--check`, the release drift and the changelog check. |
| `docs` | Markdown links and anchors, the README examples and `CLAUDE.md`. |
| `integration`, `refusal` | The owned-tmux integration suites of [tests/run_integration.lua](../../tests/run_integration.lua), or only the version-refusal ones. |
| `package` | The installed-rock checks of [scripts/package](../package/README.md). |
| `types` | LuaLS diagnostics, the documentation export and the editor completion check. |
| `outer` | `mid`, `integration`, `package` and `types`. |

## Who runs it

Every job of [ci.yml](../../.github/workflows/ci.yml) and every maintainer, as
CONTRIBUTING.md describes.

## Run it

Run the whole mid loop:

```console
$ mise exec -- luajit scripts/check/check.lua mid
```

Run one unit suite under another interpreter:

```console
$ mise exec -- luajit scripts/check/check.lua unit query \
    --lua .cache/toolchains/lua-5.1.5/bin/lua
```

Run one integration suite, here `tests/integration/test_buffer.lua`:

```console
$ mise exec -- luajit scripts/check/check.lua integration buffer \
    --lua .cache/toolchains/luajit-2.1/bin/luajit \
    --nvim .cache/toolchains/nvim-0.12.5/bin/nvim
```

Run the tests of the runner and the sandbox:

```console
$ luajit scripts/support/run_tests.lua \
    scripts/check/tests/test_check.lua \
    scripts/check/tests/test_sandbox_host.lua
```
