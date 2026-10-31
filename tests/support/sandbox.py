"""A private tmux world for the processes that run the tests.

A tmux command that names no socket goes to the server an inherited TMUX
names, and otherwise to the default socket under TMUX_TMPDIR. Every test here
passes -S, so none should reach either. Entering the sandbox removes what
selects a server and points TMUX_TMPDIR at a directory this run owns: a test
that forgets -S finds nothing, and the run fails when it finds a socket anywhere
in the sandbox.

Findings name variables and never print their values: a TMUX value names a
server, and an environment can hold secrets.
"""

import atexit
from collections import namedtuple
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time

MARKER = "LIBTMUX_TEST_SANDBOX"
PREFIX = "libtmux-lua-sb-"
# A socket path must fit sun_path, 104 bytes on macOS. This leaves room for
# /tmux-<uid>/<name> after the directory.
MAX_BYTES = 60
# tempfile.mkdtemp appends eight characters to the prefix.
NAME_BYTES = len(PREFIX) + 8
# How long kill-server may take before a socket that still accepts a
# connection counts as a server that was not stopped.
STOP_SECONDS = 3

# leaked: every socket found under the sandbox, relative to it.
# answering: those that still accepted a connection after the stop.
Release = namedtuple("Release", "leaked answering")


class Refused(Exception):
    """The environment cannot be made into a sandbox, or is not one."""


def ambient(name):
    """Whether a variable selects a server or a pane for a command naming none."""
    return name in ("TMUX", "TMUX_PANE") or name.startswith("LIBTMUX_SOCKET")


def _directory_findings(env):
    directory = env.get("TMUX_TMPDIR")
    if not directory:
        return ["TMUX_TMPDIR is unset"]
    if not directory.startswith("/"):
        return ["TMUX_TMPDIR is not an absolute path"]
    if len(os.fsencode(directory)) > MAX_BYTES:
        return [f"TMUX_TMPDIR is longer than {MAX_BYTES} bytes"]
    if env.get(MARKER) != directory or not os.path.basename(directory.rstrip("/")).startswith(PREFIX):
        return ["TMUX_TMPDIR is not the sandbox directory of this run"]
    return []


def violations(env):
    """What in env lets a test reach a server it does not own, from the strings alone."""
    return [f"{name} is set" for name in sorted(env) if ambient(name)] + _directory_findings(env)


def _directory_problem(directory):
    try:
        status = os.stat(directory)
    except OSError:
        return "the sandbox directory is missing"
    if not stat.S_ISDIR(status.st_mode) or status.st_uid != os.geteuid():
        return "the sandbox directory belongs to another user"
    return None


def check(env=None):
    """Raise Refused unless env is a sandbox that exists and is this user's."""
    env = os.environ if env is None else env
    found = violations(env)
    if not found:
        problem = _directory_problem(env["TMUX_TMPDIR"])
        found = [problem] if problem else []
    if found:
        raise Refused("; ".join(found))


def scrub(env):
    """A copy of env without the variables that select a server or a pane."""
    return {name: value for name, value in env.items() if not ambient(name)}


def default_socket(env, uid=None):
    """The socket tmux connects to when TMUX is unset and no -S or -L is given.

    tmux resolves the directory through realpath, so a symlinked TMUX_TMPDIR
    (macOS /tmp) names the target.
    """
    uid = os.getuid() if uid is None else uid
    base = env.get("TMUX_TMPDIR") or "/tmp"
    return os.path.join(os.path.realpath(base), f"tmux-{uid}", "default")


def _create(roots):
    for root in roots:
        if (len(os.fsencode(root)) + 1 + NAME_BYTES <= MAX_BYTES
                and os.path.isdir(root) and os.access(root, os.W_OK | os.X_OK)):
            return tempfile.mkdtemp(prefix=PREFIX, dir=root)
    raise Refused("no temporary directory is short enough for a tmux socket path; set TMPDIR to a shorter one")


