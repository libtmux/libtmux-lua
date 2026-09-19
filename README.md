# libtmux for Lua

This port is under development. It provides pure Lua queries, explicit
asynchronous connections, snapshots and live queries, literal commands, groups,
bounded batches, session/window/pane creation, Pane operations, and shared
session observation. Other domain operations and MCP/workspace consumers remain
under development; their separate packages currently provide scaffolds.

The [query API](docs/query.md) filters captured tables through Lua predicates
or validated structured criteria without tmux I/O. Explicit live query
Requests capture data and report source filtering and consistency evidence.

The package foundation separates `libtmux`, `libtmux-mcp`, and
`libtmux-workspace`. Requiring a package does not start tmux or an event loop.
The runtime adapters explicitly select luv or borrow Neovim's host loop.
Consumer dependencies do not belong in core-only installations.

- [Development and validation](.github/CONTRIBUTING.md)
- [Runtime ownership, cancellation and limits](docs/runtime.md)
- [Explicit connections and captured snapshots](docs/snapshots.md)
- [Literal commands, groups and independent batches](docs/commands.md)
- [Create sessions, windows and panes](docs/creation.md)
- [Capture, send input and manage panes](docs/panes.md)
- [Observe sessions and stream pane output](docs/control.md)
- [Read and change options and hooks](docs/settings.md)
- [Read and change persistent environment values](docs/environment.md)
- [Compatibility targets](docs/compatibility.md)
- [Writing conventions](.github/WRITING.md)

All live tests use explicit owned sockets and verify cleanup. Do not use a
default or personal tmux server for integration tests.
