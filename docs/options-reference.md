# tmux option and hook reference

This generated catalog records every canonical built-in option and hook
in the supported tmux releases listed below. It describes native types
and storage scopes; it does not establish runtime or platform compatibility.
Edit [the catalog](../data/tmux-options.json), then regenerate:

```console
$ python scripts/generate_options.py
```

Check generated Lua metadata and this reference without changing files:

```console
$ python scripts/generate_options.py --check
```

Both commands run offline with Python and the pinned StyLua formatter.
`--verify-source` additionally accepts a local tmux Git checkout and checks
every release tag, pinned source digest, definition and line anchor. It
does not download sources, build tmux or start a server.

## Values and scopes

Built-in names select their native storage scope; command flags alone do
not enforce the caller's intended scope. Session and window defaults are
separate global stores. Pane-capable options also support window storage;
there is no global pane store. Unknown release strings require new source
evidence: the private catalog does not fall back to the latest version.

Flags use booleans, numbers use exact bounded integers, and choices use
literal strings, including numeric-looking choices such as `"24"`. Keys,
colours, styles and commands retain their native string grammars. A command
value is tmux command-list source, not shell argv. Native grammar validation
and remote conditions such as shell suitability still require tmux.

Arrays retain native zero-based sparse indices and their element type.
The separator is a set of splitting characters, not a reversible codec.
An omitted array separator means space/comma; an empty separator preserves
one complete command-list entry. Indexed assignment avoids splitting.
All built-in hooks are command arrays; a scalar command option is not a
hook. User options beginning with `@` are separate string scalars.

Global built-in unset restores the default; local unset removes an override.
Native aliases, prefix matching, default values and descriptive option text
are outside this catalog. Source integer limits assume the supported target
ABIs' 32-bit `int` and 16-bit `short`; the largest bound is 4294967295.

## Source releases

