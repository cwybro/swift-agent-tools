#!/usr/bin/env python3
"""swiftdbg: an MCP server that lets an agent drive LLDB (via lldb-dap), plus a
local web viewer that shows the same live session to a human.

    MCP over stdio  ->  Session  ->  lldb-dap  ->  your Swift process
    HTTP :7311      ->  Session (same one)

Stdlib only; Python 3.9+.
"""
import json
import os
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dap import DAPError, Session, log  # noqa: E402

SESSION = Session()
VIEWER_PORT = int(os.environ.get("SWIFTDBG_PORT", "7311"))
HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------- tools

def _int_keys(d):
    return {int(k): v for k, v in (d or {}).items()}

TOOLS = [
    {
        "name": "debug_set_breakpoints",
        "description": "Replace all breakpoints in one source file. Works before or during a session. "
                       "Pass an empty list to clear the file. Optional per-line LLDB conditions, e.g. {\"17\": \"total > 10\"}.",
        "inputSchema": {"type": "object", "required": ["file", "lines"], "properties": {
            "file": {"type": "string", "description": "Absolute path to the .swift file"},
            "lines": {"type": "array", "items": {"type": "integer"}},
            "conditions": {"type": "object", "additionalProperties": {"type": "string"}}}},
        "run": lambda a: SESSION.set_breakpoints(a["file"], a["lines"], _int_keys(a.get("conditions"))),
    },
    {
        "name": "debug_launch",
        "description": "Launch an executable (a debug build: `swift build`, xcodebuild for macOS, or `bazel build -c dbg`) under LLDB. "
                       "Blocks until the first breakpoint hit, exit, or timeout, and returns stack, locals and source around the stop. "
                       "For Bazel builds pass init_commands like [\"settings set target.source-map . /abs/workspace\"].",
        "inputSchema": {"type": "object", "required": ["program"], "properties": {
            "program": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}},
            "cwd": {"type": "string"}, "stop_on_entry": {"type": "boolean"},
            "init_commands": {"type": "array", "items": {"type": "string"}},
            "timeout": {"type": "number", "description": "seconds to wait for a stop (default 30)"}}},
        "run": lambda a: SESSION.launch(a["program"], a.get("args"), a.get("cwd"), a.get("stop_on_entry", False),
                                        a.get("init_commands"), a.get("timeout", 30)),
    },
    {
        "name": "debug_attach",
        "description": "Attach to a running process by pid, or by executable path with wait_for=true to catch it at launch "
                       "(e.g. an iOS Simulator app started with `xcrun simctl launch --wait-for-debugger`).",
        "inputSchema": {"type": "object", "properties": {
            "pid": {"type": "integer"}, "program": {"type": "string"}, "wait_for": {"type": "boolean"},
            "init_commands": {"type": "array", "items": {"type": "string"}}}},
        "run": lambda a: SESSION.attach(a.get("pid"), a.get("program"), a.get("wait_for", False), a.get("init_commands")),
    },
    {
        "name": "debug_continue",
        "description": "Resume until the next breakpoint, exit, or timeout. Returns the new stop snapshot.",
        "inputSchema": {"type": "object", "properties": {"timeout": {"type": "number"}}},
        "run": lambda a: SESSION.resume("continue", a.get("timeout", 30)),
    },
    {
        "name": "debug_step",
        "description": "Step the stopped thread: kind = over | in | out.",
        "inputSchema": {"type": "object", "required": ["kind"], "properties": {
            "kind": {"type": "string", "enum": ["over", "in", "out"]}}},
        "run": lambda a: SESSION.resume(a["kind"], 15),
    },
    {
        "name": "debug_wait",
        "description": "If the process is still running (a previous call timed out), wait for it to stop or exit.",
        "inputSchema": {"type": "object", "properties": {"timeout": {"type": "number"}}},
        "run": lambda a: SESSION.wait(a.get("timeout", 30)),
    },
    {
        "name": "debug_pause",
        "description": "Interrupt a running process and return where it is.",
        "inputSchema": {"type": "object", "properties": {}},
        "run": lambda a: SESSION.pause(),
    },
    {
        "name": "debug_select_frame",
        "description": "Switch to another stack frame (index from the snapshot's frames list) and return its locals and source.",
        "inputSchema": {"type": "object", "required": ["index"], "properties": {"index": {"type": "integer"}}},
        "run": lambda a: SESSION.select_frame(a["index"]),
    },
    {
        "name": "debug_variables",
        "description": "Expand a structured value using a non-zero `ref` from locals or an evaluate result.",
        "inputSchema": {"type": "object", "required": ["ref"], "properties": {"ref": {"type": "integer"}}},
        "run": lambda a: {"variables": SESSION.variables(a["ref"])},
    },
    {
        "name": "debug_evaluate",
        "description": "Evaluate in the selected frame. Default: a variable path or Swift expression (prefer simple paths "
                       "like `cart.items[0].price`, they work without compiling). With lldb_command=true, run a raw LLDB "
                       "command instead, e.g. `v -T item`, `po self`, `bt all`, `image lookup -n total`.",
        "inputSchema": {"type": "object", "required": ["expression"], "properties": {
            "expression": {"type": "string"}, "lldb_command": {"type": "boolean"}}},
        "run": lambda a: SESSION.evaluate(a["expression"], a.get("lldb_command", False)),
    },
    {
        "name": "debug_status",
        "description": "Current status, breakpoints, last stop snapshot, program output, and the shared activity log "
                       "(which also shows actions the human took in the viewer).",
        "inputSchema": {"type": "object", "properties": {}},
        "run": lambda a: SESSION.state(),
    },
    {
        "name": "debug_terminate",
        "description": "Kill the debuggee and end the session (breakpoints are kept for the next launch).",
        "inputSchema": {"type": "object", "properties": {}},
        "run": lambda a: SESSION.terminate(),
    },
]
TOOL_MAP = {t["name"]: t for t in TOOLS}

