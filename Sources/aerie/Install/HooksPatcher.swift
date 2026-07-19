import Foundation

/// Merges/removes aerie hook entries in ~/.claude/settings.json.
/// The file already contains other tools' hooks (claude-rpc) on the same
/// events — we only ever append our own entry or remove entries whose command
/// contains "aerie hook ". Unknown keys are preserved verbatim.
enum HooksPatcher {
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "Stop", "SessionEnd",
    ]

    static func settingsPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static func hookEntry(binaryPath: String, event: String) -> [String: Any] {
        [
            "matcher": "",
            "hooks": [["type": "command", "command": "\(binaryPath) hook \(event)"]],
        ]
    }

    /// Returns true if the settings changed.
    @discardableResult
    static func install(binaryPath: String, settingsURL: URL? = nil, dryRun: Bool = false) throws -> Bool {
        let url = settingsURL ?? settingsPath()
        var root = try readSettings(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let already = entries.contains { entryIsOurs($0, binaryPath: binaryPath) }
            if !already {
                entries.append(hookEntry(binaryPath: binaryPath, event: event))
                hooks[event] = entries
                changed = true
                if dryRun { print("+ hooks.\(event): \(binaryPath) hook \(event)") }
            }
        }
        guard changed else { return false }
        root["hooks"] = hooks
        if !dryRun {
            try backup(url)
            try writeSettings(root, to: url)
        }
        return true
    }

    @discardableResult
    static func uninstall(binaryPath: String, settingsURL: URL? = nil, dryRun: Bool = false) throws -> Bool {
        let url = settingsURL ?? settingsPath()
        var root = try readSettings(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return false }
        var changed = false

        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryIsOurs($0, binaryPath: binaryPath) }
            if kept.count != entries.count {
                hooks[event] = kept.isEmpty ? nil : kept
                changed = true
                if dryRun { print("- hooks.\(event): aerie entry") }
            }
        }
        guard changed else { return false }
        root["hooks"] = hooks
        if !dryRun {
            try backup(url)
            try writeSettings(root, to: url)
        }
        return true
    }

    private static func entryIsOurs(_ entry: [String: Any], binaryPath: String) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { hook in
            guard let cmd = hook["command"] as? String else { return false }
            // Match any aerie binary path, so uninstall works after the
            // binary moved (e.g. dev build path vs installed path).
            return cmd.hasPrefix(binaryPath) || cmd.contains("aerie hook ")
        }
    }

    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func writeSettings(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent().appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let base = "settings.json.aerie-\(df.string(from: Date()))"
        var dest = dir.appendingPathComponent(base)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: dest)
    }
}
