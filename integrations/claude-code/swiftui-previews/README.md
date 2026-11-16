# swiftui-previews

A Claude Code plugin that shows SwiftUI previews from a Bazel (rules_swift + rules_apple) project in a pane beside the chat. The pane hot reloads on every save. After Claude edits a Swift file while a preview runs, the plugin tells Claude how the reload went: the new frame, or compiler errors at the right file and line.

```
/plugin install swiftui-previews --marketplace <owner>/swift-agent-tools
```

It runs the `swiftpreview` CLI from [swift-agent-tools](../../../README.md) (`tools/swiftpreview`, built with `swift build -c release`). Set the `swiftpreviewPath` option to that binary unless `swiftpreview` is on your PATH. The plugin starts `swiftpreview mcp`, which gives Claude the `swiftui_preview`, `swiftui_preview_discover`, `swiftui_preview_list` and `swiftui_preview_devices` tools. Those render through the pane's session while one runs.

Commands: `/preview <File.swift> [n] [--host //label]`, `/preview dark|light`, `/preview device [name]`, `/preview renderer auto|swiftui|window`, `/preview zoom 25|50|75|100` (also the − and + buttons beside the file name), `/preview rebuild`, `/preview stop`.

Options: `swiftpreviewPath`, `editor` (xcode, vscode, cursor, default), `discoverPreviews` (search the workspace for previews on every start; off by default, the pane's **Find previews in the workspace** button does it on request), `keepHostMinutes` (keep the iOS host warm after Stop, default 10), `simulatorIdleMinutes` (shut down simulators swiftpreview booted once idle, default 15), and `watch` / `pollIntervalMs` / `watchEventsAbove` (poll or use file events to notice saves; by default it polls up to 200 files). See [Settings](../../../docs/swiftui-previews.md#settings).
