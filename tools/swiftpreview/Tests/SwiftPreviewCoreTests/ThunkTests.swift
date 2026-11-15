import Testing
@testable import SwiftPreviewCore

let card = """
  import SwiftUI

  struct Card: View {
    let title: String
    var body: some View {
      Text(title)
    }
    private func label(for count: Int, _ suffix: String) -> String { "\\(count)\\(suffix)" }
  }

  #Preview("Light") {
    Card(title: "Hi")
  }

  #Preview(traits: .sizeThatFitsLayout) {
    @Previewable @State var on = true
    Toggle("On", isOn: $on)
  }
  """

func plan(_ current: String, baseline: String? = nil) -> ThunkPlan {
  let c = SourceAnalyzer.analyze(source: current, path: "/w/Card.swift")
  let b = SourceAnalyzer.analyze(source: baseline ?? current, path: "/w/Card.swift")
  return ThunkGenerator.plan(current: c, baseline: b, options: ThunkOptions(moduleName: "Views", registerPreviews: true, fileKey: "Card.swift"))
}

@Test func findsPreviews() {
  let a = SourceAnalyzer.analyze(source: card, path: "/w/Card.swift")
  #expect(a.previews.map(\.displayName) == ["Light", "Preview 2"])
  #expect(a.previews[1].layout == .sizeThatFits)
  #expect(a.previews[1].previewables == ["@State var on = true"])
}

@Test func replacesBodiesAndFunctions() throws {
  guard case .thunk(let s) = plan(card) else { Issue.record("expected a thunk"); return }
  #expect(s.contains("@_private(sourceFile: \"Card.swift\") import Views"))
  #expect(s.contains("@_dynamicReplacement(for: body)"))
  #expect(s.contains("@ViewBuilder"))
  #expect(s.contains("@_dynamicReplacement(for: label(for:_:))"))
  #expect(s.contains("private struct __SwiftPreview_1: View"))
  #expect(s.contains("@_cdecl(\"swiftpreview_register\")"))
}

@Test func bodyEditHotReloads() {
  let edited = card.replacingOccurrences(of: "Text(title)", with: "Text(title).bold()")
  guard case .thunk(let s) = plan(edited, baseline: card) else { Issue.record("expected a thunk"); return }
  #expect(s.contains("Text(title).bold()"))
}

@Test func storedPropertyChangeNeedsRebuild() {
  let edited = card.replacingOccurrences(of: "let title: String", with: "let title: String\n  var count = 0")
  guard case .needsRebuild = plan(edited, baseline: card) else { Issue.record("expected a rebuild"); return }
}

@Test func newTypeAndMemberAreEmittedVerbatim() {
  let edited = card
    .replacingOccurrences(of: "Text(title)", with: "Badge(); extra")
    + "\nstruct Badge: View { var body: some View { Circle() } }\n"
  let withMember = edited.replacingOccurrences(of: "  private func label", with: "  var extra: some View { EmptyView() }\n  private func label")
  guard case .thunk(let s) = plan(withMember, baseline: card) else { Issue.record("expected a thunk"); return }
  #expect(s.contains("struct Badge: View"))
  #expect(s.contains("var extra: some View { EmptyView() }"))
  #expect(!s.contains("@_dynamicReplacement(for: extra)"))
}

@Test func cleansBazelSwiftCompileArguments() {
  let args = [
    "bazel-out/darwin_arm64-opt-exec/bin/external/rules_swift+/tools/worker/worker", "/usr/bin/swiftc",
    "-target", "arm64-apple-ios17.0-simulator", "-sdk", "__BAZEL_XCODE_SDKROOT__",
    "-Xwrapped-swift=-bazel-target-label=@@//lib:Views", "-emit-object",
    "-output-file-map", "bazel-out/x/Views.output_file_map.json",
    "-emit-module-path", "bazel-out/x/bin/lib/Views.swiftmodule",
    "-Xfrontend", "-const-gather-protocols-file", "-Xfrontend", "external/x.json",
    "-Xfrontend", "-internalize-at-link", "-DDEBUG", "-Onone",
    "-Xcc", "-iquote.", "-enable-batch-mode", "-module-name", "Views", "-static",
    "-I", "bazel-out/x/bin/dep", "lib/A.swift", "lib/B.swift",
  ]
  let r = ArgumentCleaner.clean(args)
  #expect(r.swiftc == "/usr/bin/swiftc")
  #expect(r.moduleName == "Views")
  #expect(r.moduleDir == "bazel-out/x/bin/lib")
  #expect(r.sources == ["lib/A.swift", "lib/B.swift"])
  #expect(r.flags == ["-target", "arm64-apple-ios17.0-simulator", "-sdk", "__BAZEL_XCODE_SDKROOT__", "-DDEBUG", "-Onone", "-Xcc", "-iquote.", "-I", "bazel-out/x/bin/dep"])
}