| Release | Built-ins, including hooks | Hooks |
| --- | ---: | ---: |
| [3.3a](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c) | 181 | 65 |
| [3.4](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c) | 186 | 65 |
| [3.5](https://github.com/tmux/tmux/blob/ac44566c9c7e3e94d23be6def4c7ae83472543f5/options-table.c) | 190 | 66 |
| [3.5a](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/options-table.c) | 190 | 66 |
| [3.6](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c) | 210 | 68 |
| [3.6a](https://github.com/tmux/tmux/blob/cc117b5048f77a4842820f8ebbe3a86e5c077224/options-table.c) | 210 | 68 |
| [3.6b](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/options-table.c) | 210 | 68 |
| [3.7](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c) | 221 | 68 |
| [3.7a](https://github.com/tmux/tmux/blob/0e418b62d259ce8da8970f75732cc6632ee4c3a0/options-table.c) | 221 | 68 |
| [3.7b](https://github.com/tmux/tmux/blob/e802909de06012a4df6209d55e86487c56223163/options-table.c) | 221 | 68 |
| [3.7c](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/options-table.c) | 221 | 68 |
| [3.7d](https://github.com/tmux/tmux/blob/0d7b9e87f45d51e96c4f6f26450bcbb2411f11c8/options-table.c) | 221 | 68 |
| [3.8](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c) | 272 | 89 |
| [next-3.9](https://github.com/tmux/tmux/blob/b17d3da7cd84114e4c58630637f0b80428c0aa34/options-table.c) | 270 | 89 |

Full commit identities, hashes for `options-table.c`, `options.c` and
`tmux.h`, and per-entry source anchors are recorded in the source catalog.
Repeated release labels below mean the extracted metadata is identical,
not that defaults or other native behavior are identical.

## Options

| Name | Releases | Scope | Value | Array separator |
| --- | --- | --- | --- | --- |
| [`activity-action`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L383) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `none`, `any`, `current`, `other` | — |
| [`aggressive-resize`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L794) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | flag | — |
| [`allow-passthrough`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L804) | 3.3a | window, pane | flag | — |
| [`allow-passthrough`](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c#L859) | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | `off`, `on`, `all` | — |
| [`allow-rename`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L812) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | flag | — |
| [`allow-set-title`](https://github.com/tmux/tmux/blob/ac44566c9c7e3e94d23be6def4c7ae83472543f5/options-table.c#L900) | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | flag | — |
| [`alternate-screen`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L820) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | flag | — |
| [`assume-paste-time`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L391) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..2147483647 | — |
| [`automatic-rename`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L828) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | flag | — |
| [`automatic-rename-format`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L835) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`backspace`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L205) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | key | — |
| [`base-index`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L402) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..2147483647 | — |
| [`bell-action`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L411) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `none`, `any`, `current`, `other` | — |
| [`buffer-limit`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L212) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | 1..2147483647 | — |
| [`clear-on-attach`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L312) | 3.8, next-3.9 | server | flag | — |
| [`clock-mode-colour`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L843) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | window | colour | — |
| [`clock-mode-colour`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1322) | 3.8, next-3.9 | window | colour | — |
| [`clock-mode-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L850) | 3.3a, 3.4, 3.5, 3.5a | window | `12`, `24` | — |
| [`clock-mode-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1093) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | `12`, `24`, `12-with-seconds`, `24-with-seconds` | — |
| [`codepoint-widths`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L306) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string; sparse array | `","` |
| [`command-alias`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L222) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string; sparse array | `","` |
| [`copy-command`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L237) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string | — |
| [`copy-mode-current-line-number-style`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1208) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`copy-mode-current-line-style`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1448) | 3.8, next-3.9 | window | style string | — |
| [`copy-mode-current-match-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L867) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`copy-mode-line-number-style`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1217) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`copy-mode-line-numbers`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1226) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | `off`, `default`, `absolute`, `relative`, `hybrid` | — |
| [`copy-mode-mark-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L876) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`copy-mode-match-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L858) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`copy-mode-position-format`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1128) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | string | — |
| [`copy-mode-position-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1140) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`copy-mode-selection-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1149) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`cursor-colour`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L245) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | window, pane | colour | — |
| [`cursor-colour`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L354) | 3.8, next-3.9 | window, pane | colour | — |
| [`cursor-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L252) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | `default`, `blinking-block`, `block`, `blinking-underline`, `underline`, `blinking-bar`, `bar` | — |
| [`dark-theme-black`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L574) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-blue`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L630) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-cyan`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L638) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-dark-grey`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L598) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-green`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L606) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-light-grey`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L590) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-magenta`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L646) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-red`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L622) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-white`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L582) | 3.8, next-3.9 | server | colour | — |
| [`dark-theme-yellow`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L614) | 3.8, next-3.9 | server | colour | — |
| [`default-client-command`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L338) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | command | — |
| [`default-command`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L419) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`default-shell`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L427) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`default-size`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L434) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`default-terminal`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L260) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string | — |
| [`destroy-unattached`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L442) | 3.3a | session | flag | — |
| [`destroy-unattached`](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c#L488) | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `off`, `on`, `keep-last`, `keep-group` | — |
| [`detach-on-destroy`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L450) | 3.3a | session | `off`, `on`, `no-detached` | — |
| [`detach-on-destroy`](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c#L497) | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `off`, `on`, `no-detached`, `previous`, `next` | — |
| [`display-panes-active-colour`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L459) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | session | colour | — |
| [`display-panes-active-colour`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1338) | 3.8, next-3.9 | window | colour | — |
| [`display-panes-border-style`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1346) | 3.8, next-3.9 | window | style string | — |
| [`display-panes-colour`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L466) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | session | colour | — |
| [`display-panes-colour`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1355) | 3.8, next-3.9 | window | colour | — |
| [`display-panes-format`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1363) | 3.8, next-3.9 | window | string | — |
| [`display-panes-time`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L473) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | session | 1..2147483647 | — |
| [`display-panes-time`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1372) | 3.8, next-3.9 | window | 1..2147483647 | — |
| [`display-time`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L483) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..2147483647 | — |
| [`editor`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L267) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string | — |
| [`escape-time`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L274) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | 0..2147483647 | — |
| [`exit-empty`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L284) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | flag | — |
| [`exit-unattached`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L291) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | flag | — |
| [`extended-keys`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L299) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | `off`, `on`, `always` | — |
| [`extended-keys-format`](https://github.com/tmux/tmux/blob/ac44566c9c7e3e94d23be6def4c7ae83472543f5/options-table.c#L320) | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | `csi-u`, `xterm` | — |
| [`fill-character`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L885) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`focus-events`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L308) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | flag | — |
| [`focus-follows-mouse`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L670) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | flag | — |
| [`get-clipboard`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L414) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | `off`, `buffer`, `request`, `both` | — |
| [`history-file`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L315) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string | — |
| [`history-limit`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L493) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..2147483647 | — |
| [`initial-repeat-time`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L664) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..2000000 | — |
| [`input-buffer-size`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L416) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | 1048576..4294967295 | — |
| [`key-table`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L505) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`light-theme-black`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L654) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-blue`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L710) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-cyan`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L718) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-dark-grey`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L678) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-green`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L686) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-light-grey`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L670) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-magenta`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L726) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-red`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L702) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-white`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L662) | 3.8, next-3.9 | server | colour | — |
| [`light-theme-yellow`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L694) | 3.8, next-3.9 | server | colour | — |
| [`lock-after-time`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L513) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..2147483647 | — |
| [`lock-command`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L523) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`main-pane-height`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L892) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`main-pane-width`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L900) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`menu-border-lines`](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c#L359) | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | `single`, `double`, `heavy`, `simple`, `rounded`, `padded`, `none` | — |
| [`menu-border-style`](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c#L350) | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`menu-selected-style`](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c#L341) | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`menu-style`](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c#L332) | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`message-command-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L530) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | style string | — |
| [`message-format`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L736) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`message-limit`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L323) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | 0..2147483647 | — |
| [`message-line`](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c#L587) | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `0`, `1`, `2`, `3`, `4` | — |
| [`message-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L540) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | style string | — |
| [`mode-keys`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L908) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | `emacs`, `vi` | — |
| [`mode-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L916) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`monitor-activity`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L925) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | flag | — |
| [`monitor-bell`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L932) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | flag | — |
| [`monitor-silence`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L939) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | 0..2147483647 | — |
| [`mouse`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L549) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | flag | — |
| [`other-pane-height`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L950) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`other-pane-width`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L958) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`pane-active-border-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L966) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | window | style string | — |
| [`pane-active-border-style`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1315) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | style string | — |
| [`pane-base-index`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L975) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | 0..65535 | — |
| [`pane-border-format`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L984) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | string | — |
| [`pane-border-indicators`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L992) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | `off`, `colour`, `arrows`, `both` | — |
| [`pane-border-lines`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1001) | 3.3a, 3.4, 3.5, 3.5a | window | `single`, `double`, `heavy`, `simple`, `number` | — |
| [`pane-border-lines`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1274) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | window | `single`, `double`, `heavy`, `simple`, `number`, `spaces` | — |
| [`pane-border-lines`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1603) | 3.8 | window, pane | `single`, `double`, `heavy`, `simple`, `number`, `spaces`, `none` | — |
| [`pane-border-lines`](https://github.com/tmux/tmux/blob/b17d3da7cd84114e4c58630637f0b80428c0aa34/options-table.c#L1618) | next-3.9 | window, pane | `single`, `double`, `heavy`, `simple`, `number`, `spaces`, `none`, `rounded` | — |
| [`pane-border-status`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1010) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | window | `off`, `top`, `bottom` | — |
| [`pane-border-status`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1612) | 3.8, next-3.9 | window, pane | `off`, `top`, `bottom`, `top-floating`, `bottom-floating` | — |
| [`pane-border-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1018) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | window | style string | — |
| [`pane-border-style`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1374) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | style string | — |
| [`pane-colours`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1027) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | colour; sparse array | `" ,"` |
| [`pane-scrollbars`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1308) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | window | `off`, `modal`, `on` | — |
| [`pane-scrollbars`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1637) | 3.8, next-3.9 | window | `off`, `modal`, `on`, `auto-hide` | — |
| [`pane-scrollbars-position`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1325) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | `right`, `left` | — |
| [`pane-scrollbars-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1316) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | style string | — |
| [`pane-scrollbars-timeout`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1645) | 3.8, next-3.9 | window | 0..2147483647 | — |
| [`pane-status-current-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L924) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`pane-status-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L933) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`popup-border-lines`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1053) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8 | window | `single`, `double`, `heavy`, `simple`, `rounded`, `padded`, `none` | — |
| [`popup-border-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1044) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8 | window | style string | — |
| [`popup-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1035) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8 | window | style string | — |
| [`prefix`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L558) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | key | — |
| [`prefix-timeout`](https://github.com/tmux/tmux/blob/ac44566c9c7e3e94d23be6def4c7ae83472543f5/options-table.c#L388) | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | 0..2147483647 | — |
| [`prefix2`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L565) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | key | — |
| [`prompt-command-cursor-colour`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1165) | 3.8, next-3.9 | session | colour | — |
| [`prompt-command-cursor-style`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L997) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `default`, `blinking-block`, `block`, `blinking-underline`, `underline`, `blinking-bar`, `bar` | — |
| [`prompt-cursor-colour`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L943) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | session | colour | — |
| [`prompt-cursor-colour`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1157) | 3.8, next-3.9 | session | colour | — |
| [`prompt-cursor-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L950) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `default`, `blinking-block`, `block`, `blinking-underline`, `underline`, `blinking-bar`, `bar` | — |
| [`prompt-history-limit`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L332) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | 0..2147483647 | — |
| [`remain-on-exit`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1062) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | window, pane | `off`, `on`, `failed` | — |
| [`remain-on-exit`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1443) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d | window, pane | `off`, `on`, `failed`, `key` | — |
| [`remain-on-exit`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1699) | 3.8, next-3.9 | window, pane | `off`, `on`, `failed`, `key`, `failed-key` | — |
| [`remain-on-exit-format`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1071) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | string | — |
| [`renumber-windows`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L572) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | flag | — |
| [`repeat-time`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L580) | 3.3a, 3.4, 3.5, 3.5a | session | 0..32767 | — |
| [`repeat-time`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L759) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..2000000 | — |
| [`scroll-on-clear`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1084) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | flag | — |
| [`session-status-current-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L958) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`session-status-style`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L967) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`set-clipboard`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L341) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | `off`, `external`, `on` | — |
| [`set-titles`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L591) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | flag | — |
| [`set-titles-string`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L598) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`silence-action`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L605) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `none`, `any`, `current`, `other` | — |
| [`status`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L613) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `off`, `on`, `2`, `3`, `4`, `5` | — |
| [`status-bg`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L621) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | colour | — |
| [`status-fg`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L629) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | colour | — |
| [`status-format`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L637) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string; sparse array | `" ,"` |
| [`status-interval`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L649) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..2147483647 | — |
| [`status-justify`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L659) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `left`, `centre`, `right`, `absolute-centre` | — |
| [`status-keys`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L667) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `emacs`, `vi` | — |
| [`status-left`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L675) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`status-left-length`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L682) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..32767 | — |
| [`status-left-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L691) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | style string | — |
| [`status-position`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L700) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `top`, `bottom` | — |
| [`status-right`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L708) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`status-right-length`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L718) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | 0..32767 | — |
| [`status-right-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L727) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | style string | — |
| [`status-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L736) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | style string | — |
| [`switch-mode-match-style`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1731) | 3.8, next-3.9 | window, pane | style string | — |
| [`synchronize-panes`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1092) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | flag | — |
| [`terminal-features`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L360) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string; sparse array | `","` |
| [`terminal-overrides`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L351) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string; sparse array | `","` |
| [`theme`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L565) | 3.8, next-3.9 | server | `detect`, `terminal`, `light`, `dark` | — |
| [`tiled-layout-max-columns`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1397) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | 0..65535 | — |
| [`tree-mode-border-style`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1757) | 3.8, next-3.9 | window | style string | — |
| [`tree-mode-preview-format`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1491) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | string | — |
| [`tree-mode-preview-style`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1500) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`tree-mode-selection-style`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1788) | 3.8, next-3.9 | window | style string | — |
| [`update-environment`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L745) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string; sparse array | `" ,"` |
| [`user-keys`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L371) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | string; sparse array | `","` |
| [`variation-selector-always-wide`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L532) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | server | flag | — |
| [`visual-activity`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L755) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `off`, `on`, `both` | — |
| [`visual-bell`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L764) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `off`, `on`, `both` | — |
| [`visual-silence`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L773) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | `off`, `on`, `both` | — |
| [`window-active-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1099) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | style string | — |
| [`window-default-command`](https://github.com/tmux/tmux/blob/b17d3da7cd84114e4c58630637f0b80428c0aa34/options-table.c#L1794) | next-3.9 | window | string | — |
| [`window-pane-current-status-format`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1522) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`window-pane-status-format`](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c#L1529) | 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`window-size`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1108) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | `largest`, `smallest`, `manual`, `latest` | — |
| [`window-status-activity-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1129) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`window-status-bell-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1138) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`window-status-current-format`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1147) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`window-status-current-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1154) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`window-status-format`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1163) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`window-status-last-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1171) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`window-status-separator`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1180) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | string | — |
| [`window-status-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1187) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | style string | — |
| [`window-style`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1120) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | style string | — |
| [`word-separators`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L782) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | string | — |
| [`wrap-search`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1197) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | flag | — |
| [`xterm-keys`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1205) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | flag | — |