def _remove(directory):
    if os.path.basename(directory.rstrip("/")).startswith(PREFIX):
        shutil.rmtree(directory, ignore_errors=True)


def prepare(env, roots=None):
    """Turn env into a sandbox in place and return (directory, created).

    A process whose env already names a live sandbox joins it instead of
    making another, so the process that made it is the one that checks it.
    """
    roots = [tempfile.gettempdir(), "/tmp"] if roots is None else roots
    directory = env.get("TMUX_TMPDIR")
    joined = not _directory_findings(env) and _directory_problem(directory) is None
    for name in [name for name in env if ambient(name)]:
        del env[name]
    if not joined:
        directory = _create(roots)
    env["TMUX_TMPDIR"] = env[MARKER] = directory
    try:
        check(env)
    except Refused:
        if not joined:
            _remove(directory)
        raise
    return directory, not joined


def leaks(directory):
    """Every socket under the directory, at any depth, relative to it.

    Each test here puts its own server on a socket in a directory of its own,
    so a socket anywhere in the sandbox, whether tmux chose it or a test named
    it with -S, is a server no test stopped. A link is not followed: its
    target is a socket in some other tree.
    """
    found = []
    for folder, folders, files in os.walk(directory):
        for name in folders + files:
            path = os.path.join(folder, name)
            try:
                if stat.S_ISSOCK(os.lstat(path).st_mode):
                    found.append(os.path.relpath(path, directory))
            except OSError:
                pass
    return sorted(found)


def _answering(target):
    """Whether a connection to the socket succeeds.

    Only a refusal or a missing path shows that no server is behind it. Any
    other outcome, a full backlog or a path too long to connect to, leaves the
    server unproven gone.
    """
    client = socket.socket(socket.AF_UNIX)
    try:
        client.setblocking(False)
        client.connect(os.fsdecode(target))
    except (FileNotFoundError, ConnectionRefusedError, NotADirectoryError):
        return False
    except (OSError, ValueError):
        return True
    finally:
        client.close()
    return True


def _stop(target, tmux, wait):
    """Run kill-server on a socket and return whether nothing answers there.

    A server leaves a moment after kill-server returns, so the connection is
    retried until it fails or the wait runs out.
    """
    try:
        subprocess.run(
            [tmux, "-N", "-S", str(target), "kill-server"],
            env=scrub(os.environ), stdin=subprocess.DEVNULL, capture_output=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        pass
    deadline = time.monotonic() + wait
    while _answering(target):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)
    return True


def release(directory, tmux=None, wait=None):
    """Stop the server behind each socket and remove the directory.

    The directory stays while a server still answers. Returns a Release that
    names what was found.
    """
    tmux = tmux or os.environ.get("TMUX_BIN", "tmux")
    wait = STOP_SECONDS if wait is None else wait
    found = leaks(directory)
    answering = [path for path in found if not _stop(Path(directory) / path, tmux, wait)]
    if not answering:
        _remove(directory)
    return Release(found, answering)


def describe(released, directory):
    """The failure for a release that found sockets: names, never values."""
    text = "libtmux-lua tests left sockets in the sandbox: " + ", ".join(released.leaked)
    if released.answering:
        text += (f"; a server still answers at {', '.join(released.answering)}, "
                 f"so {os.path.basename(directory.rstrip('/'))} was kept")
    return text


def _finish(directory, owner):
    if os.getpid() != owner:
        return
    released = release(directory)
    if released.leaked:
        print(describe(released, directory), file=sys.stderr, flush=True)
        sys.stdout.flush()
        # An exit status set inside an atexit handler is ignored; this is the
        # only way to fail the run from here.
        os._exit(1)


def enter(env=None):
    """Make this process's environment the sandbox and return its directory.

    The process that makes the sandbox checks it when it exits. Raises Refused
    when no sandbox can be made.
    """
    env = os.environ if env is None else env
    directory, created = prepare(env)
    if created:
        atexit.register(_finish, directory, os.getpid())
    return directory