@Test func staleBuildErrorsTriggerRebuildButCodeErrorsDoNot() {
  #expect(PreviewSession.isStaleBuildError("Card+Preview.swift:2:51: error: no such module 'Views'"))
  #expect(PreviewSession.isStaleBuildError("error: compiled module was created by a newer version of the compiler"))
  #expect(!PreviewSession.isStaleBuildError("Card.swift:9:7: error: cannot find 'Txet' in scope"))
}

@Test func simulatorsSortIPhonesOnStandardNewestRuntimesFirst() {
  func d(_ name: String, _ runtime: String, _ id: String, _ state: String = "Shutdown") -> SimDevice {
    SimDevice(udid: name, name: name, runtime: runtime, state: state, runtimeID: "com.apple.CoreSimulator.SimRuntime.\(id)")
  }
  let list = [
    d("iPad (A16)", "iOS 27.2", "iOS-27-2"),
    d("iPhone Duo", "iOS 27.2", "iOS-27-2-iPhone19-4"),
    d("iPhone 16", "iOS 26.0", "iOS-26-0"),
    d("iPhone 18 Pro", "iOS 27.2", "iOS-27-2"),
  ]
  let sorted = SimDevice.sort(list)
  #expect(sorted.map(\.name) == ["iPhone 18 Pro", "iPhone 16", "iPhone Duo", "iPad (A16)"])
  #expect(SimDevice.preferred(sorted)?.name == "iPhone 18 Pro")
  let booted = SimDevice.sort(list.map { $0.name == "iPhone 16" ? d("iPhone 16", "iOS 26.0", "iOS-26-0", "Booted") : $0 })
  #expect(SimDevice.preferred(booted)?.name == "iPhone 16")
}

@Test func platformComesFromTargetTriples() {
  #expect(AQuery.platform(ofTriple: "arm64-apple-ios17.0-simulator") == "ios")
  #expect(AQuery.platform(ofTriple: "arm64-apple-macos14.0") == "macos")
  #expect(AQuery.platform(ofTriple: "x86_64-apple-macosx13.0") == "macos")
  #expect(AQuery.platform(ofTriple: "arm64-apple-xros2.0-simulator") == "xros")
  func m(_ name: String, _ target: String, _ config: String = "ios_sim_arm64-fastbuild") -> ModuleCompile {
    ModuleCompile(moduleName: name, swiftc: "swiftc", flags: [], sources: [], moduleDir: nil, target: target, environment: [:], configuration: config)
  }
  // A macOS exec-configuration tool under an iOS host does not count.
  let compiles = [
    m("Profile", "arm64-apple-ios17.0-simulator"), m("Runtime", "arm64-apple-ios17.0-simulator"),
    m("Tool", "arm64-apple-macos14.0", "darwin_arm64-opt-exec-ST-1"), m("Tool2", "arm64-apple-macos14.0", "darwin_arm64-opt-exec-ST-1"),
    m("Tool3", "arm64-apple-macos14.0", "darwin_arm64-opt-exec-ST-1"),
  ]
  #expect(AQuery.hostPlatform(compiles) == "ios")
  #expect(AQuery.hostPlatform([m("Views", "arm64-apple-macos14.0", "darwin_arm64-fastbuild")]) == "macos")
}

@Test func detectsStaleXcodeDetection() {
  let good = """
    xcode_version(
      name = 'version27_2_0_27B52',
      version = '27.2.0.27B52',
    )
    xcode_config(
      name = 'host_xcodes',
      default = ':version27_2_0_27B52',
    )
    """
  let none = "xcode_config(name = 'host_xcodes')\n# Error: Invoking xcode-locator failed, return code 1"
  let c = XcodeCheck.parse(good, repo: "r")
  #expect(c.defaultBuild == "27B52")
  #expect(XcodeCheck.staleReason(cached: c, active: ("Xcode 27.2", "27B52")) == nil)
  #expect(XcodeCheck.staleReason(cached: c, active: ("Xcode 27.3", "27C10")) != nil)
  #expect(XcodeCheck.staleReason(cached: XcodeCheck.parse(none, repo: "r"), active: ("Xcode 27.2", "27B52")) != nil)
  // Only the Command Line Tools selected: nothing to compare.
  #expect(XcodeCheck.staleReason(cached: XcodeCheck.parse(none, repo: "r"), active: nil) == nil)
  #expect(XcodeCheck.isStaleXcodeError(#"configurable attribute "actual" in @@rules_swift++system_sdk+system_sdk//:implicit_modules doesn't match this configuration"#))
  #expect(!XcodeCheck.isStaleXcodeError("error: cannot find 'Txet' in scope"))
}
