# libtmux-workspace

A development package for planned libtmux workspace operations in Lua. It is
unpublished and builds nothing yet.

- It has no loader, command or builder API, so there is no workspace file to
  load and no command to run.
- `require("libtmux_workspace")` returns a table whose only field is
  `_VERSION`.
- The rock is not on LuaRocks.
  [libtmux.org](https://libtmux.org/en/lua/latest/workspace/) records the same
  availability.

## Build it from a checkout

The rockspec depends on `libtmux`, `luv`, `lunajson` and `lyaml`. Building
`luv` needs a C compiler and CMake. `lyaml` builds against LibYAML, so install
its development files first, or add `YAML_DIR=<prefix>` to the workspace
command below. From the repository root, install the core rock:

```console
$ luarocks --local make rockspecs/libtmux-scm-1.rockspec
```

Build this package:

```console
$ luarocks --local make rockspecs/libtmux-workspace-scm-1.rockspec
```

Add the local rocks tree to Lua's module paths:

```console
$ eval "$(luarocks --local path)"
```

Load the module and print its version:

```console
$ lua -e 'print(require("libtmux_workspace")._VERSION)'
scm
```

The package check installs this rock into an empty tree and imports it
without side effects. See [validation](../../.github/CONTRIBUTING.md#validation)
for how to run it.
