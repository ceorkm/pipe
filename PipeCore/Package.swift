// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PipeCore",
    platforms: [.macOS("15.0")],
    products: [
        // Static: the system extension runs from /Library/SystemExtensions, outside the app
        // bundle, so a dynamic framework at @rpath would fail to load there.
        .library(name: "PipeCore", type: .static, targets: ["PipeCore"]),
    ],
    targets: [
        .target(name: "PipeCore"),
        .testTarget(name: "PipeCoreTests", dependencies: ["PipeCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
