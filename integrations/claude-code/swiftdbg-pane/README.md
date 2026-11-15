# swiftdbg-pane

```
/plugin install swiftdbg-pane --marketplace <owner>/swift-agent-tools
```

The plugin starts the swiftdbg MCP server ([tools/swiftdbg](../../../tools/swiftdbg/README.md),
linked into the plugin as `server/`), so Claude gets the `debug_*` tools.

A Claude Code mod that shows the live swiftdbg debug session in a pane beside
the chat. The agent drives LLDB through the swiftdbg MCP server; this pane
follows the same session and lets you step, continue, pause, toggle
breakpoints (click the dot beside a line), switch stack frames and expand
variables. It polls the swiftdbg viewer endpoint at http://127.0.0.1:7311,
opens itself when a debug session starts, and can be opened with /swiftdbg or
the "Open debugger" button shown above the prompt while a session is active.

To set a breakpoint by name, type `File.swift:42` in the pane's "Add breakpoint"
field, or run `/swiftdbg break File.swift:42`. Add a folder (`App/Cart.swift:42`)
when two files share a name. The source view jumps to that line.

The Files tab lists the project's .swift files (build output skipped). Filter by
name, search their text, and open one to browse it page by page and toggle
breakpoints in its gutter. With the pane focused: `1` Debug, `2` Files,
`f` find a file, `g` search text.
