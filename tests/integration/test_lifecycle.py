"""Run the exact ordinary example with captured defaults in owned tmux fixtures."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = ROOT / "examples/ordinary.lua"

# The wrapper changes the failure trigger, never the imported example file.
WRAPPER = r'''
local mode = os.getenv("LIBTMUX_EXAMPLE_MODE")
local adapter = require("libtmux.runtime.luv")
local run = adapter.run
local emit = print
adapter.run = function(body, options)
    local value, failure = run(function(runtime)
        print = function(...)
            emit(...)
            if mode == "cancel" then
                runtime:close("injected cancellation")
            elseif mode == "body" or mode == "cleanup" then
                error("injected body failure", 0)
            end
        end
        if mode == "cleanup" then
            local uv = require("luv")
            local spawn = uv.spawn
            uv.spawn = function(binary, spec, callback)
                for _, argument in ipairs(spec.args) do
                    if argument == "kill-session" then
                        return nil, "injected teardown failure"
                    end
                end
                return spawn(binary, spec, callback)
            end
        end
        return body(runtime)
    end, options)
    if failure then error(failure, 0) end
    return value
end
local ok, err = pcall(dofile, os.getenv("LIBTMUX_EXAMPLE_FILE"))
if not ok then
    io.stderr:write(tostring(err), "\n")
    if type(err) == "table" and err.cause then
        io.stderr:write("body: ", tostring(err.cause), "\n")
    end
    if type(err) == "table" and err.errors then
        for _, failure in ipairs(err.errors) do
            io.stderr:write("cleanup: ", tostring(failure), "\n")
        end
    end
    os.exit(1)
end
'''


class LifecycleTests(unittest.TestCase):
    def child_env(self, fixture, *, named=False):
        env = {key: value for key, value in fixture.env.items()
               if key not in ("LIBTMUX_SOCKET_PATH", "LIBTMUX_SOCKET_NAME", "TMUX_TMPDIR")}
        binary = shutil.which(fixture.binary)
        env["PATH"] = os.pathsep.join((str(Path(binary).parent), env.get("PATH", "")))
        if named:
            env.update(LIBTMUX_SOCKET_NAME=fixture.socket.name, TMUX_TMPDIR=str(fixture.path))
        else:
            env["LIBTMUX_SOCKET_PATH"] = str(fixture.socket)
        env.update(TMUX="invalid but lower precedence", TMUX_PANE="%999")
        return env

    def run_example(self, fixture, *, named=False, mode=None):
        env = self.child_env(fixture, named=named)
        lua = env.get("LIBTMUX_TEST_LUA") or shutil.which("lua")
        command = [lua, str(EXAMPLE)]
        if mode:
            env.update(LIBTMUX_EXAMPLE_MODE=mode, LIBTMUX_EXAMPLE_FILE=str(EXAMPLE))
            command = [lua, "-e", WRAPPER]
        return subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=0.8)

    def test_exact_example_path_and_named_defaults(self):
        before = EXAMPLE.read_bytes()
        for named in (False, True):
            with self.subTest(named=named):
                with TmuxFixture(socket_name="ordinary" if named else None) as fixture:
                    result = self.run_example(fixture, named=named)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual(result.stdout, b"session: ordinary-example\n")
                    self.assertEqual(fixture.run("list-sessions", "-F", "#{session_name}").stdout,
                                     "fixture\n")
                    self.assertEqual(list(fixture.path.rglob("libtmux-lua-pin-*")), [])
                self.assertFalse(fixture.path.exists())
        self.assertEqual(EXAMPLE.read_bytes(), before)

    def test_body_error_and_cancellation_remove_created_session(self):
        for mode in ("body", "cancel"):
            with self.subTest(mode=mode):
                with TmuxFixture() as fixture:
                    result = self.run_example(fixture, mode=mode)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(b"session: ordinary-example", result.stdout)
                    self.assertIn(b"injected", result.stderr)
                    self.assertEqual(fixture.run("list-sessions", "-F", "#{session_name}").stdout,
                                     "fixture\n")
                    self.assertEqual(list(fixture.path.rglob("libtmux-lua-pin-*")), [])
                self.assertFalse(fixture.path.exists())

    def test_cleanup_failure_is_visible_and_harness_reaps_remaining_session(self):
        with TmuxFixture() as fixture:
            result = self.run_example(fixture, mode="cleanup")
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"deferred cleanup failed", result.stderr)
            self.assertIn(b"body: injected body failure", result.stderr)
            self.assertIn(b"cleanup:", result.stderr)
            self.assertIn("ordinary-example", fixture.run("list-sessions", "-F", "#{session_name}").stdout)
        self.assertFalse(fixture.path.exists())

    def test_captured_clients_and_deferred_cleanup_in_luv_and_neovim(self):
        for host in ("luv", "nvim"):
            for mode in ("normal", "body", "cancel"):
                with self.subTest(host=host, mode=mode), TmuxFixture(socket_name="captured") as fixture:
                    env = self.child_env(fixture, named=True)
                    env.update(LIBTMUX_LIFECYCLE_MODE=mode, LIBTMUX_CLIENT_MARKER="before")
                    if host == "luv":
                        command = [env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                                   "tests/integration/lifecycle.lua"]
                    else:
                        env.pop("LUA_CPATH", None)
                        command = [env.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                                   "--headless", "-u", "NONE", "-i", "NONE", "-c",
                                   "lua dofile('tests/integration/lifecycle.lua')"]
                    result = subprocess.run(command, cwd=ROOT, env=env,
                                            capture_output=True, timeout=0.8)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertIn(f"captured lifecycle {mode} PASS".encode(), result.stdout)
                    self.assertEqual(fixture.run("list-sessions", "-F", "#{session_name}").stdout,
                                     "fixture\n")
                    self.assertEqual(list(fixture.path.rglob("libtmux-lua-pin-*")), [])

    def test_named_root_checks_preserve_filesystem_semantics(self):
        with TmuxFixture(socket_name="ordinary") as fixture:
            env = self.child_env(fixture, named=True)
            lua = env.get("LIBTMUX_TEST_LUA") or shutil.which("lua")
            probe = r'''
local adapter = require("libtmux.runtime.luv")
local value, err = adapter.run(function(runtime)
    return runtime:connect():await()
end)
if err then io.stderr:write(err.code, ": ", tostring(err), "\n"); os.exit(1) end
assert(value)
'''
            directory = fixture.socket.parent
            removed = fixture.path / "gone"
            removed.mkdir()
            removed.rmdir()
            for root in (str(fixture.path / "missing" / ".."), str(fixture.path / "gone")):
                with self.subTest(root=root):
                    env["TMUX_TMPDIR"] = root
                    result = subprocess.run([lua, "-e", probe], cwd=ROOT, env=env,
                                            capture_output=True, timeout=0.8)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(b"invalid_endpoint", result.stderr)
            branch = fixture.path / "branch"
            branch.mkdir()
            (branch / "inner").mkdir()
            (fixture.path / "link").symlink_to(branch / "inner", target_is_directory=True)
            directory.rename(branch / directory.name)
            fixture.socket = branch / directory.name / fixture.socket.name
            env["TMUX_TMPDIR"] = str(fixture.path / "link") + "/.."
            result = subprocess.run([lua, "-e", probe], cwd=ROOT, env=env,
                                    capture_output=True, timeout=0.8)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertFalse(directory.exists(), "root was normalized as a string")

    def test_named_directory_permissions_and_fresh_root_without_daemon(self):
        with TmuxFixture(socket_name="ordinary") as fixture:
            env = self.child_env(fixture, named=True)
            for mode, succeeds in ((0o700, True), (0o770, True), (0o701, False)):
                fixture.socket.parent.chmod(mode)
                result = self.run_example(fixture, named=True)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr.decode())
            fixture.socket.parent.chmod(0o700)
            with tempfile.TemporaryDirectory(prefix="libtmux-lua-fresh-", dir="/tmp") as fresh:
                env["TMUX_TMPDIR"] = fresh
                lua = env.get("LIBTMUX_TEST_LUA") or shutil.which("lua")
                result = subprocess.run([lua, str(EXAMPLE)], cwd=ROOT, env=env,
                                        capture_output=True, timeout=0.8)
                self.assertNotEqual(result.returncode, 0)
                directory = Path(fresh) / f"tmux-{os.getuid()}"
                self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
                self.assertEqual(list(directory.iterdir()), [])
                self.assertIn(b"not an accessible socket", result.stderr)
