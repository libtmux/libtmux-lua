"""Own one real tmux server for a test; never use the default socket."""

import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import time


_DEADLINE = 0.8


class _ProcessExit:
    def __init__(self, pid):
        self.pid = pid
        self.fd = None
        self.queue = None
        try:
            if hasattr(os, "pidfd_open"):
                self.fd = os.pidfd_open(pid)
            elif hasattr(select, "kqueue"):
                self.queue = select.kqueue()
                self.queue.control(
                    [select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                   flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                   fflags=select.KQ_NOTE_EXIT)], 0, 0,
                )
                self.fd = self.queue.fileno()
            else:
                raise RuntimeError("tmux fixture needs Linux pidfd or BSD kqueue")
        except ProcessLookupError:
            self.close()

    def close(self):
        if self.queue is not None:
            self.queue.close()
            self.queue = None
        elif self.fd is not None:
            os.close(self.fd)
        self.fd = None

    def terminate(self):
        if self.fd is None or select.select([self.fd], [], [], 0)[0]:
            return
        if self.queue is not None or not hasattr(signal, "pidfd_send_signal"):
            raise RuntimeError("forced process cleanup requires Linux pidfd signals")
        signal.pidfd_send_signal(self.fd, signal.SIGKILL)


class TmuxFixture:
    """Context manager with an explicit socket and sanitized child environment.

    ``run`` waits for a command; ``spawn`` owns a long-lived tmux client.
    The enclosing runner translates cancellation signals into exceptions so
    this context can close before that runner exits.
    """

    def __init__(self, binary=None):
        self.binary = binary or os.environ.get("TMUX_BIN", "tmux")
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("TMUX", "TMUX_PANE")}
        self.path = None
        self.socket = None
        self.server_pid = None
        self.pane_pids = []
        self._clients = []
        self._exits = {}
        self._closed = False

    def __enter__(self):
        if self.path is not None:
            raise RuntimeError("tmux fixture cannot be entered twice")
        # /tmp keeps Unix socket names short even with a long checkout/TMPDIR.
        self.path = Path(tempfile.mkdtemp(prefix="libtmux-lua-", dir="/tmp"))
        self.socket = self.path / "tmux.sock"
        try:
            result = self.run(
                "new-session", "-d", "-s", "fixture", "-P", "-F",
                "#{pid} #{pane_pid}", "exec /bin/cat",
            )
            self._record_panes(result.stdout)
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()

    def spawn(self, *arguments):
        if self.socket is None or self._closed:
            raise RuntimeError("tmux fixture is not active")
        client = subprocess.Popen(
            [self.binary, "-f", "/dev/null", "-S", str(self.socket), *arguments],
            env=self.env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self._clients.append(client)
        return client

    def run(self, *arguments, check=True):
        client = self.spawn(*arguments)
        try:
            stdout, stderr = client.communicate(timeout=_DEADLINE)
        except BaseException:
            client.kill()
            client.communicate(timeout=_DEADLINE)
            raise
        result = subprocess.CompletedProcess(
            client.args, client.returncode, stdout, stderr,
        )
        if check:
            result.check_returncode()
        return result

    def _record_panes(self, output):
        for line in output.splitlines():
            server_pid, pane_pid = map(int, line.split())
            self.server_pid = server_pid
            if pane_pid not in self.pane_pids:
                self.pane_pids.append(pane_pid)
            for pid in (server_pid, pane_pid):
                if pid not in self._exits:
                    self._exits[pid] = _ProcessExit(pid)

    def close(self):
        if self._closed or self.path is None:
            return
        errors = []

        def attempt(operation, action):
            try:
                return action()
            except BaseException as error:
                errors.append((operation, error))

        if self.socket.exists():
            panes = attempt("list-panes", lambda: self.run(
                "list-panes", "-a", "-F", "#{pid} #{pane_pid}", check=False,
            ))
            if panes is not None and panes.returncode == 0:
                attempt("observe panes", lambda: self._record_panes(panes.stdout))
            released = attempt("kill-server", lambda: self.run(
                "kill-server", check=False,
            ))
            if released is None or released.returncode != 0:
                for watch in self._exits.values():
                    attempt(f"terminate process {watch.pid}", watch.terminate)
        for client in self._clients:
            attempt(f"close client {client.pid}", lambda: self._finish_client(client))
        attempt("wait for owned process exit", self._wait_exits)
        for watch in self._exits.values():
            attempt(f"close process observer {watch.pid}", watch.close)
        attempt("remove fixture directory", lambda: shutil.rmtree(self.path))
        self._closed = True
        for _, error in errors:
            if not isinstance(error, Exception):
                raise error
        if errors:
            message = "; ".join(f"{operation}: {error}" for operation, error in errors)
            raise RuntimeError(f"tmux fixture cleanup failed: {message}") from errors[0][1]

    @staticmethod
    def _finish_client(client):
        try:
            try:
                client.communicate(timeout=_DEADLINE)
            except BaseException:
                client.kill()
                client.communicate(timeout=_DEADLINE)
                raise
        finally:
            client.stdout.close()
            client.stderr.close()

    def _wait_exits(self):
        remaining = {watch.fd: watch.pid for watch in self._exits.values()
                     if watch.fd is not None}
        deadline = time.monotonic() + _DEADLINE
        while remaining:
            ready, _, _ = select.select(
                list(remaining), [], [], max(0, deadline - time.monotonic()),
            )
            if not ready:
                raise RuntimeError(
                    f"owned tmux processes did not exit: {list(remaining.values())}"
                )
            for fd in ready:
                del remaining[fd]
