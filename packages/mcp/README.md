# libtmux-mcp

A development package for the planned libtmux MCP server in Lua. It is
unpublished and serves nothing yet.

- It has no server, executable, tools, toolsets or prompts, so there is
  nothing to register with an MCP client and no tool to link.
- `require("libtmux_mcp")` returns a table whose only field is `_VERSION`.
- The rock is not on LuaRocks. [libtmux.org](https://libtmux.org/en/lua/latest/mcp/)
  records the same availability and has no tool reference for Lua.

## Build it from a checkout

The rockspec depends on `libtmux`, `luv` and `lunajson`. Building `luv`
needs a C compiler and CMake. From the repository root, install the core rock
first:

```console
$ luarocks --local make rockspecs/libtmux-scm-1.rockspec
```

Build this package:

```console
$ luarocks --local make rockspecs/libtmux-mcp-scm-1.rockspec
```

Add the local rocks tree to Lua's module paths:

```console
$ eval "$(luarocks --local path)"
```

Load the module and print its version:

```console
$ lua -e 'print(require("libtmux_mcp")._VERSION)'
scm
```

The package check installs this rock into an empty tree and imports it
without side effects. See [validation](../../.github/CONTRIBUTING.md#validation)
for how to run it.
