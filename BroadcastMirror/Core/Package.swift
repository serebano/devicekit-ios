// swift-tools-version:5.7
import PackageDescription

// Pure, platform-agnostic core of the Broadcast Mirror encoder: the resolution,
// bitrate and NAL byte-format logic. Extracted so it runs deviceless under
// `swift test` (no VideoToolbox / ReplayKit / signing needed). The extension
// target compiles the SAME sources directly (see project.rb), so this package is
// the single source of truth for the tested logic — never a fork of it.
let package = Package(
    name: "BroadcastMirrorCore",
    products: [
        .library(name: "BroadcastMirrorCore", targets: ["BroadcastMirrorCore"]),
    ],
    targets: [
        .target(name: "BroadcastMirrorCore", path: "Sources/BroadcastMirrorCore"),
        .testTarget(
            name: "BroadcastMirrorCoreTests",
            dependencies: ["BroadcastMirrorCore"],
            path: "Tests/BroadcastMirrorCoreTests"
        ),
    ]
)
