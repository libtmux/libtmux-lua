#!/bin/sh
set -eu

program=${1:?Pass the complete Lua example filename}
binary=$(command -v "${TMUX_BIN:-tmux}")
case "$binary" in
    /*) ;;
    *) printf '%s\n' 'tmux must resolve to an absolute path' >&2; exit 1 ;;
esac
directory=$(mktemp -d "${TMPDIR:-/tmp}/libtmux-lua-api.XXXXXX")
socket="$directory/tmux.sock"

cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    if [ -S "$socket" ] && ! "$binary" -S "$socket" kill-server; then
        printf 'Cannot stop tmux; kept %s\n' "$directory" >&2
        exit 1
    fi
    rm -rf "$directory" || exit 1
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

unset TMUX TMUX_PANE
export TMUX_BIN="$binary" TMUX_SOCKET="$socket" ENV=/dev/null BASH_ENV=/dev/null
"$binary" -S "$socket" -f /dev/null \
    new-session -d -s bootstrap -n bootstrap /bin/cat
"${LUA_BIN:-lua}" "$program"
"$binary" -S "$socket" has-session -t '=bootstrap'
