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
    ///
    /// Replaces (not just appends-if-absent) any existing aerie entry per
    /// event: `entryIsOurs` matches on the generic "aerie hook " marker, not
    /// the exact binary path, so a stale entry from an older install (e.g.
    /// before switching from a dev build path to a Homebrew Cellar path)
    /// would otherwise be silently left pointing at a binary that may no
    /// longer exist — install must have run once at that old path, but
    /// re-running install alone (without an uninstall first) previously
    /// never corrected it.
    @discardableResult
    static func install(binaryPath: String, settingsURL: URL? = nil, dryRun: Bool = false) throws -> Bool {
        let url = settingsURL ?? settingsPath()
        var root = try readSettings(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in events {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let others = entries.filter { !entryIsOurs($0, binaryPath: binaryPath) }
            let newEntries = others + [hookEntry(binaryPath: binaryPath, event: event)]
            if !entriesEqual(entries, newEntries) {
                hooks[event] = newEntries
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

    /// Order-sensitive but key-order-insensitive comparison (values are all
    /// JSON-simple, so a sorted-keys round-trip is a reliable equality check).
    private static func entriesEqual(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        else { return false }
        return da == db
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
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "aerie", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(url.path) is not valid JSON — refusing to touch it"])
        }
        return obj
    }

    private static func writeSettings(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try ConfigWriter.writeThroughSymlinks(data, to: url)
    }

    // MARK: statusline wrapping (Claude usage tracking)

    /// Claude only surfaces quota via the statusLine command's stdin JSON, so
    /// usage tracking wraps whatever statusline the user has: their original
    /// command is preserved inside our `--chain` argument and restored
    /// verbatim on uninstall.
    enum StatuslinePatcher {
        static func install(binaryPath: String, settingsURL: URL? = nil) throws {
            let url = settingsURL ?? HooksPatcher.settingsPath()
            var root = try readRoot(url)
            let ours = "\(binaryPath) statusline"
            if let existing = root["statusLine"] as? [String: Any],
               let cmd = existing["command"] as? String {
                if cmd.contains(" statusline") { return }  // already ours
                // preserve the original inside --chain (single-quote safe)
                let escaped = cmd.replacingOccurrences(of: "'", with: "'\\''")
                root["statusLine"] = [
                    "type": "command",
                    "command": "\(ours) --chain '\(escaped)'",
                ]
            } else {
                root["statusLine"] = ["type": "command", "command": ours]
            }
            try HooksPatcher.backup(url)
            try write(root, to: url)
        }

        static func uninstall(settingsURL: URL? = nil) throws {
            let url = settingsURL ?? HooksPatcher.settingsPath()
            var root = try readRoot(url)
            guard let sl = root["statusLine"] as? [String: Any],
                  let cmd = sl["command"] as? String,
                  cmd.contains(" statusline") else { return }
            if let range = cmd.range(of: "--chain '"), cmd.hasSuffix("'") {
                // restore the original chained command
                var original = String(cmd[range.upperBound...].dropLast())
                original = original.replacingOccurrences(of: "'\\''", with: "'")
                root["statusLine"] = ["type": "command", "command": original]
            } else {
                root["statusLine"] = nil
            }
            try HooksPatcher.backup(url)
            try write(root, to: url)
        }

        private static func readRoot(_ url: URL) throws -> [String: Any] {
            guard let data = try? Data(contentsOf: url) else { return [:] }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "aerie", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(url.path) is not valid JSON — refusing to write"])
            }
            return obj
        }

        private static func write(_ root: [String: Any], to url: URL) throws {
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try ConfigWriter.writeThroughSymlinks(data, to: url)
        }
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
