# Design: SwiftUI previews and hot reload for Bazel

## Goal

See SwiftUI `#Preview`s from a Bazel (rules_swift + rules_apple) project without
Xcode's canvas, from Claude Code: a pane beside the chat that re-renders in about
a second on every save, and a tool Claude can call to look at the UI it just
wrote.

## Prior art

| Project | What it does | Takeaway |
|---|---|---|
| [rules_xcodeproj](https://github.com/MobileNativeFoundation/rules_xcodeproj) | Generates an Xcode project from Bazel targets; Xcode's own canvas then works (BwB mode). | Needs Xcode and a generated project; previews run in Xcode's process, not scriptable. |
| [rules_swift_previews](https://github.com/jhodsdon/rules_swift_previews) | Generates a `Package.swift` next to a `swift_library` so Xcode can preview it via SwiftPM. | Same: Xcode's canvas. |
| [axe](https://github.com/k-kohey/axe) | CLI previews with hot reload: builds with `xcodebuild`, compiles `#Preview` + `@_dynamicReplacement` thunks into a dylib, loads it into a host app on a headless simulator. Has a Claude Code plugin. | Proves the thunk technique outside Xcode. Tied to xcodebuild build settings. |
| PreviewsMCP (forks: [kezhuoquan](https://github.com/kezhuoquan/PreviewsMCP), [hanrw](https://github.com/hanrw/PreviewsMCP)) | Compiles a `#Preview` closure into a dylib and loads it into a macOS or simulator host, as an MCP server. | Same family. |
| [InjectionLite / InjectionNext](https://github.com/johnno1962/InjectionLite) | Hot reload for running apps; has a Bazel mode that recovers `swiftc` commands from `bazel aquery`. | `aquery` is the reliable way to get Bazel's real compile flags. |
| [SnapshotPreviews](https://github.com/EmergeTools/SnapshotPreviews) | Finds previews at runtime by scanning `PreviewProvider` / `PreviewRegistry` conformances. | An alternative discovery path; needs the `#Preview` macro to have run. |
| [swiftui-render](https://github.com/olliewagner/swiftui-render) | Renders a single file headlessly to PNG. | No `#Preview` support, no project context. |

None of these drives previews from **Bazel's own build graph**, which is the gap
here.

## How it works

```
 save File.swift
      │
      ▼
 swiftpreview serve ──(1) bazel build //:preview_host  (once, and on layout changes)
      │                 (2) bazel aquery SwiftCompile deps(//:preview_host)
      │                     → per-module swiftc flags (target, SDK, -I, -Xcc module maps, -D…)
      │
      ├─(3) SwiftSyntax: diff File.swift against the last full build
      │      body-only / additive change → thunk; stored layout change → back to (1)
      ├─(4) swiftc thunk.swift -emit-library -undefined dynamic_lookup  (~0.4s)
      ├─(5) write request.json {seq, dylibs, file, preview}
      ▼
 preview host (macOS process or iOS simulator app, built by Bazel)
      ├─ polls request.json, dlopen()s the dylib
      │    → the runtime applies its @_dynamicReplacement entries
      │    → swiftpreview_register() lists the file's previews
      ├─ shows the selected preview, captures it (drawHierarchy / cacheDisplay)
      └─ writes frame-N.png + frame-N.jpg, response.json
      │
      ▼
 JSON Lines events on stdout → the Claude mod's pane, status line and model context
```

### The host build (`previews/defs.bzl`)

`swiftui_preview_host` wraps an `ios_application` (or macOS `swift_binary`) in a
rule whose dependency edge has a transition that adds, for the preview build
only:

- `-enable-implicit-dynamic`: every function and property is replaceable.
- `-enable-private-imports`: thunks see `private` declarations through
  `@_private(sourceFile: "File.swift") import Module` (the file's **basename**).
- `-enable-dynamic-replacement-chaining`: later thunks win over earlier ones.
- the rules_swift feature `swift.internalize_at_link` **off**: with it on,
  rules_swift passes `-internalize-at-link` and the symbols thunks bind to
  disappear.

The host links with `-all_load` (the host's `main` references none of the
libraries under preview, so without it the linker drops their objects) and
`-export_dynamic` (keep their symbols alive and exported for `dynamic_lookup`).

The rule also writes `<name>.preview_manifest.json`, a manifest with the host's
`platform` and optional default `simulator`. `swiftpreview` reads it after
the build, so these facts live only in BUILD. Hosts without one fall back to
the compile commands' `-target` triples.

Bazel detects Xcode once, in the `local_config_xcode` repository, and keeps
that answer across Xcode installs, upgrades and `xcode-select` switches. A
stale answer fails analysis (`…system_sdk//:implicit_modules doesn't match
this configuration`) or quietly builds with the old Xcode. Before each full
build, `swiftpreview` compares the cached default Xcode's build version
(`default = ':version27_2_0_27B52'`) with the selected Xcode's
`version.plist`, and on a mismatch runs `bazel fetch --force
--repo=@@…local_config_xcode`. That takes about 2 s and keeps the action
cache. A build that fails with that error is refreshed and retried once.

On Bazel 9 the native `--swiftcopt` is gone; the transition writes rules_swift's
`@rules_swift//swift:copt` flag instead.

### Thunks (`tools/swiftpreview/Sources/SwiftPreviewCore`)

For each changed file the generator emits, per type:

```swift
@_private(sourceFile: "ProfileCard.swift") import Views
extension ProfileCard {
  @_dynamicReplacement(for: body)
  @ViewBuilder private var __preview__body: some View {
    #sourceLocation(file: "/abs/ProfileCard.swift", line: 13)
    …the body as written…
    #sourceLocation()
  }
}
```

- `@ViewBuilder` is added to `body` replacements: the original gets the builder
  from the `View` requirement, a replacement does not.
- `#sourceLocation` makes compile errors point at the user's file and line.
- Members whose signature is not in the last full build (new helpers) and whole
  new types are compiled into the thunk as ordinary declarations, so adding a
  subview or a computed property still hot reloads.
- Anything that changes memory layout or witness tables (stored properties,
  initializers, enum cases, conformances, protocols, `override`s) returns
  `needsRebuild`, and the session runs Bazel again and relaunches the host.
- `#Preview` closures become `PreviewContent.make { … }` (overloads for SwiftUI
  views, `UIViewController` and `UIView`, like the macro's); `@Previewable`
  declarations are hoisted into a wrapper view's properties. `PreviewProvider`s
  are listed too. This never runs the `#Preview` macro, so it also works where
  the macro plugin is missing.

All files changed since the last full build go into each thunk, so reverting a
change also reverts it in the running host.

### Compile flags from `aquery`

`bazel aquery 'mnemonic("SwiftCompile", deps(//:preview_host))' --output=jsonproto --include_param_files`
gives each module's real command line in the preview configuration. The cleaner
drops the worker wrapper, outputs, `-Xwrapped-swift=`, batch/WMO and explicit
module flags, and keeps target, SDK, search paths, module maps, defines and
features. The host's platform comes from the same output: the most common OS in the
`-target` triples of target-configuration (non-exec) compiles, so a macOS
exec tool under an iOS host doesn't count. The query is about 0.5 s on a warm
server and runs only on full builds, never on a hot reload.
`__BAZEL_XCODE_SDKROOT__` / `__BAZEL_XCODE_DEVELOPER_DIR__` are
resolved with `xcrun`. Thunks compile from the execution root, so all the
relative `bazel-out/...` paths resolve.

## Measured (macOS host, Command Line Tools only, Apple Silicon)

| Step | Time |
|---|---|
| Thunk compile + link | 0.40–0.49 s |
| `dlopen` + register | 0.05–0.07 s |
| Render + PNG/JPEG | 0.10 s |
| Save → new frame | ≈ 0.6 s |
| Layout change → Bazel rebuild → frame | a few seconds (incremental) |

## Limits and open work

- **iOS runs; hot reload on save is not yet verified there.** With Xcode 27.2
  the host builds, installs and launches on the simulator, the `-undefined
  dynamic_lookup` thunk loads, and `drawHierarchy` captures the frame
  (iPhone 18 Pro, iPad Air). Bazel's `.app` is read-only and `simctl install`
  fails to stage a read-only bundle (EACCES), so the host installs a writable
  copy from the session directory. Switching devices reinstalls the built app
  on the new simulator without a Bazel build; a cold boot takes about 20 s,
  an already-booted simulator a few seconds. Simulators are left booted.
- **Pane resolution.** The desktop pane draws pictures only through an SVG
  element capped at 131,072 characters, which holds a base64 image of about
  96 KB. A single image that small looks soft on a Retina display. So the CLI
  scales each frame to 2x and cuts it into 512-row strips, each a PNG when it
  fits (crisp text) or else the best JPEG that fits, splitting any strip that
  fits neither. The pane stacks them without gaps. An iPhone frame is about
  four PNGs, 70 KB in total, and slicing adds about 0.1 s.
- State resets on every reload (each frame is a fresh view), as in Xcode.
- Generic member signatures that differ only in constraints, `#if` inside
  function bodies across clauses, and result builders other than `@ViewBuilder`
  on `body` are handled textually and may need care.
- The Command Line Tools ship no SwiftUI macro plugins, so `@State`, `@Entry`,
  `#Preview` and friends only compile with Xcode. `examples/macos_clt` avoids
  them; `examples/macos` (Xcode) uses them, and hot reload works alongside the
  macros' own expansions.
- Files are watched by polling mtimes every ~120 ms; fine for a few thousand
  files.
- On macOS, capture (by default, `renderer: auto`) uses SwiftUI's
  `ImageRenderer` when the view tree is pure SwiftUI. When it contains AppKit-backed controls (`Toggle`, `TextField`,
  `NSViewRepresentable`…), which `ImageRenderer` cannot draw, it falls back to
  `cacheDisplay`, which adds tick marks to stroked capsules. Either can be
  forced (`swiftui` / `window`); each frame reports which one ran and why. iOS uses
  `drawHierarchy`. Effects that only exist in the window server (materials,
  some animations) may differ from the screen; `xcrun simctl io booted
  screenshot` is the fallback for iOS.
