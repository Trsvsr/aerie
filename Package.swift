// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "eaves",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "eaves",
            path: "Sources/eaves",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "eavesTests",
            dependencies: ["eaves"],
            path: "Tests/eavesTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
