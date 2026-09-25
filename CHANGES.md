# Changelog

## Unreleased

- Types: declare `libtmux.Session`, `Window`, `WindowLink`, `Pane`, `Client`
  and `Buffer` handle classes. Each lists only the methods tmux accepts for
  that kind; `Server:handle` returns the class that matches the record.

## 0.1.0alpha1-1 (2026-09-20)

- Core: add explicit async requests, snapshots and queries for tmux objects.
- Core: add session, window, pane, buffer and client operations, with
  capability checks for tmux versions.
- Runtime: support explicit standalone luv and Neovim event-loop adapters.
- Packaging: prepare the first MIT-licensed core alpha. MCP and workspace
  packages remain development scaffolds and are not published.
