# swiftdbg (proof of concept)

An MCP server that lets an agent debug Swift / iOS processes with LLDB, plus a
live web viewer (http://localhost:7311) that shows the **same** session to a
human, who can also step, toggle breakpoints, and inspect variables.

```
agent ──MCP stdio──┐
                   ├─ Session ── lldb-dap (DAP) ── LLDB ── your process
human ──HTTP:7311──┘
```

Stdlib Python 3.9+, no dependencies. Requires an LLDB that matches your macOS
version (`xcrun lldb-dap`).

## Files
- `dap.py` – DAP client for `lldb-dap` + the shared `Session` model
- `server.py` – MCP tools (`debug_*`) and the HTTP viewer endpoints
- `viewer.html` – Xcode-style view: source with breakpoint gutter, call stack,
  expandable variables, evaluate box, program output, shared activity log
- `smoke_test.py` – drives the server over MCP against `examples/swiftpm` (build it first)
- `demo_viewer.py` – viewer only, for UI work (`--launch` also starts SampleApp paused at a breakpoint)

## Tools
`debug_set_breakpoints`, `debug_launch`, `debug_attach`, `debug_continue`,
`debug_step`, `debug_wait`, `debug_pause`, `debug_select_frame`,
`debug_variables`, `debug_evaluate`, `debug_status`, `debug_terminate`.
Each stop returns stack, locals and a source excerpt so the agent rarely
needs a second call.

## Targets
- SwiftPM: `swift build`, then `debug_launch(program: .build/debug/App)`
- iOS Simulator: `xcrun simctl launch --wait-for-debugger <udid> <bundle>`,
  then `debug_attach(pid: …)`
- Bazel: build with `-c dbg`, pass
  `init_commands: ["settings set target.source-map . /abs/workspace"]`
