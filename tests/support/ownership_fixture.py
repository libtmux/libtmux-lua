"""Run lifecycle programs inside a Linux fixture with observed process retirement.

The example is read from disk unchanged. Configuration and failure injection are
external; cleanup addresses accepted child identities, never the default socket.
"""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
OBSERVER = Path(__file__).with_name('ownership_observer.lua')
sys.path.insert(0, str(ROOT / 'scripts'))
from runtime_config import identify, clean_environment


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('label')
    parser.add_argument('source')
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--lua', default=os.environ.get('LIBTMUX_TEST_LUA') or shutil.which('lua'))
    parser.add_argument('--tmux', default=os.environ.get('TMUX_BIN') or shutil.which('tmux'))
    parser.add_argument('--named', action='store_true')
    parser.add_argument('--module-root', type=Path, default=ROOT)
    parser.add_argument('--worker-mode', choices=('body-fail', 'timeout', 'crash'))
    parser.add_argument('--nvim')
    parser.add_argument('--timeout', type=float, default=10)
    args = parser.parse_args()
    output = args.evidence / args.label
    output.mkdir(parents=True, exist_ok=False)
    assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
    runtime = identify(args.lua)
    env = {key: value for key, value in clean_environment().items() if key not in ('TMUX', 'TMUX_PANE', 'LIBTMUX_SOCKET_NAME', 'LIBTMUX_SOCKET_PATH', 'TMUX_TMPDIR')}
    rocks = ROOT / '.cache/rocks' / runtime.cache_label
    env['LUA_PATH'] = f'{args.module_root}/lua/?.lua;{args.module_root}/lua/?/init.lua;{ROOT}/?.lua;{rocks}/share/lua/{runtime.version}/?.lua;{rocks}/share/lua/{runtime.version}/?/init.lua'
    env['LUA_CPATH'] = f'{rocks}/lib/lua/{runtime.version}/?.so'
    env['PATH'] = str(Path(args.tmux).parent) + ':' + env.get('PATH', '')
    env['SHELL'] = '/bin/sh'
    root = Path(tempfile.mkdtemp(prefix='libtmux-lua-', dir='/dev/shm'))
    socket = root / 'socket'
    if args.named:
        directory = root / f'tmux-{os.getuid()}'
        directory.mkdir(mode=0o700)
        socket = directory / 'named'
        env.update(LIBTMUX_SOCKET_NAME='named', TMUX_TMPDIR=str(root))
    else:
        env['LIBTMUX_SOCKET_PATH'] = str(socket)
    env.update(LIBTMUX_TEST_ROOT=str(root), LIBTMUX_TEST_BINARY=args.tmux, EXAMPLE_UNUSED_SOCKET=str(root / 'documentation-server'))
    observer = root / 'observer'
    observer.mkdir()
    env['LIBTMUX_OBSERVER'] = str(observer)
    env['LUA_INIT'] = '@' + str(OBSERVER)
    if args.worker_mode:
        env['LIBTMUX_WORKER_MODE'] = args.worker_mode
    events, watches, children = [], {}, []
    def accept(pid, role):
        if pid in watches:
            return
        try:
            fd = os.pidfd_open(pid)
            stat = Path(f'/proc/{pid}/stat').read_text()
            start = stat.rsplit(') ', 1)[1].split()[19]
            watches[pid] = fd
            events.append({'event': 'accepted', 'pid': pid, 'start': start, 'role': role, 'time': time.monotonic()})
        except ProcessLookupError:
            events.append({'event': 'already_exited', 'pid': pid, 'role': role})
    def collect(pid):
        path = Path(f'/proc/{pid}/task/{pid}/children')
        try:
            pids = [int(item) for item in path.read_text().split()]
        except FileNotFoundError:
            return
        for child in pids:
            accept(child, 'owned descendant')
            collect(child)
    observer_stop = threading.Event()
    def observe():
        handled = set()
        while not observer_stop.is_set():
            for notice in observer.glob('spawn-*'):
                if notice.name in handled:
                    continue
                try:
                    pid = int(notice.read_text())
                    cmdline = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                    stat = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
                    assert int(stat[1]) == worker.pid, (pid, stat[1], worker.pid)
                    assert b'-D' in cmdline and any(item.startswith(str(root).encode()+b'/') for item in cmdline), cmdline
                    accept(pid, 'library foreground daemon')
                    events.append({'event': 'spawn_route', 'pid': pid, 'argv': [item.decode(errors='replace') for item in cmdline if item]})
                    notice.with_name('ack-' + notice.name).write_text('accepted')
                    handled.add(notice.name)
                except (FileNotFoundError, ValueError):
                    pass
                except BaseException as error:
                    errors.append('observer: ' + repr(error))
                    notice.with_name('ack-' + notice.name).write_text('rejected')
                    handled.add(notice.name)
            observer_stop.wait(0.001)
    def cmd(*words):
        return subprocess.run([args.tmux, '-N', '-S', str(socket), *words], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1)
    host_environment = dict(os.environ)
    report = {'label': args.label, 'source': str(Path(args.source).resolve()), 'source_sha256': hashlib.sha256(Path(args.source).read_bytes()).hexdigest(), 'lua': runtime.executable, 'nvim': args.nvim, 'tmux': args.tmux, 'root': str(root), 'named': args.named, 'module_root': str(args.module_root), 'worker_mode': args.worker_mode, 'events': events}
    report['source_module_hashes'] = {str(path.relative_to(args.module_root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted((args.module_root / 'lua').rglob('*.lua'))}
    daemon = worker = None
    errors = []
    began = time.monotonic()
    try:
        daemon = subprocess.Popen([args.tmux, '-D', '-f', '/dev/null', '-S', str(socket)], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        accept(daemon.pid, 'foreground daemon')
        limit = time.monotonic() + 0.8
        while True:
            if daemon.poll() is not None or time.monotonic() >= limit:
                raise RuntimeError('foreground daemon did not confirm its owned endpoint')
            if socket.exists():
                probe = cmd('display-message', '-p', '#{pid}')
                if probe.returncode == 0 and probe.stdout == f'{daemon.pid}\n'.encode():
                    break
            select.select([watches[daemon.pid]], [], [], 0.005)
        result = cmd('new-session', '-d', '-s', 'fixture', '-P', '-F', '#{pane_pid}', 'exec /bin/cat')
        assert result.returncode == 0, result.stderr
        accept(int(result.stdout), 'fixture pane')
        with (output / 'stdout.log').open('wb') as stdout, (output / 'stderr.log').open('wb') as stderr:
            command = [runtime.executable, args.source]
            if args.nvim:
                command = [args.nvim, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'luafile ' + str(OBSERVER), '-c', 'luafile ' + args.source]
            report['command'] = command
            worker = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
            accept(worker.pid, 'Lua worker')
            observer_thread = threading.Thread(target=observe)
            observer_thread.start()
            try:
                report['returncode'] = worker.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                report['timed_out'] = True
                collect(worker.pid)
                signal.pidfd_send_signal(watches[worker.pid], signal.SIGKILL)
                worker.wait(timeout=1)
                report['returncode'] = worker.returncode
        report['remaining_sessions'] = cmd('list-sessions', '-F', '#{session_name}').stdout.decode(errors='replace')
    except BaseException as error:
        errors.append(repr(error))
    finally:
        observer_stop.set()
        if 'observer_thread' in locals():
            observer_thread.join(timeout=1)
        collect(os.getpid())
        for pid, fd in list(watches.items()):
            if not select.select([fd], [], [], 0)[0]:
                signal.pidfd_send_signal(fd, signal.SIGTERM)
        deadline = time.monotonic() + 1
        pending = set(watches.values())
        while pending and time.monotonic() < deadline:
            ready = select.select(list(pending), [], [], 0.05)[0]
            pending.difference_update(ready)
        for fd in pending:
            signal.pidfd_send_signal(fd, signal.SIGKILL)
        if pending:
            deadline = time.monotonic() + 1
            while pending and time.monotonic() < deadline:
                pending.difference_update(select.select(list(pending), [], [], 0.05)[0])
        for pid, fd in watches.items():
            exited = bool(select.select([fd], [], [], 0)[0])
            events.append({'event': 'observed_exit', 'pid': pid, 'exited': exited, 'time': time.monotonic()})
            os.close(fd)
        if daemon is not None:
            daemon.wait(timeout=1)
        if worker is not None:
            worker.wait(timeout=1)
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
                if not pid:
                    break
            except ChildProcessError:
                break
        if not pending:
            shutil.rmtree(root)
            events.append({'event': 'removed_root', 'time': time.monotonic()})
        else:
            errors.append('owned process exit unproved; retaining root')
        report.update(errors=errors, elapsed_seconds=time.monotonic()-began, root_removed=not root.exists(), parent_environment_unchanged=dict(os.environ) == host_environment)
        (output / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report.get(key) for key in ('label', 'returncode', 'root_removed', 'elapsed_seconds', 'errors')}))
    expected = report.get('returncode') == 0
    if args.worker_mode == 'body-fail':
        expected = report.get('returncode') == 1 and report.get('remaining_sessions') == 'fixture\n'
    elif args.worker_mode == 'timeout':
        expected = report.get('timed_out') is True and report.get('returncode') == -signal.SIGKILL
    elif args.worker_mode == 'crash':
        expected = report.get('returncode') == -signal.SIGKILL and not report.get('timed_out')
    return int(bool(errors) or not expected or not report['parent_environment_unchanged'])


if __name__ == '__main__':
    raise SystemExit(main())
