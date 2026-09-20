"""Verify chained LuaLS completions over the real language-server protocol."""

import json
import os
from pathlib import Path
import selectors
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    started = time.monotonic()
    executable = ROOT / ".cache/tools/luals-3.19.1/bin/lua-language-server"
    process = subprocess.Popen(
        [str(executable), "--logpath=" + str(ROOT / ".cache/luals-editor")],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = bytearray()

    def send(message):
        data = json.dumps(message).encode()
        process.stdin.write(b"Content-Length: " + str(len(data)).encode() + b"\r\n\r\n" + data)
        process.stdin.flush()

    def request(identity, method, parameters):
        send({"jsonrpc": "2.0", "id": identity, "method": method, "params": parameters})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            while b"\r\n\r\n" in buffer:
                header, body = buffer.split(b"\r\n\r\n", 1)
                size = int(next(line.split(b":", 1)[1] for line in header.split(b"\r\n")
                                if line.lower().startswith(b"content-length:")))
                if size > 16 * 1024 * 1024:
                    raise RuntimeError("oversized language-server response")
                if len(body) < size:
                    break
                message = json.loads(body[:size])
                del buffer[:len(header) + 4 + size]
                if message.get("id") == identity and "method" not in message:
                    if "error" in message:
                        raise RuntimeError(message["error"])
                    return message.get("result")
                if "id" in message and "method" in message:
                    send({"jsonrpc": "2.0", "id": message["id"], "result": None})
            if selector.select(min(0.5, max(0, deadline - time.monotonic()))):
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError("language server exited before replying")
                buffer.extend(data)
        raise RuntimeError(f"language-server response deadline: {method}")

    try:
        request(1, "initialize", {"processId": os.getpid(), "rootUri": ROOT.as_uri(), "capabilities": {}})
        send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
        uri = (ROOT / "examples/editor_query.lua").as_uri()
        lines = [
            'local query = require("libtmux.query")',
            'local rows = {{id="%1", active=true}}',
            'local schema = {fields={id={type="string"},active={type="boolean"}}}',
            'local selected = query.select(rows, schema):where({active=true})',
            'selected:',
            'local first = selected:first()',
            'if first then',
            '  first.',
            'end',
            '---@type libtmux.Fields.Pane',
            'local pane = {}',
            'pane.',
            '---@type libtmux.Fields.WindowLink',
            'local link = {}',
            'link.',
        ]
        checks = [(4, 9, {"where", "filter", "first", "one", "count"}),
                  (7, 8, {"id", "active"}),
                  (11, 5, {"id", "active", "current_path", "dead_status"}),
                  (14, 5, {"session_id", "window_id", "index", "active"})]

        def complete(line, required):
            checks.append((len(lines), len(line), required))
            lines.append(line)

        for adapter, entry in (("luv", "run"), ("nvim", "start")):
            lines.extend((f'local {adapter} = require("libtmux.runtime.{adapter}")',
                          f'{"local run_result = " if adapter == "luv" else ""}{adapter}.{entry}(function(runtime)'))
            complete('  runtime:', {"connect", "close", "spawn", "stats"})
            lines.append('  local pending = runtime:connect({binary="/usr/bin/tmux",socket_path="/tmp/owned.sock"})')
            complete('  pending:', {"await", "cancel", "result", "on_complete"})
            lines.append('  local server = assert(pending:await())')
            complete('  server:', {"snapshot", "close", "handle", "command", "group", "batch", "new_session", "query_panes", "explain_panes", "get_option", "list_options", "set_option",
                                    "get_hook", "set_hook", "get_environment", "list_environment",
                                    "set_buffer", "show_buffer", "delete_buffer"})
            lines.append('  local buffer_value = assert(server:show_buffer("clipboard"):await())')
            complete('  buffer_value.', {"name", "bytes", "text"})
            lines.append('  local created = assert(server:new_session({argv={"/bin/cat"}}):await())')
            complete('  created.', {"session", "window", "pane", "window_link", "created"})
            lines.append('  local created_session = created.session')
            complete('  created_session:', {"new_window", "reference", "get_option", "set_hook", "run_hook", "get_environment",
                                           "rename", "kill", "navigate_window", "renumber_windows"})
            lines.append('  local created_window = created.window')
            complete('  created_window:', {"rename", "kill", "resize", "layout", "respawn"})
            lines.append('  local created_link = created.window_link')
            complete('  created_link:', {"select", "link", "move", "swap", "unlink", "reference"})
            lines.append('  local option_record = assert(created_session:get_option("mouse"):await())')
            complete('  option_record.', {"name", "present", "inherited", "value", "entries", "target"})
            lines.append('  local hook_record = assert(created_session:get_hook("session-renamed"):await())')
            complete('  hook_record.', {"present", "inherited", "source", "entries"})
            lines.append('  local environment_record = assert(created_session:get_environment("APP"):await())')
            complete('  environment_record.', {"name", "state", "hidden", "value", "scope", "inherited"})
            lines.append('  local observation = assert(server:observe(created_session):await())')
            complete('  observation:', {"watch_pane", "watch_notifications", "subscribe_format", "coverage", "close"})
            lines.append('  local coverage = assert(observation:coverage())')
            complete('  coverage.', {"session_id", "panes", "generation", "ready"})
            lines.append('  local watch = assert(observation:watch_pane(created.pane):await())')
            complete('  watch:', {"next", "close"})
            lines.append('  local event = assert(watch:next():await())')
            complete('  event.', {"kind", "data", "generation", "sequence"})
            lines.append('  local created_pane = created.pane')
            complete('  created_pane:', {"split", "reference", "capture", "send_text", "send_keys",
                                        "copy_mode", "copy_command", "resize", "kill", "respawn",
                                        "select", "set_title", "swap", "paste_buffer", "move_to"})
            lines.append('  local pane_capture_request = created_pane:capture({history_lines=20})')
            complete('  pane_capture_request:', {"await", "cancel", "result", "on_complete"})
            lines.append('  local pane_capture = assert(pane_capture_request:await())')
            complete('  pane_capture.', {"bytes", "target", "text"})
            lines.append('  local pane_text = assert(pane_capture:text())')
            complete('  pane_text:', {"byte", "sub", "find"})
            lines.append('  local queried = assert(server:query_panes({where={active=true}}):await())')
            complete('  queried.', {"rows", "snapshot", "plan", "complete", "races", "acquisition"})
            lines.extend(('  local match = queried.rows:first()', '  if match then'))
            complete('    match.', {"id", "active", "current_path", "window"})
            lines.append('  end')
            lines.append('  local capture = server:snapshot()')
            complete('  capture:', {"await", "cancel", "result", "on_complete"})
            lines.append('  local snapshot = assert(capture:await())')
            complete('  snapshot.', {"panes", "windows", "window_links", "sessions", "complete"})
            lines.extend(('  local pane = snapshot.panes:where({active=true}):first()',
                          '  if pane then'))
            complete('    pane.', {"id", "active", "current_path", "window"})
            lines.extend(('    local window = pane.window', '    if window then'))
            complete('      window.', {"id", "name", "panes", "window_links"})
            lines.extend(('    end', '    local handle = assert(server:handle(snapshot, pane))'))
            complete('    handle:', {"snapshot", "reference"})
            lines.append('    local refreshed = assert(handle:snapshot():await())')
            complete('    refreshed.', {"id", "title", "window_id", "window"})
            lines.extend(('  end', '  local command = assert(server:command({"display-message", "-p", "ok"}):await())'))
            complete('  command.', {"stdout", "stderr", "exit_code", "signal"})
            lines.append('  return snapshot')
            if adapter == "nvim":
                lines.append('end, function(value, err) end)')
            else:
                lines.extend(('end)', 'if run_result then'))
                complete('  run_result.', {"panes", "sessions", "complete"})
                lines.append('end')
        text = '\n'.join(lines)
        send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
            "textDocument": {"uri": uri, "languageId": "lua", "version": 1, "text": text},
        }})
        # LuaLS waits for workspace readiness on this request, unlike completion.
        request(2, "textDocument/documentSymbol", {"textDocument": {"uri": uri}})
        for identity, (line, character, required) in enumerate(checks, start=3):
            result = request(identity, "textDocument/completion", {
                "textDocument": {"uri": uri}, "position": {"line": line, "character": character},
            })
            items = result.get("items", []) if isinstance(result, dict) else result or []
            labels = {item["label"].split("(", 1)[0] for item in items}
            if not required <= labels:
                raise RuntimeError(f"missing chained completions at line {line + 1}: "
                                   f"{sorted(required - labels)}; got {sorted(labels)}")
        request(len(checks) + 3, "shutdown", None)
        send({"jsonrpc": "2.0", "method": "exit", "params": None})
        process.stdin.close()
        process.wait(timeout=0.8)
        if process.returncode:
            raise RuntimeError(f"language server exited {process.returncode}")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=0.8)
        for stream in (process.stdin, process.stdout):
            stream.close()
        selector.close()
    print(json.dumps({"editor_completion": "PASS", "wall_seconds": round(time.monotonic() - started, 4)}))


if __name__ == "__main__":
    main()
