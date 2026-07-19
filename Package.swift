// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "aerie",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "aerie",
            path: "Sources/aerie",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "aerieTests",
            dependencies: ["aerie"],
            path: "Tests/aerieTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
