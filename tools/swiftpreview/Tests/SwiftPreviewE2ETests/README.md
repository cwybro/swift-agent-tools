# End-to-end tests

These build a real Bazel workspace and drive `swiftpreview serve` the way the
pane does, so they need Bazel (bazelisk), Xcode and a few minutes the first
time. They are skipped unless `SWIFTPREVIEW_E2E=1`:

```bash
swift build && SWIFTPREVIEW_E2E=1 swift test --filter SwiftPreviewE2ETests
```

`Tests/Fixtures/layered` is a workspace of four Swift modules: `Core`, `UI`
(imports Core), `Profile` (imports UI and Core; has the preview) and `Sibling`
(imports Core, linked into the host, imported by nothing the preview sees).
Each test copies it to `~/Library/Caches/swiftpreview/e2e/<name>`, so Bazel's
cache for it stays warm between runs, and edits that copy: bodies at each
layer hot reload, `Sibling` is not watched, a stored property rebuilds, and
adding, removing or a BUILD edit re-queries and rebuilds. They run once per
watch mode (`poll` and `events`).
