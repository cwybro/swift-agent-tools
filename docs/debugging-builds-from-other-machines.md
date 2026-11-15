# Debugging a build made on another machine

Question: can swiftdbg set breakpoints in an executable (an iOS app / IPA) built
somewhere else, given the source at the exact commit it was built from?

Short answer: **yes, if you have the build's dSYM and the build lets a debugger
attach.** Having the source alone is not enough.

## What was tested here (macOS, SwiftPM sample, LLDB 2103 / Swift 6.4.2)

A "build machine" directory built `SampleApp` in release with `-g`, saved the
dSYM with `dsymutil`, stripped the shipped binary, and was then deleted.

| Experiment | Result |
|---|---|
| Stripped binary, no dSYM: `b main.swift:27`, `b Cart.total` | **No locations.** File:line and Swift function names are gone. |
| Stripped binary + matching dSYM (`target symbols add`) | **`main.swift:27` resolves**, even though `Cart.total()` was inlined into `main` by the optimizer. |
| Rebuild the same commit at a **different path** | **Different UUID**; LLDB rejects the old dSYM: "does not match any existing module". |
| Rebuild the same commit at the **same absolute path**, same toolchain | **Identical UUID** (D4A00FDF…): a rebuilt dSYM would match. |
| Rebuild at different paths with `-file-prefix-map` (+ linker `-oso_prefix`) | Still different UUIDs. Path-independent rebuilds need more than this (a hermetic build such as Bazel's). |
| Re-sign the shipped binary (`codesign -f`) | **UUID unchanged**, so the dSYM still matches a re-signed app. |
| Re-sign without `com.apple.security.get-task-allow` | The debugger cannot attach. SwiftPM debug builds carry that entitlement; the stripped/re-signed one did not. |

Not verified here (blocked by the macOS Developer Tools authorization prompt,
since Developer Mode is off on this Mac): stopping at the breakpoint and reading
source + variables through `target.source-map`. That part is standard LLDB; see
the recipe below.

## What you need

1. **The dSYM whose UUID matches the binary.** Check with
   `dwarfdump --uuid App.app/App App.app.dSYM`. Xcode archives keep it
   (`*.xcarchive/dSYMs`); CI should upload it as an artifact. For App Store
   builds it is also downloadable from App Store Connect.
   Without it, rebuilding the exact commit only helps if you reproduce the build
   exactly (same absolute path, Xcode/toolchain, flags, SDK), as shown above.
2. **Source at the exact commit**, so line numbers match. The dSYM records the
   build machine's absolute paths; map them to your checkout:
   `settings set target.source-map /Users/ci/builds/app /Users/you/src/app`
   (`dwarfdump App.app.dSYM | grep -m1 DW_AT_comp_dir` shows the old prefix).
   swiftdbg takes these as `init_commands` on `debug_launch` / `debug_attach`.
3. **A build a debugger may attach to** (`get-task-allow`):
   - Development-signed builds: yes.
   - Ad hoc, TestFlight, App Store, Enterprise: no. Re-sign the IPA with your own
     development certificate and profile (adds `get-task-allow`; the UUID and so
     the dSYM match are unchanged).
   - iOS Simulator builds: always attachable, but an IPA is a device build and
     cannot run in the Simulator.
4. **A debug-friendly configuration** if possible. Release (`-O`) builds still
   break on file:line, but variables are often "optimized out", inlined code
   jumps around, and `po` may fail; `v` (frame variable) is the most reliable.

## Recipe (device, iOS 17+)

```
xcrun devicectl device install app --device <udid> Resigned.ipa
xcrun devicectl device process launch --device <udid> --start-stopped com.example.app
# then in lldb (or swiftdbg's debug_attach with init_commands):
device select <udid>
device process attach --pid <pid>
target symbols add /path/App.app.dSYM
settings set target.source-map /Users/ci/builds/app /Users/you/src/app
b CartView.swift:42
continue
```

This device path needs full Xcode (not just Command Line Tools) and is untested
in this repo.
