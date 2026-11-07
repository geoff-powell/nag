// swift-tools-version: 6.0
// Minimal Swift consumer of the KMP prototype (#41). Build the XCFramework first:
//   (cd kmp && ./gradlew :nag-rules:assembleNagRulesReleaseXCFramework)
import PackageDescription

let package = Package(
    name: "NagRulesConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The current Swift core, so the prototype can be compared against it directly.
        .package(path: "../../../Packages/NagKit"),
    ],
    targets: [
        .binaryTarget(
            name: "NagRules",
            path: "NagRules.xcframework"
        ),
        .executableTarget(
            name: "NagRulesConsumer",
            dependencies: [
                "NagRules",
                .product(name: "NagCore", package: "NagKit"),
            ]
        ),
    ]
)
