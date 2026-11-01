#!/bin/sh
set -eu

program=${1:?Pass the complete Lua example filename}
binary=$(command -v "${TMUX_BIN:-tmux}")
case "$binary" in
    /*) ;;
    *) printf '%s\n' 'tmux must resolve to an absolute path' >&2; exit 1 ;;
esac
# The check that a server stopped connects to its socket, which takes perl.
command -v perl >/dev/null 2>&1 || { printf '%s\n' 'perl is required to confirm that tmux stopped' >&2; exit 1; }
# A socket path must fit sun_path, 104 bytes on macOS. The longest path under
# the directory is the default socket of a program that forgets -S, so a TMPDIR
# that leaves no room for it gives way to /tmp.
root=${TMPDIR:-/tmp}
longest="/libtmux-lua-api.XXXXXX/tmux-$(id -u)/default"
bytes=$(printf '%s%s' "$root" "$longest" | wc -c)
if [ $((bytes)) -gt 100 ]; then
    printf '%s\n' 'TMPDIR is too long for a tmux socket path; using /tmp' >&2
    root=/tmp
fi
directory=$(mktemp -d "$root/libtmux-lua-api.XXXXXX")
socket="$directory/tmux.sock"

# Succeeds only when a connection to the socket is refused or its path is gone.
# Any other outcome leaves a server unproven stopped, including one that a tmux
# client could not talk to.
gone() {
    probed=0
    perl -MSocket -e 'socket(my $s, PF_UNIX, SOCK_STREAM, 0) or exit 0;
        connect($s, sockaddr_un($ARGV[0])) and exit 0;
        exit(($!{ECONNREFUSED} || $!{ENOENT} || $!{ENOTSOCK}) ? 1 : 0)' "$1" || probed=$?
    [ "$probed" -eq 1 ]
}

# Stops the server on a socket, then connects until nothing answers: a server
# leaves a moment after kill-server returns. The client runs in the background
# because it waits for a reply, which a server that never answers does not send.
stop() {
    "$binary" -S "$1" kill-server >/dev/null 2>&1 &
    client=$!
    tries=0
    until gone "$1"; do
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ]; then
            kill "$client" 2>/dev/null || true
            wait "$client" 2>/dev/null || true
            return 1
        fi
        sleep 0.1
    done
    wait "$client" 2>/dev/null || true
}

cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    kept=0
    # A socket anywhere in the directory is a server to stop. Any but the
    # launcher's own is one the program started.
    sockets=$(find "$directory" -type s 2>/dev/null || true)
    while IFS= read -r found; do
        [ -n "$found" ] || continue
        name=${found#"$directory"/}
        if [ "$found" != "$socket" ]; then
            printf 'The program left a tmux socket in the run directory: %s\n' "$name" >&2
            [ "$status" -ne 0 ] || status=1
        fi
        if ! stop "$found"; then
            printf 'tmux still answers at %s\n' "$name" >&2
            kept=1
        fi
    done <<SOCKETS
$sockets
SOCKETS
    if [ "$kept" -ne 0 ]; then
        printf 'Cannot stop tmux; kept %s\n' "${directory##*/}" >&2
        exit 1
    fi
    rm -rf "$directory" || exit 1
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

unset TMUX TMUX_PANE LIBTMUX_SOCKET LIBTMUX_SOCKET_PATH LIBTMUX_SOCKET_NAME
export TMUX_BIN="$binary" TMUX_SOCKET="$socket" TMUX_TMPDIR="$directory" ENV=/dev/null BASH_ENV=/dev/null
"$binary" -S "$socket" -f /dev/null new-session -d -s bootstrap -n bootstrap /bin/cat
"${LUA_BIN:-lua}" "$program"
"$binary" -S "$socket" has-session -t '=bootstrap'
