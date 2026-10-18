// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AppleLingo",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
        .package(url: "https://github.com/huggingface/AnyLanguageModel", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AppleLingoCore",
            dependencies: [.product(name: "AnyLanguageModel", package: "AnyLanguageModel")]
        ),
        .executableTarget(
            name: "AppleLingo",
            dependencies: ["AppleLingoCore", "KeyboardShortcuts"]
        ),
        .testTarget(
            name: "AppleLingoCoreTests",
            dependencies: ["AppleLingoCore", .product(name: "AnyLanguageModel", package: "AnyLanguageModel")],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AppleLingoTests",
            dependencies: ["AppleLingo", "AppleLingoCore", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