## Hooks

| Name | Releases | Scope | Value | Array separator |
| --- | --- | --- | --- | --- |
| [`after-bind-key`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1214) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-capture-pane`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1215) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-copy-mode`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1216) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-display-message`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1217) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-display-panes`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1218) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-kill-pane`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1219) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-list-buffers`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1220) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-list-clients`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1221) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-list-keys`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1222) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-list-panes`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1223) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-list-sessions`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1224) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-list-windows`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1225) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-load-buffer`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1226) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-lock-server`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1227) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-new-session`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1228) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-new-window`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1229) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-paste-buffer`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1230) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-pipe-pane`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1231) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-queue`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1232) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d | session | command; sparse array | empty |
| [`after-refresh-client`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1233) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-rename-session`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1234) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-rename-window`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1235) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-resize-pane`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1236) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-resize-window`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1237) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-save-buffer`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1238) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-select-layout`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1239) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-select-pane`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1240) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-select-window`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1241) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-send-keys`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1242) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-set-buffer`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1243) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-set-environment`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1244) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-set-hook`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1245) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-set-option`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1246) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-show-environment`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1247) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-show-messages`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1248) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-show-options`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1249) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-split-window`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1250) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-swap-window`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1963) | 3.8, next-3.9 | session | command; sparse array | empty |
| [`after-unbind-key`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1251) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`alert-activity`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1252) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`alert-bell`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1253) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`alert-silence`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1254) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-active`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1255) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-attached`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1256) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-closed`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1978) | 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-created`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1976) | 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-dark-theme`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1571) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-detached`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1257) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-focus-in`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1258) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-focus-out`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1259) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-light-theme`](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c#L1570) | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-resized`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1260) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`client-session-changed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1261) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`command-error`](https://github.com/tmux/tmux/blob/ac44566c9c7e3e94d23be6def4c7ae83472543f5/options-table.c#L1350) | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`marked-pane-changed`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1996) | 3.8, next-3.9 | session | command; sparse array | empty |
| [`pane-activity`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L1998) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-bell`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2000) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-command-finished`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2002) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-command-started`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2004) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-created`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2006) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-died`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1262) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-exited`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1263) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-focus-in`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1264) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-focus-out`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1265) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-mode-changed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1266) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-mode-entered`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2021) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-mode-exited`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2023) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-moved`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2025) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-prompt-closed`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2027) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-prompt-opened`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2029) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-resized`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2031) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-set-clipboard`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1267) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-shell-prompt`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2036) | 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`pane-title-changed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1268) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window, pane | command; sparse array | empty |
| [`session-added-to-group`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2044) | 3.8, next-3.9 | session | command; sparse array | empty |
| [`session-closed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1269) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`session-created`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1270) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`session-removed-from-group`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2048) | 3.8, next-3.9 | session | command; sparse array | empty |
| [`session-renamed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1271) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`session-window-changed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1272) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`window-closed`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2054) | 3.8, next-3.9 | window | command; sparse array | empty |
| [`window-created`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2052) | 3.8, next-3.9 | window | command; sparse array | empty |
| [`window-layout-changed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1273) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | command; sparse array | empty |
| [`window-linked`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1274) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`window-pane-changed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1275) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | command; sparse array | empty |
| [`window-renamed`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1276) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | command; sparse array | empty |
| [`window-resized`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1277) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | window | command; sparse array | empty |
| [`window-unlinked`](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c#L1278) | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.7d, 3.8, next-3.9 | session | command; sparse array | empty |
| [`window-unzoomed`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2067) | 3.8, next-3.9 | window | command; sparse array | empty |
| [`window-zoomed`](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c#L2069) | 3.8, next-3.9 | window | command; sparse array | empty |
