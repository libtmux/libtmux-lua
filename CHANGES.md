# Changelog

## Unreleased

- Server ownership: accept and clean up created daemons through their private endpoints. Retain the published socket alias after daemon exit or startup rollback so cleanup cannot unlink a concurrent replacement. Reusing a stale path requires caller-coordinated alias retirement or a different path.
- Discovery: use the same first `TMUX_TMPDIR` value as connection defaults, including an empty value that selects `/tmp`.

- Add task-scoped ownership and explicit adoption for servers, sessions, windows and panes, generation-guarded cleanup, retryable owners and complete-receipt rollback.
- Add foreground server startup, bounded discovery and created/reused results for server, session, window and keyed-pane lookup.

- Connections: select an existing daemon through captured path/name defaults,
  tmux context or the default named socket. Explicit selectors still take
  precedence. Resolve omitted executables through captured `PATH`; accept
  copied `client_env` overrides and remove nested tmux context from clients.
- Runtime: add `defer` for asynchronous task cleanup after success, body errors
  and cancellation, with body and teardown failures retained in the result.
- Examples: add an ordinary default-connection example and an external private
  harness that verifies its session cleanup. Use owned server scopes for
  fresh-daemon creation and cleanup.

- Docs: add complete common API examples with private tmux setup and cleanup.

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
