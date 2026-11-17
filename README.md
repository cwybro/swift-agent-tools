# swift-agent-tools

**Let coding agents see and debug the Swift apps they write.**

Two MCP servers for Swift and SwiftUI. Any MCP agent can use them (Claude Code, Codex, Cursor and others). Claude Code also gets panes beside the chat.

| | |
|---|---|
| **SwiftUI previews for Bazel** | Render any `#Preview` from a rules_swift / rules_apple project on macOS or an iOS simulator. A save shows a new frame in about a second, with no Xcode canvas and no generated `.xcodeproj`. |
| **swiftdbg** | Drive LLDB on a Swift process or simulator app: breakpoints, stepping, variables and expressions. You follow and drive the same session in a live viewer. |

<p>
  <img src="docs/images/swiftui-previews-pane.png" height="360" alt="The SwiftUI Preview pane: a profile view rendered on an iPhone simulator, with buttons for each preview, a device picker, and Dark, Rebuild and Stop.">
  <img src="docs/images/swiftdbg-pane.png" height="360" alt="The swiftdbg pane: Claude stopped a sample app at a breakpoint; the pane shows the source line, call stack and variables, with Continue and Step buttons.">
</p>

## Quick start

**Requirements:** macOS with Xcode (or only the Command Line Tools for macOS previews), plus Bazel or bazelisk for previews and Python 3.9+ for swiftdbg.

**1. Build the preview CLI.** swiftdbg needs no build.

```bash
git clone https://github.com/cwybro/swift-agent-tools && cd swift-agent-tools
```

```bash
cd tools/swiftpreview && swift build -c release
```

**2. Add a preview host to your Bazel project.**

```starlark
# MODULE.bazel
bazel_dep(name = "rules_swiftui_previews", version = "0")
local_path_override(module_name = "rules_swiftui_previews", path = "path/to/swift-agent-tools")
```

```starlark
# BUILD.bazel
load("@rules_swiftui_previews//previews:defs.bzl", "swiftui_preview_host")

swiftui_preview_host(
    name = "preview_host",
    platform = "ios",               # or "macos"
    deps = ["//Features/Profile"],  # swift_library targets with previews
)
```

**3. Connect your agent.** Pick one of these:

<details open>
<summary><b>Claude Code</b>: plugins with panes</summary>

```
/plugin marketplace add cwybro/swift-agent-tools
/plugin install swiftui-previews@swift-agent-tools
/plugin install swiftdbg-pane@swift-agent-tools
```

Set the swiftui-previews `swiftpreviewPath` option to `tools/swiftpreview/.build/release/swiftpreview`, unless that binary is on your `PATH`. Then:

- `/preview path/to/View.swift` opens a pane that hot reloads on every save. It has a button for each preview, light and dark, a device picker, and Rebuild.
- The debugger pane opens when Claude starts a debug session. `/swiftdbg break File.swift:42` sets a breakpoint.

</details>

<details>
<summary><b>Any MCP agent</b></summary>

Copy [integrations/mcp.json](integrations/mcp.json) into your agent's MCP config, and replace `/path/to/swift-agent-tools` with your checkout's path.

| Server | Tools |
|---|---|
| `swiftpreview mcp` | `swiftui_preview`, `swiftui_preview_discover`, `swiftui_preview_list`, `swiftui_preview_devices` |
| `python3 tools/swiftdbg/server.py` | `debug_launch`, `debug_attach`, `debug_set_breakpoints`, `debug_step`, `debug_continue`, `debug_variables`, `debug_evaluate`, … |

`swiftui_preview` returns the rendered PNG inline, so the agent sees the UI it just changed. The swiftdbg viewer runs at http://localhost:7311.

</details>

Or use the CLI on its own:

```bash
tools/swiftpreview/.build/release/swiftpreview serve path/to/View.swift
```

## Docs

- [SwiftUI previews](docs/swiftui-previews.md): setup, CLI, settings, what hot reloads and what's watched
- [Design and prior art](docs/DESIGN.md)
- [swiftdbg](tools/swiftdbg/README.md)
- [Debugging builds from other machines](docs/debugging-builds-from-other-machines.md)

<details>
<summary><b>Repository layout</b></summary>

```
tools/swiftpreview/        Swift CLI + MCP server for previews
runtime/                   SwiftPreviewRuntime, linked into the preview host app
previews/defs.bzl          swiftui_preview_host Bazel macro (this repo is the Bazel module)
tools/swiftdbg/            Python MCP server for LLDB (lldb-dap) + the live viewer
integrations/mcp.json      MCP config for any agent
integrations/claude-code/  Claude Code plugins: swiftui-previews, swiftdbg-pane
examples/                  ios, macos, macos_clt preview hosts; swiftpm debugger sample
```

Everything an agent can do lives under `tools/` and is reachable over MCP or as a CLI with JSON output. The plugins only add what needs the Claude Code UI.

</details>

<details>
<summary><b>Running the tests</b></summary>

```bash
cd tools/swiftpreview && swift test
```

End to end: builds a four-module Bazel workspace and checks that edits at each layer reload the preview, in both watch modes (about a minute once cached):

```bash
cd tools/swiftpreview && swift build && SWIFTPREVIEW_E2E=1 swift test --filter SwiftPreviewE2ETests
```

```bash
cd examples/swiftpm && swift build && python3 ../../tools/swiftdbg/smoke_test.py
```

```bash
claude plugin test integrations/claude-code/swiftui-previews
```

```bash
claude plugin test integrations/claude-code/swiftdbg-pane
```

</details>

## License

[MIT](LICENSE)
