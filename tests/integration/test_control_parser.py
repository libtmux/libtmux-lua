"""Parse captured control bytes from one explicitly owned tmux server."""

import os
from pathlib import Path
import select
import shutil
import subprocess
import time
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class ControlParserTests(unittest.TestCase):
    def test_live_guards_notifications_and_wait_continuation(self):
        with TmuxFixture() as fixture:
            client = subprocess.Popen(
                [fixture.binary, "-f", "/dev/null", "-S", str(fixture.socket),
                 "-C", "attach-session", "-t", "fixture"],
                env=fixture.env, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            captured = bytearray()

            def command(value):
                client.stdin.write(value + b"\n")
                client.stdin.flush()

            def until(predicate):
                start = len(captured)
                deadline = time.monotonic() + 0.8
                while not predicate(bytes(captured[start:])):
                    ready = select.select([client.stdout], [], [],
                                          max(0, deadline - time.monotonic()))[0]
                    self.assertTrue(ready, bytes(captured))
                    data = os.read(client.stdout.fileno(), 65536)
                    self.assertTrue(data, bytes(captured))
                    captured.extend(data)

            def boundary(marker):
                command(b'display-message -p "' + marker + b'"')
                until(lambda data: marker + b"\n%end " in data)

            try:
                boundary(b"PARSER_READY")
                command(b'display-message -p "%%output %%0 body\\n%%begin 1 2 3'
                        b'\\n%%end 1 2 3\\nBODY_END"')
                until(lambda data: b"BODY_END\n%end " in data)
                fixture.run("respawn-pane", "-k", "-t", "fixture:0.0",
                            r"stty raw -echo; printf 'PLAIN\000\001\012\015\134\377DONE'; exec /bin/cat")
                until(lambda data: b"%output " in data and b"DONE\n" in data)
                command(b"refresh-client -f pause-after=5")
                until(lambda data: b"\n%end " in data)
                fixture.run("respawn-pane", "-k", "-t", "fixture:0.0",
                            r"stty raw -echo; printf 'EXTENDED\000\001\012\015\134\377DONE'; exec /bin/cat")
                until(lambda data: b"%extended-output " in data and b"DONE\n" in data)
                # An explicit pane target keeps job output routing stable across tmux versions.
                command(b'run-shell -t fixture:0.0 "printf PANE_ONLY"')
                boundary(b"WAIT_DONE")
                command(b"detach-client")
                deadline = time.monotonic() + 0.8
                while True:
                    self.assertTrue(select.select([client.stdout], [], [],
                                                  max(0, deadline - time.monotonic()))[0])
                    data = os.read(client.stdout.fileno(), 65536)
                    if not data:
                        break
                    captured.extend(data)
                self.assertEqual(client.wait(timeout=0.8), 0)
                command_line = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                                "tests/integration/control_parser.lua"]
                self.assertIsNotNone(command_line[0], "missing Lua executable")
                result = subprocess.run(command_line, input=captured, cwd=ROOT,
                                        env=fixture.env, capture_output=True, timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(b"control parser capture passed", result.stdout)
            finally:
                if client.poll() is None:
                    client.kill()
                client.communicate(timeout=0.8)
