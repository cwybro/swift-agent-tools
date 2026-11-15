"""Minimal Debug Adapter Protocol client for lldb-dap.

Owns one lldb-dap subprocess, speaks DAP over its stdio, and keeps a small
model of the session (breakpoints, last stop, program output) that both the
MCP tools and the web viewer read.
"""
import json
import os
import subprocess
import sys
import threading
import time
from typing import Any, Dict, List, Optional


def log(*a):
    print("[swiftdbg]", *a, file=sys.stderr, flush=True)


def find_lldb_dap() -> str:
    env = os.environ.get("LLDB_DAP")
    if env:
        return env
    out = subprocess.run(["xcrun", "--find", "lldb-dap"], capture_output=True, text=True)
    path = out.stdout.strip()
    if not path:
        raise RuntimeError("lldb-dap not found (install Xcode or Command Line Tools)")
    return path


class DAPError(Exception):
    pass


class DAPClient:
    def __init__(self):
        self.proc = subprocess.Popen(
            [find_lldb_dap(), "--repl-mode", "command"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self._seq = 0
        self._wlock = threading.Lock()
        self._pending: Dict[int, Dict[str, Any]] = {}
        self._cv = threading.Condition()
        self.events: List[Dict[str, Any]] = []   # all events, in order
        self.alive = True
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._stderr, daemon=True).start()

    # -- wire ---------------------------------------------------------------
    def _send(self, msg: Dict[str, Any]):
        body = json.dumps(msg).encode()
        with self._wlock:
            self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            self.proc.stdin.flush()

    def _reader(self):
        f = self.proc.stdout
        try:
            while True:
                length = None
                while True:
                    line = f.readline()
                    if not line:
                        raise EOFError
                    line = line.strip()
                    if not line:
                        break
                    k, _, v = line.decode().partition(":")
                    if k.lower() == "content-length":
                        length = int(v.strip())
                msg = json.loads(f.read(length))
                with self._cv:
                    if msg.get("type") == "response":
                        self._pending[msg["request_seq"]] = msg
                    elif msg.get("type") == "event":
                        self.events.append(msg)
                    self._cv.notify_all()
        except EOFError:
            pass
        finally:
            with self._cv:
                self.alive = False
                self._cv.notify_all()

    def _stderr(self):
        for line in self.proc.stderr:
            log("lldb-dap:", line.decode(errors="replace").rstrip())

    # -- requests -----------------------------------------------------------
    def send_request(self, command: str, arguments: Optional[Dict] = None) -> int:
        with self._cv:
            self._seq += 1
            seq = self._seq
        self._send({"seq": seq, "type": "request", "command": command, "arguments": arguments or {}})
        return seq

    def wait_response(self, seq: int, timeout: float = 30) -> Dict[str, Any]:
        deadline = time.time() + timeout
        with self._cv:
            while seq not in self._pending:
                left = deadline - time.time()
                if left <= 0 or not self.alive:
                    raise DAPError("no response to request %d (adapter %s)" % (seq, "alive" if self.alive else "exited"))
                self._cv.wait(left)
            resp = self._pending.pop(seq)
        if not resp.get("success"):
            raise DAPError(resp.get("message") or json.dumps(resp.get("body")))
        return resp.get("body") or {}

    def request(self, command: str, arguments: Optional[Dict] = None, timeout: float = 30) -> Dict[str, Any]:
        return self.wait_response(self.send_request(command, arguments), timeout)

    def wait_event(self, names, start_index: int, timeout: float) -> Optional[Dict[str, Any]]:
        """Wait for the first event named in `names` at or after start_index."""
        deadline = time.time() + timeout
        with self._cv:
            i = start_index
            while True:
                while i < len(self.events):
                    if self.events[i]["event"] in names:
                        return self.events[i]
                    i += 1
                left = deadline - time.time()
                if left <= 0 or not self.alive:
                    return None
                self._cv.wait(left)

    def event_count(self) -> int:
        with self._cv:
            return len(self.events)

    def failure(self, what: str) -> str:
        if self.alive:
            return what
        code = self.proc.poll()
        return ("lldb-dap exited (code %s) before the session started. If LLDB is crashing, check "
                "~/Library/Logs/DiagnosticReports/lldb*.ips; an outdated Xcode / Command Line Tools for this "
                "macOS version is the usual cause." % code)

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


class Session:
    """A debug session: what the agent and the viewer both look at."""

    def __init__(self):
        self.lock = threading.RLock()
        self.dap: Optional[DAPClient] = None
        self.breakpoints: Dict[str, Dict[int, Optional[str]]] = {}  # abs path -> {line: condition}
        self.verified: Dict[str, Dict[int, bool]] = {}
        self.status = "idle"          # idle | running | stopped | exited
        self.snapshot: Dict[str, Any] = {}
        self.version = 0
        self.activity: List[str] = []  # human-readable log of who did what
        self.program = None
        self._resume_mark = 0
        self._handled_mark = -1

    # -- helpers ------------------------------------------------------------
    def _note(self, who: str, what: str):
        self.activity.append("%s %s: %s" % (time.strftime("%H:%M:%S"), who, what))
        self.activity = self.activity[-200:]
        self.version += 1

    def output(self) -> str:
        if not self.dap:
            return ""
        return "".join(e["body"].get("output", "") for e in self.dap.events
                       if e["event"] == "output" and e["body"].get("category") in ("stdout", "stderr"))

    # -- breakpoints ----------------------------------------------------------
    def set_breakpoints(self, file: str, lines: List[int], conditions: Optional[Dict[int, str]] = None,
                        who: str = "agent") -> Dict[str, Any]:
        """Replace all breakpoints in `file` with `lines`."""
        with self.lock:
            path = os.path.abspath(file)
            conditions = conditions or {}
            self.breakpoints[path] = {int(l): conditions.get(int(l)) for l in lines}
            if not self.breakpoints[path]:
                del self.breakpoints[path]
            self._note(who, "breakpoints %s -> %s" % (os.path.basename(path), sorted(int(l) for l in lines)))
            if self.dap and self.status in ("running", "stopped"):
                self._push_breakpoints(path)
            return self.describe_breakpoints()

    def toggle_breakpoint(self, file: str, line: int, who: str = "human"):
        with self.lock:
            path = os.path.abspath(file)
            cur = dict(self.breakpoints.get(path, {}))
            if line in cur:
                del cur[line]
            else:
                cur[line] = None
            return self.set_breakpoints(path, list(cur), {k: v for k, v in cur.items() if v}, who=who)

    def _push_breakpoints(self, path: str):
        bps = self.breakpoints.get(path, {})
        args = {"source": {"path": path},
                "breakpoints": [dict(line=l, **({"condition": c} if c else {})) for l, c in sorted(bps.items())]}
        body = self.dap.request("setBreakpoints", args)
        self.verified[path] = {b.get("line", l): bool(b.get("verified"))
                               for l, b in zip(sorted(bps), body.get("breakpoints", []))}

    def describe_breakpoints(self) -> Dict[str, Any]:
        return {p: [{"line": l, "condition": c, "verified": self.verified.get(p, {}).get(l)}
                    for l, c in sorted(b.items())] for p, b in self.breakpoints.items()}

    # -- lifecycle ------------------------------------------------------------
    def launch(self, program: str, args: Optional[List[str]] = None, cwd: Optional[str] = None,
               stop_on_entry: bool = False, init_commands: Optional[List[str]] = None,
               timeout: float = 30, who: str = "agent") -> Dict[str, Any]:
        with self.lock:
            self.terminate(who=who, quiet=True)
            self.dap = DAPClient()
            self._resume_mark, self._handled_mark = 0, -1
            self.program = os.path.abspath(program)
            self.dap.request("initialize", {
                "clientID": "swiftdbg", "adapterID": "lldb-dap", "linesStartAt1": True,
                "columnsStartAt1": True, "pathFormat": "path", "supportsVariableType": True})
            # Newer lldb-dap answers `launch` only after configurationDone, so
            # send it, then do the configuration phase, then collect the reply.
            launch_seq = self.dap.send_request("launch", {
                "program": self.program, "args": args or [], "cwd": cwd or os.path.dirname(self.program),
                "stopOnEntry": stop_on_entry, "initCommands": init_commands or []})
            if not self.dap.wait_event({"initialized"}, 0, timeout):
                raise DAPError(self.dap.failure("adapter never sent 'initialized'"))
            for path in list(self.breakpoints):
                self._push_breakpoints(path)
            mark = self.dap.event_count()
            self.dap.request("configurationDone")
            self.dap.wait_response(launch_seq, timeout)
            self.status = "running"
            self._resume_mark = mark
            self._note(who, "launched %s" % os.path.basename(self.program))
        return self._wait_stop(mark, timeout)

    def attach(self, pid: Optional[int] = None, program: Optional[str] = None, wait_for: bool = False,
               init_commands: Optional[List[str]] = None, timeout: float = 60, who: str = "agent"):
        with self.lock:
            self.terminate(who=who, quiet=True)
            self.dap = DAPClient()
            self._resume_mark, self._handled_mark = 0, -1
            self.program = program
            self.dap.request("initialize", {"clientID": "swiftdbg", "adapterID": "lldb-dap",
                                            "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path"})
            a: Dict[str, Any] = {"initCommands": init_commands or []}
            if pid:
                a["pid"] = pid
            if program:
                a["program"] = program
            if wait_for:
                a["waitFor"] = True
            seq = self.dap.send_request("attach", a)
            if not self.dap.wait_event({"initialized"}, 0, timeout):
                raise DAPError(self.dap.failure("adapter never sent 'initialized'"))
            for path in list(self.breakpoints):
                self._push_breakpoints(path)
            mark = self.dap.event_count()
            self.dap.request("configurationDone")
            self.dap.wait_response(seq, timeout)
            self.status = "running"
            self._resume_mark = mark
            self._note(who, "attached to %s" % (pid or program))
        # An attach usually leaves the process stopped; report whatever happens first.
        return self._wait_stop(mark, 2)

    def terminate(self, who: str = "agent", quiet: bool = False):
        with self.lock:
            if self.dap:
                try:
                    self.dap.request("disconnect", {"terminateDebuggee": True}, timeout=5)
                except Exception:
                    pass
                self.dap.close()
                if not quiet:
                    self._note(who, "terminated session")
            self.dap = None
            self.status = "idle"
            self.snapshot = {}
            self.version += 1
            return {"status": self.status}

    # -- execution control ------------------------------------------------------
    def _require_stopped(self):
        if not self.dap:
            raise DAPError("no session; call debug_launch or debug_attach first")
        if self.status != "stopped":
            raise DAPError("process is %s, not stopped" % self.status)

    def resume(self, kind: str = "continue", timeout: float = 30, who: str = "agent") -> Dict[str, Any]:
        with self.lock:
            self._require_stopped()
            tid = self.snapshot.get("threadId")
            cmd = {"continue": "continue", "over": "next", "in": "stepIn", "out": "stepOut"}[kind]
            mark = self.dap.event_count()
            self.dap.request(cmd, {"threadId": tid})
            self.status = "running"
            self._resume_mark = mark
            self._note(who, kind)
        return self._wait_stop(mark, timeout)

    def pause(self, who: str = "agent"):
        with self.lock:
            if not self.dap or self.status != "running":
                raise DAPError("process is not running")
            mark = self.dap.event_count()
            self.dap.request("pause", {"threadId": 0})
            self._note(who, "pause")
        return self._wait_stop(mark, 10)

    def _wait_stop(self, mark: int, timeout: float) -> Dict[str, Any]:
        """Block (without holding the session lock) until the process stops or exits."""
        dap = self.dap
        ev = dap.wait_event({"stopped", "exited", "terminated"}, mark, timeout) if dap else None
        with self.lock:
            if dap is not self.dap or (ev is not None and self._handled_mark >= mark and self.status != "running"):
                # Session replaced, or another caller (e.g. the viewer) already handled this stop.
                return dict(self.snapshot, status=self.status)
            return self._handle_stop(ev, mark, timeout)

    def _handle_stop(self, ev, mark: int, timeout: float) -> Dict[str, Any]:
        if ev is None:
            self.version += 1
            return {"status": "running", "note": "still running after %.0fs; call debug_wait or debug_pause" % timeout,
                    "output": self.output()[-2000:]}
        self._handled_mark = mark
        if ev["event"] in ("exited", "terminated"):
            code = None
            if ev["event"] == "exited":
                code = ev["body"].get("exitCode")
            else:
                ex = self.dap.wait_event({"exited"}, mark, 0.5)
                code = ex["body"].get("exitCode") if ex else None
            self.status = "exited"
            self.snapshot = {"exitCode": code}
            self._note("process", "exited (code %s)" % code)
            return {"status": "exited", "exitCode": code, "output": self.output()[-4000:]}
        self.status = "stopped"
        self.snapshot = self._build_snapshot(ev["body"])
        top = self.snapshot["frames"][0] if self.snapshot["frames"] else {}
        self._note("process", "stopped (%s) at %s:%s" % (ev["body"].get("reason"), os.path.basename(top.get("file") or "?"), top.get("line")))
        return dict(self.snapshot, status="stopped")

    def wait(self, timeout: float = 30) -> Dict[str, Any]:
        with self.lock:
            if self.status != "running":
                return dict(self.snapshot, status=self.status)
            mark = self._resume_mark
        return self._wait_stop(mark, timeout)

    # -- inspection ---------------------------------------------------------
    def _build_snapshot(self, stop: Dict[str, Any], frame_count: int = 20) -> Dict[str, Any]:
        tid = stop.get("threadId")
        threads = self.dap.request("threads").get("threads", [])
        if tid is None and threads:
            tid = threads[0]["id"]
        st = self.dap.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": frame_count})
        frames = []
        for f in st.get("stackFrames", []):
            src = f.get("source") or {}
            frames.append({"id": f["id"], "name": f.get("name"), "file": src.get("path"), "line": f.get("line")})
        snap = {"reason": stop.get("reason"), "description": stop.get("description"),
                "threadId": tid, "threads": [{"id": t["id"], "name": t.get("name")} for t in threads],
                "frames": frames, "selectedFrame": 0}
        snap.update(self._frame_detail(frames[0]) if frames else {"locals": [], "source": None})
        return snap

    def _frame_detail(self, frame: Dict[str, Any]) -> Dict[str, Any]:
        scopes = self.dap.request("scopes", {"frameId": frame["id"]}).get("scopes", [])
        local_vars = []
        for s in scopes:
            if s.get("name", "").lower().startswith("local"):
                local_vars = self.variables(s["variablesReference"])
        return {"locals": local_vars, "source": self._source_excerpt(frame.get("file"), frame.get("line"))}

    def variables(self, ref: int, limit: int = 100) -> List[Dict[str, Any]]:
        out = []
        for v in self.dap.request("variables", {"variablesReference": ref}).get("variables", [])[:limit]:
            out.append({"name": v.get("name"), "type": v.get("type"), "value": v.get("value"),
                        "ref": v.get("variablesReference", 0)})
        return out

    def select_frame(self, index: int, who: str = "agent") -> Dict[str, Any]:
        with self.lock:
            self._require_stopped()
            frames = self.snapshot["frames"]
            if not 0 <= index < len(frames):
                raise DAPError("frame index out of range (0..%d)" % (len(frames) - 1))
            self.snapshot.update(self._frame_detail(frames[index]))
            self.snapshot["selectedFrame"] = index
            self._note(who, "selected frame #%d %s" % (index, frames[index]["name"]))
            return dict(self.snapshot, status="stopped")

    def evaluate(self, expression: str, lldb_command: bool = False, who: str = "agent") -> Dict[str, Any]:
        with self.lock:
            self._require_stopped()
            frame = self.snapshot["frames"][self.snapshot.get("selectedFrame", 0)]
            ctx = "repl" if lldb_command else "watch"
            body = self.dap.request("evaluate", {"expression": expression, "frameId": frame["id"], "context": ctx})
            self._note(who, ("lldb> " if lldb_command else "eval ") + expression)
            return {"result": body.get("result"), "type": body.get("type"), "ref": body.get("variablesReference", 0)}

    @staticmethod
    def _source_excerpt(path: Optional[str], line: Optional[int], radius: int = 6):
        if not path or not line or not os.path.exists(path):
            return None
        with open(path, errors="replace") as fh:
            lines = fh.read().splitlines()
        lo, hi = max(1, line - radius), min(len(lines), line + radius)
        return {"path": path, "line": line,
                "text": "\n".join("%s%4d  %s" % ("->" if i == line else "  ", i, lines[i - 1]) for i in range(lo, hi + 1))}

    def state(self) -> Dict[str, Any]:
        """Everything the viewer needs, as plain JSON."""
        with self.lock:
            return {"version": self.version, "status": self.status, "program": self.program,
                    "breakpoints": self.describe_breakpoints(), "snapshot": self.snapshot,
                    "output": self.output()[-8000:], "activity": self.activity[-60:]}
