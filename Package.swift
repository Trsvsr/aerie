// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Keep in sync with the deployment target in `platforms:` below — both must
// name the same OS version.
let deploymentTarget = "15.0"

// `swift build` links with `-target arm64-apple-macos15.0` (from the
// platforms declaration below) alongside `-sdk <active-sdk-path>`. On at
// least one beta toolchain (Xcode 27), the linker mis-stamps the binary's
// LC_BUILD_VERSION "sdk" field from the target triple's OS version (15.0)
// instead of the actual SDK's own version — even though the SDK path it's
// pointed at is correct. AppKit/SwiftUI gate automatic adoption of each
// year's new control appearance (e.g. Liquid Glass on macOS 26+) on that
// stamped SDK version, so a mis-stamped binary silently renders with a
// stale, pre-Tahoe look regardless of what OS or Xcode actually built it.
// A CI build with a non-beta Xcode stamps this correctly on its own; this
// forces the same correct value everywhere so local dev builds match.
func hostSDKVersion() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    task.arguments = ["--sdk", "macosx", "--show-sdk-version"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

let sdkVersionLinkerFlags: [String] = hostSDKVersion().map {
    ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", deploymentTarget, "-Xlinker", $0]
} ?? []

let package = Package(
    name: "aerie",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "aerie",
            path: "Sources/aerie",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(sdkVersionLinkerFlags)]
        ),
        .testTarget(
            name: "aerieTests",
            dependencies: ["aerie"],
            path: "Tests/aerieTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
