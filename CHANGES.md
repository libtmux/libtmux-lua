# Changelog

## Unreleased

- Docs: add complete common API examples with private tmux setup and cleanup.
- Core: require tmux 3.3a, checked against the running tmux server rather
  than the `tmux` executable. Connecting to an older server, including 3.3
  without its patch letter, fails with `unsupported_version` before any
  command runs; upgrade tmux and restart the server after saving its
  sessions. Development builds pass only above the release they name. See
  the [proposal](https://github.com/libtmux/libtmux-lua/issues/31). (#35)
- Core: reading the server's version no longer runs the user's tmux hooks,
  and a control attachment no longer runs `display-message`. (#35)
- Core: commands no longer start a version probe each. The version is read
  once when the endpoint connects, and a server replaced afterwards fails
  with `stale_generation` before any command runs. (#35)
- Releases: support tmux 3.7d, 3.8 and the pinned next-3.9 development
  build in option, buffer, topology and layout operations, including 3.8's
  JSON layouts and the metadata escapes it adds. (#35)
- Control: observation needs tmux 3.7 or newer and returns `unsupported`
  before any attachment on an older daemon.
- Commands: refuse literal commands that are unsafe on the connected release
  before dispatch: named buffer deletion and rename below 3.4, custom layouts
  without a checksum below 3.4, `split-window -p` on 3.4, `break-pane` on
  exactly 3.7, and names containing `:` or `.` on exactly 3.7. Typed
  operations are unchanged. See the
  [proposal](https://github.com/libtmux/libtmux-lua/issues/32).

## 0.1.0alpha2-1

- Types: declare `libtmux.Session`, `Window`, `WindowLink`, `Pane`, `Client`
  and `Buffer` handle classes. Each lists only the methods tmux accepts for
  that kind; `Server:handle` returns the class that matches the record.
- Types: give each option, hook and environment operation its own options
  class, listing only the fields that operation accepts. `run_hook` takes
  `process` alone; `hidden` belongs to `set_environment`.

## 0.1.0alpha1-1 (2026-09-20)

- Core: add explicit async requests, snapshots and queries for tmux objects.
- Core: add session, window, pane, buffer and client operations, with
  capability checks for tmux versions.
- Runtime: support explicit standalone luv and Neovim event-loop adapters.
- Packaging: prepare the first MIT-licensed core alpha. MCP and workspace
  packages remain development scaffolds and are not published.
