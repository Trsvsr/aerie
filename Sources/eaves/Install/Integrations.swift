import Foundation

/// Per-tool hook integrations beyond Claude Code (which HooksPatcher owns).
/// Each integration knows how to detect the tool, whether eaves hooks are
/// installed, and how to install/remove them idempotently.
enum ToolIntegration: String, CaseIterable {
    case claude
    case codex
    case antigravity
    case cursor

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .antigravity: return "Antigravity CLI"
        case .cursor: return "Cursor"
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Config file the integration writes into.
    var configURL: URL {
        switch self {
        case .claude: return Self.home.appendingPathComponent(".claude/settings.json")
        case .codex: return Self.home.appendingPathComponent(".codex/hooks.json")
        // Antigravity CLI (`agy`, successor to Gemini CLI mid-2026); global
        // hooks path per current docs — verify with `agy inspect` if it moves.
        case .antigravity: return Self.home.appendingPathComponent(".gemini/antigravity-cli/hooks.json")
        // Shared by the Cursor IDE and cursor-agent CLI (same schema).
        case .cursor: return Self.home.appendingPathComponent(".cursor/hooks.json")
        }
    }

    /// Is the tool present on this machine? (binary on PATH or config dir)
    var isDetected: Bool {
        switch self {
        case .claude:
            return FileManager.default.fileExists(
                atPath: Self.home.appendingPathComponent(".claude").path)
        case .codex:
            return binaryOnPath("codex")
                || FileManager.default.fileExists(
                    atPath: Self.home.appendingPathComponent(".codex").path)
        case .antigravity:
            return binaryOnPath("agy")
                || FileManager.default.fileExists(
                    atPath: Self.home.appendingPathComponent(".gemini/antigravity-cli").path)
        case .cursor:
            return binaryOnPath("cursor-agent") || binaryOnPath("cursor")
                || FileManager.default.fileExists(
                    atPath: Self.home.appendingPathComponent(".cursor").path)
        }
    }

    /// Are eaves hooks currently present in the tool's config?
    var isInstalled: Bool {
        guard let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("eaves hook ")
    }

    /// Event mapping: tool's hook event name → (eaves event, extra CLI flags).
    /// Codex/Cursor payloads are Claude-hook-shaped (Cursor documents Claude
    /// compat explicitly); Antigravity nests tool args differently, which
    /// HookCommand handles with fallback field parsing. One stdin parser
    /// serves everyone — only the source tag and forced types differ.
    var eventMap: [(toolEvent: String, eavesEvent: String, extraFlags: String)] {
        switch self {
        case .claude:
            return [] // handled by HooksPatcher during `eaves install`
        case .codex:
            return [
                ("SessionStart", "SessionStart", ""),
                ("UserPromptSubmit", "UserPromptSubmit", ""),
                ("PreToolUse", "PreToolUse", ""),
                ("PostToolUse", "PostToolUse", ""),
                ("PermissionRequest", "Notification", " --notification-type permission_prompt"),
                ("Stop", "Stop", ""),
            ]
        case .antigravity:
            // Confirmed initial event set; no session lifecycle events yet —
            // sessions appear on first PreToolUse and get reaped by TTL.
            return [
                ("PreToolUse", "PreToolUse", ""),
                ("PostToolUse", "PostToolUse", ""),
                ("Stop", "Stop", ""),
            ]
        case .cursor:
            // Events that fire in both the IDE and cursor-agent (CLI verified
            // reliable since ~2026.04).
            return [
                ("sessionStart", "SessionStart", ""),
                ("preToolUse", "PreToolUse", ""),
                ("postToolUse", "PostToolUse", ""),
                ("stop", "Stop", ""),
                ("sessionEnd", "SessionEnd", ""),
            ]
        }
    }

    /// Cursor's hooks.json is a flat schema (`{"version":1,"hooks":{event:
    /// [{command}]}}`); the others nest a hooks array per entry.
    private var usesFlatEntries: Bool { self == .cursor }

    /// Install eaves hook entries into the tool's JSON config (merge,
    /// append-only, existing entries preserved). Returns true if changed.
    @discardableResult
    func install(binaryPath: String) throws -> Bool {
        guard self != .claude else {
            return try HooksPatcher.install(binaryPath: binaryPath)
        }
        var root = readJSON(configURL)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for (toolEvent, eavesEvent, flags) in eventMap {
            var entries = hooks[toolEvent] as? [[String: Any]] ?? []
            let command = "\(binaryPath) hook \(eavesEvent) --source \(rawValue)\(flags)"
            let already = entries.contains { entryContainsEaves($0) }
            if !already {
                if usesFlatEntries {
                    entries.append(["command": command])
                } else {
                    entries.append([
                        "hooks": [["type": "command", "command": command]]
                    ])
                }
                hooks[toolEvent] = entries
                changed = true
            }
        }
        guard changed else { return false }
        root["hooks"] = hooks
        if usesFlatEntries, root["version"] == nil { root["version"] = 1 }
        try writeJSON(root, to: configURL)
        return true
    }

    /// Remove eaves entries from the tool's config. Returns true if changed.
    @discardableResult
    func uninstall(binaryPath: String) throws -> Bool {
        guard self != .claude else {
            return try HooksPatcher.uninstall(binaryPath: binaryPath)
        }
        var root = readJSON(configURL)
        guard var hooks = root["hooks"] as? [String: Any] else { return false }
        var changed = false
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryContainsEaves($0) }
            if kept.count != entries.count {
                hooks[event] = kept.isEmpty ? nil : kept
                changed = true
            }
        }
        guard changed else { return false }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSON(root, to: configURL)
        return true
    }

    // MARK: helpers

    private func entryContainsEaves(_ entry: [String: Any]) -> Bool {
        // flat schema (Cursor): command at top level
        if let cmd = entry["command"] as? String, cmd.contains("eaves hook ") {
            return true
        }
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains {
            ($0["command"] as? String)?.contains("eaves hook ") == true
        }
    }

    private func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func writeJSON(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // timestamped backup alongside, mirroring HooksPatcher's habit
        if FileManager.default.fileExists(atPath: url.path) {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).eaves-backup-\(df.string(from: Date()))")
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func binaryOnPath(_ name: String) -> Bool {
        let candidates = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(Self.home.path)/.local/bin", "\(Self.home.path)/bin",
        ]
        return candidates.contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
        }
    }
}
