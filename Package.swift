// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SubOverlay",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
        .package(url: "https://github.com/huggingface/AnyLanguageModel", exact: "0.16.0"),
    ],
    targets: [
        .target(
            name: "SubOverlayCore",
            dependencies: [.product(name: "AnyLanguageModel", package: "AnyLanguageModel")]
        ),
        .executableTarget(
            name: "SubOverlay",
            dependencies: ["SubOverlayCore", "KeyboardShortcuts"]
        ),
        .testTarget(
            name: "SubOverlayCoreTests",
            dependencies: ["SubOverlayCore", .product(name: "AnyLanguageModel", package: "AnyLanguageModel")],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SubOverlayTests",
            dependencies: ["SubOverlay", "SubOverlayCore", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
