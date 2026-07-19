import Foundation

enum LaunchAgent {
    static let label = "com.trevor.eaves"

    static func plistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func plistContents(binaryPath: String) -> String {
        let logPath = eavesDirectory().appendingPathComponent("eaves.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>app</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            <dict><key>SuccessfulExit</key><false/></dict>
            <key>ProcessType</key><string>Interactive</string>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
            <key>StandardOutPath</key><string>\(logPath)</string>
            <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    static func install(binaryPath: String) throws {
        try FileManager.default.createDirectory(at: eavesDirectory(), withIntermediateDirectories: true)
        let url = plistURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // bootout first so re-install picks up plist changes
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try plistContents(binaryPath: binaryPath).write(to: url, atomically: true, encoding: .utf8)
        let result = runLaunchctl(["bootstrap", "gui/\(getuid())", url.path])
        guard result == 0 else {
            throw NSError(domain: "eaves", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed (\(result))"])
        }
    }

    static func uninstall() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL())
    }

    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
