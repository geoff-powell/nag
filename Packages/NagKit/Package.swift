// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NagKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NagCore", targets: ["NagCore"]),
        .library(name: "NagKit", targets: ["NagKit"]),
    ],
    targets: [
        // Platform-independent rules: models, nag planning, unlock requirements, storage, sync merging.
        .target(name: "NagCore"),
        // Apple framework glue: notifications and iCloud sync on both platforms, Screen Time on iOS.
        .target(name: "NagKit", dependencies: ["NagCore"]),
        .testTarget(name: "NagCoreTests", dependencies: ["NagCore"]),
    ]
)
