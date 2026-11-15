"""swiftui_preview_host: a Bazel-built app that renders SwiftUI previews and
hot reloads them with swiftpreview.

The host links the libraries under preview, compiled for dynamic replacement:

  * `-enable-implicit-dynamic`: every function and property is replaceable,
    so a thunk dylib can swap in new bodies with `@_dynamicReplacement`.
  * `-enable-private-imports`: thunks can see `private`/`fileprivate` decls
    through `@_private(sourceFile:) import`.
  * `-enable-dynamic-replacement-chaining`: a later thunk replaces an earlier
    one for the same function.
  * the `swift.internalize_at_link` feature is turned off, so symbols stay
    visible to dylibs loaded at runtime.

These settings apply through a transition on the host's dependency edge only;
the rest of the build is untouched (the preview build gets its own output
directory).
"""

load("@rules_apple//apple:ios.bzl", "ios_application")
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")
load("@rules_swift//swift:swift_library.bzl", "swift_library")

PREVIEW_SWIFTCOPTS = [
    "-Xfrontend",
    "-enable-implicit-dynamic",
    "-Xfrontend",
    "-enable-private-imports",
    "-Xfrontend",
    "-enable-dynamic-replacement-chaining",
]

# -all_load: keep every object of every library, even ones the host's main
# never references (it references none). -export_dynamic: keep their symbols
# exported and alive so thunks bind to them with -undefined dynamic_lookup.
#
# swift_binary passes linkopts to clang, so they need -Wl,; rules_apple's
# linkopts go to ld as they are (it adds -Wl, itself).
PREVIEW_LINKOPTS = [
    "-Wl,-all_load",
    "-Wl,-export_dynamic",
]
PREVIEW_LD_OPTS = [
    "-all_load",
    "-export_dynamic",
]

_SWIFTCOPT = str(Label("@rules_swift//swift:copt"))
_FEATURES = "//command_line_option:features"

def _preview_transition_impl(settings, _attr):
    swiftcopts = list(settings[_SWIFTCOPT])
    if "-enable-implicit-dynamic" not in swiftcopts:
        swiftcopts.extend(PREVIEW_SWIFTCOPTS)
    features = list(settings[_FEATURES])
    if "-swift.internalize_at_link" not in features:
        features.append("-swift.internalize_at_link")
    return {
        _SWIFTCOPT: swiftcopts,
        _FEATURES: features,
    }

_preview_transition = transition(
    implementation = _preview_transition_impl,
    inputs = [_SWIFTCOPT, _FEATURES],
    outputs = [_SWIFTCOPT, _FEATURES],
)

def _swiftui_preview_host_impl(ctx):
    # A 1:1 transition on an attribute makes ctx.attr.app a one-element list.
    target = ctx.attr.app[0]
    files = target[DefaultInfo].files

    # What swiftpreview needs to know about this host, from the build itself:
    # it reads this file after `bazel build` instead of asking for settings.
    manifest = ctx.actions.declare_file(ctx.label.name + ".preview_manifest.json")
    info = {"platform": ctx.attr.platform}
    if ctx.attr.simulator:
        info["simulator"] = ctx.attr.simulator
    ctx.actions.write(manifest, json.encode_indent(info) + "\n")

    all_files = depset([manifest], transitive = [files])
    return [
        DefaultInfo(files = all_files),
        OutputGroupInfo(preview_host = files, swiftpreview_manifest = depset([manifest])),
    ]

_swiftui_preview_host = rule(
    implementation = _swiftui_preview_host_impl,
    attrs = {
        "app": attr.label(mandatory = True, cfg = _preview_transition),
        "platform": attr.string(values = ["ios", "macos"], default = "ios"),
        "simulator": attr.string(doc = "Default iOS simulator (name or UDID) for this host."),
    },
    doc = "Builds `app` with the preview compiler flags. Found by `swiftpreview` with `kind(swiftui_preview_host, ...)`.",
)

def swiftui_preview_host(
        name,
        deps,
        platform = "ios",
        simulator = None,
        bundle_id = "dev.swiftpreview.host",
        minimum_os_version = "17.0",
        families = ["iphone", "ipad"],
        infoplists = None,
        tags = [],
        visibility = None,
        **kwargs):
    """A preview host app for `deps` (swift_library targets with views).

    Args:
      name: The host target. swiftpreview finds it from the file being previewed,
        or takes `--host`.
      deps: Libraries whose previews to render. Their transitive deps come along.
      platform: "ios" (simulator app, needs Xcode) or "macos" (executable).
        swiftpreview reads it from the build; nothing else repeats it.
      simulator: Default simulator for an iOS host, e.g. "iPad Air 11-inch (M4)"
        for an iPad-only app. Without it, a booted iPhone, else the newest
        iPhone. A developer's own pick (the pane, --simulator) wins.
      bundle_id: iOS bundle identifier.
      minimum_os_version: iOS deployment target.
      families: iOS device families.
      infoplists: Overrides the default host Info.plist.
      tags: Applied to every generated target. "manual" is always added to the
        inner targets so `bazel build //...` does not build them outside the
        preview configuration.
      visibility: Visibility of the host target.
      **kwargs: Passed to the ios_application or swift_binary.
    """
    runtime = Label("//runtime:SwiftPreviewRuntime")
    main = Label("//runtime:HostMain/PreviewHostMain.swift")
    inner_tags = tags + ["manual"]

    if platform == "ios":
        swift_library(
            name = name + "_main",
            srcs = [main],
            module_name = name.replace("-", "_") + "_PreviewHostMain",
            deps = deps + [runtime],
            tags = inner_tags,
        )
        ios_application(
            name = name + "_app",
            bundle_id = bundle_id,
            families = families,
            minimum_os_version = minimum_os_version,
            infoplists = infoplists or [Label("//runtime:HostMain/Info.plist")],
            linkopts = PREVIEW_LD_OPTS,
            deps = [":" + name + "_main"],
            tags = inner_tags,
            **kwargs
        )
    elif platform == "macos":
        swift_binary(
            name = name + "_app",
            srcs = [main],
            module_name = name.replace("-", "_") + "_PreviewHostMain",
            deps = deps + [runtime],
            linkopts = PREVIEW_LINKOPTS,
            tags = inner_tags,
            **kwargs
        )
    else:
        fail("platform must be \"ios\" or \"macos\"")

    _swiftui_preview_host(
        name = name,
        app = ":" + name + "_app",
        platform = platform,
        simulator = simulator,
        tags = tags,
        visibility = visibility,
    )