# --------------------------------------------------------------------------- MCP (stdio JSON-RPC)

def _reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(msg):
    method, id_ = msg.get("method"), msg.get("id")
    if method == "initialize":
        return _reply(id_, {
            "protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "swiftdbg", "version": "0.1.0"},
            "instructions": "Debug Swift/iOS processes with LLDB. Live viewer: http://localhost:%d" % VIEWER_PORT})
    if method == "tools/list":
        return _reply(id_, {"tools": [{k: t[k] for k in ("name", "description", "inputSchema")} for t in TOOLS]})
    if method == "tools/call":
        p = msg.get("params", {})
        tool = TOOL_MAP.get(p.get("name"))
        if not tool:
            return _reply(id_, error={"code": -32602, "message": "unknown tool %s" % p.get("name")})
        try:
            out = tool["run"](p.get("arguments") or {})
            return _reply(id_, {"content": [{"type": "text", "text": json.dumps(out, indent=1)}]})
        except (DAPError, KeyError, ValueError) as e:
            return _reply(id_, {"content": [{"type": "text", "text": "error: %s" % e}], "isError": True})
        except Exception:
            log(traceback.format_exc())
            return _reply(id_, {"content": [{"type": "text", "text": traceback.format_exc()}], "isError": True})
    if method == "ping":
        return _reply(id_, {})
    if id_ is not None:
        _reply(id_, error={"code": -32601, "message": "method not found: %s" % method})


def serve_mcp():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        # Tool calls can block (waiting for a breakpoint), so run each on its own thread.
        threading.Thread(target=handle, args=(msg,), daemon=True).start()
    SESSION.terminate(quiet=True)

# --------------------------------------------------------------------------- viewer (HTTP)

class Viewer(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            body = open(os.path.join(HERE, "viewer.html"), "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/state":
            self._json(SESSION.state())
        elif self.path.startswith("/source?"):
            from urllib.parse import parse_qs, urlparse
            path = parse_qs(urlparse(self.path).query).get("path", [""])[0]
            # Only serve files the session already knows about.
            known = set(SESSION.breakpoints) | {f.get("file") for f in SESSION.snapshot.get("frames", [])}
            if path in known and os.path.isfile(path):
                self._json({"path": path, "lines": open(path, errors="replace").read().splitlines()})
            else:
                self._json({"error": "unknown file"}, 404)
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        action = self.path.strip("/")
        try:
            if action == "toggle":
                out = SESSION.toggle_breakpoint(data["file"], int(data["line"]), who="human")
            elif action in ("continue", "over", "in", "out"):
                out = SESSION.resume(action, 30, who="human")
            elif action == "pause":
                out = SESSION.pause(who="human")
            elif action == "frame":
                out = SESSION.select_frame(int(data["index"]), who="human")
            elif action == "expand":
                out = {"variables": SESSION.variables(int(data["ref"]))}
            elif action == "eval":
                out = SESSION.evaluate(data["expression"], bool(data.get("lldb")), who="human")
            else:
                return self._json({"error": "unknown action"}, 404)
            self._json(out)
        except Exception as e:
            self._json({"error": str(e)}, 400)


def serve_viewer():
    # Another swiftdbg (or the demo) may hold the port; keep trying so the
    # viewer and the swiftdbg-pane mod attach to this session once it frees up.
    import time
    warned = False
    while True:
        try:
            httpd = ThreadingHTTPServer(("127.0.0.1", VIEWER_PORT), Viewer)
            break
        except OSError as e:
            if not warned:
                log("viewer port %d busy (%s); retrying every 2s" % (VIEWER_PORT, e))
                warned = True
            time.sleep(2)
    log("viewer on http://localhost:%d" % VIEWER_PORT)
    httpd.serve_forever()


if __name__ == "__main__":
    threading.Thread(target=serve_viewer, daemon=True).start()
    serve_mcp()
