// swift-tools-version:6.0
import PackageDescription

// Platforms: only the ones CI builds. iOS (generic Simulator via xcodebuild) and
// macOS (swift build/test on macos-15). Linux is built and tested in its own job.
let package = Package(
    name: "CapabilityPlane",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CapabilityPlane", targets: ["CapabilityPlane"]),
        .library(name: "CapabilityPlaneUI", targets: ["CapabilityPlaneUI"]),
    ],
    targets: [
        .target(name: "CapabilityPlane"),
        .target(name: "CapabilityPlaneUI", dependencies: ["CapabilityPlane"]),
        .testTarget(name: "CapabilityPlaneTests", dependencies: ["CapabilityPlane"]),
        // Console-model tests. The file compiles to nothing where SwiftUI is absent (Linux),
        // and runs in the macOS CI job.
        .testTarget(name: "CapabilityPlaneUITests", dependencies: ["CapabilityPlane", "CapabilityPlaneUI"]),
    ]
)
