"""Drive server.py over MCP stdio like an agent would."""
import json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(os.path.dirname(os.path.dirname(HERE)), "examples", "swiftpm")
SRC = os.path.join(APP, "Sources/SampleApp/main.swift")
p = subprocess.Popen([sys.executable, os.path.join(HERE, "server.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                     env=dict(os.environ, SWIFTDBG_PORT=os.environ.get("SWIFTDBG_PORT", "7312")))
n = 0
def call(method, params=None):
    global n; n += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params or {}}) + "\n"); p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("id") == n: return m
def tool(name, **args):
    r = call("tools/call", {"name": name, "arguments": args})["result"]
    text = r["content"][0]["text"]
    print("\n### %s %s%s" % (name, json.dumps(args)[:120], "  [ERROR]" if r.get("isError") else ""))
    try: return json.loads(text)
    except ValueError: print(text); return text
def brief(s):
    if not isinstance(s, dict): return
    print("status:", s.get("status"), "| reason:", s.get("reason"))
    for f in s.get("frames", [])[:3]: print("  frame:", f["name"], os.path.basename(f["file"] or "?"), f["line"])
    for v in s.get("locals", []): print("  local: %s: %s = %s (ref %s)" % (v["name"], v["type"], v["value"], v["ref"]))
    if s.get("source"): print(s["source"]["text"])
    if s.get("output"): print("output:", s["output"].strip())

call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke"}})
print("tools:", [t["name"] for t in call("tools/list")["result"]["tools"]])
tool("debug_set_breakpoints", file=SRC, lines=[27])
brief(tool("debug_launch", program=os.path.join(APP, ".build/debug/SampleApp")))
s = tool("debug_evaluate", expression="sub"); print(s)
s = tool("debug_evaluate", expression="self.discountPercent"); print(s)
s = tool("debug_evaluate", expression="v self.items[0]", lldb_command=True); print(s)
brief(tool("debug_step", kind="over"))
brief(tool("debug_step", kind="out"))
brief(tool("debug_select_frame", index=0))
brief(tool("debug_continue"))
st = tool("debug_status"); print("activity:", *st["activity"], sep="\n  ")
p.stdin.close(); p.wait(5)
