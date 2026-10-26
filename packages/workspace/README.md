<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Lua workspace">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux-workspace

A development package for planned libtmux workspace operations in Lua. It is
unpublished and builds nothing yet.

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/lua/)

</div>

- It has no loader, command or builder API, so there is no workspace file to
  load and no command to run.
- [`require("libtmux_workspace")`](https://github.com/libtmux/libtmux-lua/blob/master/packages/workspace/lua/libtmux_workspace/init.lua)
  returns a table whose only field is `_VERSION`.
- The rock is not on LuaRocks.
  [libtmux.org](https://libtmux.org/en/lua/latest/workspace/) records the same
  availability.

**Contents** — [Quick start](#quick-start) ·
[Tmux from Lua today](#drive-tmux-from-lua-today) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status)

## Quick start

Build the package from a checkout and print its version. The rockspec depends
on [`libtmux`][ref-libtmux], [`luv`][luv], [`lunajson`][lunajson] and
[`lyaml`][lyaml]. Two of them build native code:

- `luv` needs a C compiler and CMake.
- `lyaml` builds against [LibYAML][libyaml]. Install its development files
  first, or add `YAML_DIR=<prefix>` to the workspace build command below.

From the repository root, install the core rock first:

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

`scm` marks a development build. Loading the module starts neither tmux nor an
event loop: the package check installs the rock into an empty tree, imports
it, and asserts both. See
[validation](https://github.com/libtmux/libtmux-lua/blob/master/.github/CONTRIBUTING.md#validation)
for how to run it.

## Drive tmux from Lua today

The core library already creates and arranges panes.
[`Server:new_session`][ref-server-new-session] starts a session,
[`Session:new_window`][ref-session-new-window] adds a window and
[`Pane:split`][ref-pane-split] divides it.

The
[root README](https://github.com/libtmux/libtmux-lua/blob/master/README.md#create-sessions-windows-and-panes)
runs each with a tested example.

## What it leaves out

- **A workspace loader.** No YAML or JSON file is read, so `lyaml` and
  `lunajson` are installed but unused.
- **Any function.** The module exports `_VERSION` and nothing else. Reach
  tmux through [`libtmux`][ref-libtmux].

## Support and status

- **Unpublished development scaffold.** Build it from a checkout, as above.
- **Lua 5.1 to 5.5.** The rockspec asks for `luv` 1.52.1 or newer,
  `lunajson` 1.2.3 or newer and `lyaml` 6.2.9 or newer.
- **Linux, including WSL.** CI runs the package check on Ubuntu 24.04, on Lua
  5.1.5 and 5.5.1. No CI job runs on macOS, so macOS is untested.

[ref-libtmux]: https://libtmux.org/en/lua/latest/reference/
[ref-server-new-session]: https://libtmux.org/en/lua/latest/reference/libtmux-server-new_session/
[ref-session-new-window]: https://libtmux.org/en/lua/latest/reference/libtmux-session-new_window/
[ref-pane-split]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-split/
[luv]: https://github.com/luvit/luv
[lunajson]: https://luarocks.org/modules/grafi/lunajson
[lyaml]: https://luarocks.org/modules/gvvaughan/lyaml
[libyaml]: https://pyyaml.org/wiki/LibYAML
