"""Run only the viewer (no MCP) for UI checks. With --launch, also start the
sample app stopped at a breakpoint so the stopped-state UI can be exercised."""
import os, sys, threading, server
app = os.path.join(os.path.dirname(os.path.dirname(server.HERE)), "examples", "swiftpm")
src = os.path.join(app, "Sources/SampleApp/main.swift")
server.SESSION.set_breakpoints(src, [18, 27])
if "--launch" in sys.argv:
    threading.Timer(1, lambda: server.SESSION.launch(os.path.join(app, ".build/debug/SampleApp"))).start()
server.serve_viewer()
