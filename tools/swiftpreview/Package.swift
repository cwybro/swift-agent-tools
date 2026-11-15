// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "swiftpreview",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "swiftpreview", targets: ["swiftpreview"])],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
  ],
  targets: [
    .target(
      name: "SwiftPreviewCore",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
      ]
    ),
    .executableTarget(name: "swiftpreview", dependencies: ["SwiftPreviewCore"]),
    .testTarget(name: "SwiftPreviewCoreTests", dependencies: ["SwiftPreviewCore"]),
  ]
)
