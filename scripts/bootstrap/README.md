# Bootstrap

`bootstrap.lua` builds and installs the cached tools the gates need. It is the
only network and build step; no test loop runs it.

## Who runs it

- CI, through the `lua-tools` action and the `validate` job of
  [ci.yml](../../.github/workflows/ci.yml).
- The docs workflow, for LuaLS.
- A maintainer setting up a checkout, as
  [CONTRIBUTING.md](../../.github/CONTRIBUTING.md) lists.

## Commands

| Command | Does |
| --- | --- |
| `runtimes VERSION...` | Builds PUC Lua releases (`5.1.5` to `5.5.1`) and `luajit` from pinned sources into `.cache/toolchains`. |
| `select-lua VERSION [--github-env=FILE]` | Names the interpreter a CI job tests under: mise's Lua for `5.5.1`, else the one `runtimes` builds. It prints the path and, with `--github-env`, appends `TEST_LUA=<path>` to FILE. |
| `rocks GROUP... [--lua=PATH]` | Installs the `dev`, `live` and `lint` rock groups into `.cache/rocks/<interpreter>`. |
| `hosts VERSION... [--check]` | Installs Neovim hosts and probes each one. `--check` makes no network call. |
| `luals` | Installs the pinned LuaLS into `.cache/tools`. |

`runtimes`, `select-lua`, `rocks` and `luals` use only the standard library, so
any Lua 5.1 to 5.5 runs them before the tool LuaJIT exists. `hosts` needs the
tool LuaJIT. Every download is verified against a pinned SHA256, and `curl`
retries a transient failure a bounded number of times.

## Run it

Build the tool LuaJIT:

```console
$ mise exec -- lua scripts/bootstrap/bootstrap.lua runtimes \
    luajit
```

Run the tests:

```console
$ luajit scripts/support/run_tests.lua \
    scripts/bootstrap/tests/test_bootstrap.lua
```
