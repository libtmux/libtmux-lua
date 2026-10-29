# tmux field catalog

This curated catalog describes the scalar fields needed by the core entity
model. It does not enumerate every tmux format. Edit
[the source catalog](../data/tmux-fields.json) and regenerate this reference
together with Lua metadata and LuaLS field annotations:

```console
$ python scripts/generate_fields.py
```

Check generated files without changing them:

```console
$ python scripts/generate_fields.py --check
```

Generation uses Python and the pinned StyLua formatter; it needs no network
or tmux process. The optional `--verify-source` argument accepts a local tmux
Git checkout and verifies every pinned format mapping and source anchor.

## Availability and values

`Since` means the first release supported by this catalog for that field,
not necessarily the release that introduced it. The floor is tmux 3.3a.
Source inspection establishes format availability; it does not establish
complete runtime or platform compatibility. The schema helper accepts recognized
final, release-candidate and `next-X.Y` reports that rank at or above the floor.
Field availability is checked against that rank. Unrecognized reports and
versions below the floor are rejected.

Record names are Lua aliases for literal tmux format names. IDs retain their
`$`, `@`, and `%` prefixes. `number` fields represent integers; consumers must
reject values outside the exact integer range of their Lua runtime rather
than silently round them. All generated LuaLS fields are optional because a
projection may leave a field unloaded.

Nullable fields may be absent within an otherwise valid native context.
Loaded absence uses `query.NULL`; an omitted key means not loaded. Known
fields unavailable at the requested version remain in the query schema with
`supported = false`. Empty text remains text for nonnullable string fields.
The scalar catalog does not build relationships or perform I/O.

Window index, active state, and flags belong to `window_link`. Windows and
panes have no scalar session ID because a window can be linked into several
sessions. `client_session` provides a session name, not a session ID. Client
names and buffer names need contextual revalidation before later mutations.

## Source provenance

- floor: [3.3a](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/format.c).
- stable: [3.7c](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c).
- upstream: [inspected upstream revision](https://github.com/tmux/tmux/blob/e880cf63e0a9fe095d7c5d313761520fb1a8653c/format.c).

## Server

| Record field | tmux format | Type | Nullable | Since | Native scope |
| --- | --- | --- | --- | --- | --- |
| `pid` | [`pid`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L541) | number | no | 3.3a | server |
| `socket_path` | [`socket_path`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2690) | string | no | 3.3a | server |
| `version` | [`version`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2697) | string | no | 3.3a | server |
| `start_time` | [`start_time`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L3107) | number | no | 3.3a | server |

- `pid`: Daemon process ID.
- `socket_path`: Socket path reported by the daemon.
- `version`: Daemon version string.
- `start_time`: Daemon start time in Unix seconds.

## Session

| Record field | tmux format | Type | Nullable | Since | Native scope |
| --- | --- | --- | --- | --- | --- |
| `id` | [`session_id`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2630) | string | no | 3.3a | session |
| `name` | [`session_name`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2663) | string | no | 3.3a | session |
| `created` | [`session_created`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L3089) | number | no | 3.3a | session |
| `activity` | [`session_activity`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L3080) | number | no | 3.3a | session |
| `attached` | [`session_attached`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2553) | number | no | 3.3a | session |
| `window_count` | [`session_windows`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2681) | number | no | 3.3a | session |
| `group` | [`session_group`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2571) | string | yes | 3.3a | session |
| `grouped` | [`session_grouped`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2618) | boolean | no | 3.3a | session |
| `path` | [`session_path`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2672) | string | no | 3.3a | session |

- `id`: Session ID, including its dollar-sign prefix.
- `name`: Session name.
- `created`: Creation time in Unix seconds.
- `activity`: Last activity time in Unix seconds.
- `attached`: Attached client count, not a boolean.
- `window_count`: Number of window links in this session.
- `group`: Session group name; absent for an ungrouped session.
- `grouped`: Whether this session belongs to a group.
- `path`: Session working directory.

## Window

| Record field | tmux format | Type | Nullable | Since | Native scope |
| --- | --- | --- | --- | --- | --- |
| `id` | [`window_id`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2844) | string | no | 3.3a | window |
| `name` | [`window_name`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2936) | string | no | 3.3a | window |
| `width` | [`window_width`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L3015) | number | no | 3.3a | window |
| `height` | [`window_height`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2835) | number | no | 3.3a | window |
| `pane_count` | [`window_panes`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2973) | number | no | 3.3a | window |
| `layout` | [`window_layout`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L839) | string | yes | 3.3a | window |
| `visible_layout` | [`window_visible_layout`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L853) | string | yes | 3.3a | window |
| `zoomed` | [`window_zoomed_flag`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L3024) | boolean | no | 3.3a | window |

- `id`: Window ID, including its at-sign prefix.
- `name`: Window name.
- `width`: Width in character cells.
- `height`: Height in character cells.
- `pane_count`: Number of panes owned by this window.
- `layout`: Layout including panes hidden by zoom; absent without a layout tree.
- `visible_layout`: Visible layout; absent without a layout tree.
- `zoomed`: Whether this window is zoomed.

## Window link

| Record field | tmux format | Type | Nullable | Since | Native scope |
| --- | --- | --- | --- | --- | --- |
| `session_id` | [`session_id`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2630) | string | no | 3.3a | session |
| `window_id` | [`window_id`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2844) | string | no | 3.3a | window |
| `index` | [`window_index`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2853) | number | no | 3.3a | winlink |
| `active` | [`window_active`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2737) | boolean | no | 3.3a | winlink |
| `flags` | [`window_flags`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2817) | string | no | 3.3a | winlink |

- `session_id`: Session owning this contextual link.
- `window_id`: Underlying window shared by links.
- `index`: tmux index within the session, not Lua array position.
- `active`: Whether this link is the session current window.
- `flags`: Printable flags for this session/window link.

## Pane

| Record field | tmux format | Type | Nullable | Since | Native scope |
| --- | --- | --- | --- | --- | --- |
| `id` | [`pane_id`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2152) | string | no | 3.3a | pane |
| `window_id` | [`window_id`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2844) | string | no | 3.3a | window |
| `index` | [`pane_index`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2161) | number | no | 3.3a | pane |
| `active` | [`pane_active`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2028) | boolean | no | 3.3a | pane |
| `title` | [`pane_title`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2384) | string | no | 3.3a | pane |
| `width` | [`pane_width`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2411) | number | no | 3.3a | pane |
| `height` | [`pane_height`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2143) | number | no | 3.3a | pane |
| `left` | [`pane_left`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2225) | number | no | 3.3a | pane |
| `top` | [`pane_top`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2393) | number | no | 3.3a | pane |
| `pid` | [`pane_pid`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2285) | number | no | 3.3a | pane |
| `tty` | [`pane_tty`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2402) | string | no | 3.3a | pane |
| `current_path` | [`pane_current_path`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L915) | string | yes | 3.3a | pane |
| `current_command` | [`pane_current_command`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L891) | string | yes | 3.3a | pane |
| `start_command` | [`pane_start_command`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L865) | string | no | 3.3a | pane |
| `dead` | [`pane_dead`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2075) | boolean | no | 3.3a | pane |
| `dead_status` | [`pane_dead_status`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2106) | number | yes | 3.3a | pane |
| `dead_signal` | [`pane_dead_signal`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2089) | string | yes | 3.3a | pane |
| `dead_time` | [`pane_dead_time`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2120) | number | yes | 3.3a | pane |
| `mode` | [`pane_mode`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2258) | string | yes | 3.3a | pane |
| `mode_count` | [`pane_in_mode`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1138) | number | no | 3.3a | pane |
| `synchronized` | [`pane_synchronized`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L2372) | boolean | no | 3.3a | pane |

- `id`: Pane ID, including its percent-sign prefix.
- `window_id`: ID of the window that owns this pane.
- `index`: tmux pane index within its window.
- `active`: Whether this pane is active in its window.
- `title`: Pane title; an empty title remains an empty string.
- `width`: Width in character cells.
- `height`: Height in character cells.
- `left`: Left cell offset in the window.
- `top`: Top cell offset in the window.
- `pid`: PID recorded for the pane process.
- `tty`: Pseudo-terminal name; empty is preserved.
- `current_path`: Process working directory when the OS can determine it.
- `current_command`: Displayed command name; absent without pane shell context.
- `start_command`: Stringified startup argv; this is not a shell-safe command.
- `dead`: Whether tmux has a ready dead-process status.
- `dead_status`: Exit status only when the process exited normally.
- `dead_signal`: Signal name only when the process terminated by signal.
- `dead_time`: Dead-pane display time in Unix seconds, when available.
- `mode`: Top mode name; absent outside pane modes.
- `mode_count`: Number of active modes, not a boolean.
- `synchronized`: Effective synchronize-panes option.

## Client

| Record field | tmux format | Type | Nullable | Since | Native scope |
| --- | --- | --- | --- | --- | --- |
| `name` | [`client_name`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1539) | string | no | 3.3a | client |
| `tty` | [`client_tty`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1623) | string | no | 3.3a | client |
| `pid` | [`client_pid`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1548) | number | no | 3.3a | client |
| `session_name` | [`client_session`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1584) | string | yes | 3.3a | client |
| `width` | [`client_width`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1677) | number | yes | 3.3a | client |
| `height` | [`client_height`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1510) | number | yes | 3.3a | client |
| `control_mode` | [`client_control_mode`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1480) | boolean | no | 3.3a | client |
| `readonly` | [`client_readonly`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1572) | boolean | no | 3.3a | client |
| `created` | [`client_created`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L3071) | number | no | 3.3a | client |
| `activity` | [`client_activity`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L3062) | number | no | 3.3a | client |

- `name`: Observed client name; not a persistent identifier.
- `tty`: Observed terminal name; empty is preserved.
- `pid`: Client process ID.
- `session_name`: Attached session name, not a session ID.
- `width`: Terminal width; nullable without a started TTY.
- `height`: Terminal height; nullable without a started TTY.
- `control_mode`: Whether this is a control-mode client.
- `readonly`: Whether this client is read-only.
- `created`: Creation time in Unix seconds.
- `activity`: Last activity time in Unix seconds.

## Buffer

| Record field | tmux format | Type | Nullable | Since | Native scope |
| --- | --- | --- | --- | --- | --- |
| `name` | [`buffer_name`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1416) | string | no | 3.3a | buffer |
| `size` | [`buffer_size`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1449) | number | no | 3.3a | buffer |
| `sample` | [`buffer_sample`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1425) | string | no | 3.3a | buffer |
| `created` | [`buffer_created`](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L3048) | number | no | 3.3a | buffer |

- `name`: Buffer name; revalidate before later mutations.
- `size`: Buffer size in bytes.
- `sample`: tmux printable preview; not complete buffer bytes.
- `created`: Creation time in Unix seconds.
