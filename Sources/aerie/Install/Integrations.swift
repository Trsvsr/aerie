import Foundation

/// Per-tool hook integrations beyond Claude Code (which HooksPatcher owns).
/// Each integration knows how to detect the tool, whether aerie hooks are
/// installed, and how to install/remove them idempotently.
enum ToolIntegration: String, CaseIterable {
    case claude
    case codex
    case antigravity
    case cursor
    case opencode
    case pi

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .antigravity: return "Antigravity CLI"
        case .cursor: return "Cursor"
        case .opencode: return "opencode"
        case .pi: return "Pi"
        }
    }

    /// How the integration installs: merged into a JSON hooks config, or a
    /// generated script file dropped into the tool's plugin/extension dir.
    var installsAsScript: Bool {
        self == .opencode || self == .pi
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
        // Generated plugin/extension files (script-based installs).
        case .opencode: return Self.home.appendingPathComponent(".config/opencode/plugins/aerie.js")
        case .pi: return Self.home.appendingPathComponent(".pi/agent/extensions/aerie-status.ts")
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
        case .opencode:
            return binaryOnPath("opencode")
                || FileManager.default.fileExists(
                    atPath: Self.home.appendingPathComponent(".config/opencode").path)
        case .pi:
            return binaryOnPath("pi")
                || FileManager.default.fileExists(
                    atPath: Self.home.appendingPathComponent(".pi/agent").path)
        }
    }

    /// Are aerie hooks currently present in the tool's config?
    var isInstalled: Bool {
        if installsAsScript {
            // whole file is ours; presence = installed
            return FileManager.default.fileExists(atPath: configURL.path)
        }
        guard let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("aerie hook ")
    }

    /// Event mapping: tool's hook event name → (aerie event, extra CLI flags).
    /// Codex/Cursor payloads are Claude-hook-shaped (Cursor documents Claude
    /// compat explicitly); Antigravity nests tool args differently, which
    /// HookCommand handles with fallback field parsing. One stdin parser
    /// serves everyone — only the source tag and forced types differ.
    var eventMap: [(toolEvent: String, aerieEvent: String, extraFlags: String)] {
        switch self {
        case .claude:
            return [] // handled by HooksPatcher during `aerie install`
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
        case .opencode, .pi:
            return [] // script-based: the generated plugin maps events itself
        }
    }

    /// Cursor's hooks.json is a flat schema (`{"version":1,"hooks":{event:
    /// [{command}]}}`); the others nest a hooks array per entry.
    private var usesFlatEntries: Bool { self == .cursor }

    /// Tools where the notch can decide permissions via a blocking hook.
    var supportsApproval: Bool {
        self == .claude || self == .codex || self == .cursor
    }

    /// The (tool event, matcher-or-nil) the blocking approval hook rides on.
    private var approvalEvent: (event: String, matcher: String?)? {
        switch self {
        case .claude:
            // PreToolUse fires for EVERY matched call — scope the matcher to
            // permission-prone tools so allowlisted reads don't detour.
            return ("PreToolUse", "Bash|Write|Edit|MultiEdit|NotebookEdit")
        case .codex: return ("PermissionRequest", nil)
        case .cursor: return ("beforeShellExecution", nil)
        default: return nil
        }
    }

    var approvalInstalled: Bool {
        guard let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("--approve")
    }

    /// Install the blocking approval hook entry (separate from status hooks;
    /// independently removable). Returns true if changed.
    @discardableResult
    func installApproval(binaryPath: String) throws -> Bool {
        guard let (event, matcher) = approvalEvent else { return false }
        var root = try readJSON(configURL.deletingLastPathComponent()
            .appendingPathComponent(configURL.lastPathComponent))
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var entries = hooks[event] as? [[String: Any]] ?? []
        guard !entries.contains(where: { entryText($0).contains("--approve") }) else { return false }

        let command = "\(binaryPath) hook \(event) --approve --source \(rawValue)"
        if usesFlatEntries {
            entries.append(["command": command, "timeout": 60])
        } else {
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": 60]]
            ]
            if let matcher { entry["matcher"] = matcher }
            entries.append(entry)
        }
        hooks[event] = entries
        root["hooks"] = hooks
        if usesFlatEntries, root["version"] == nil { root["version"] = 1 }
        try writeJSON(root, to: configURL)
        return true
    }

    @discardableResult
    func uninstallApproval(binaryPath: String) throws -> Bool {
        var root = try readJSON(configURL)
        guard var hooks = root["hooks"] as? [String: Any] else { return false }
        var changed = false
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryText($0).contains("--approve") }
            if kept.count != entries.count {
                hooks[event] = kept.isEmpty ? nil : kept
                changed = true
            }
        }
        guard changed else { return false }
        root["hooks"] = hooks
        try writeJSON(root, to: configURL)
        return true
    }

    private func entryText(_ entry: [String: Any]) -> String {
        if let cmd = entry["command"] as? String { return cmd }
        guard let inner = entry["hooks"] as? [[String: Any]] else { return "" }
        return inner.compactMap { $0["command"] as? String }.joined(separator: " ")
    }

    /// Install aerie hook entries into the tool's JSON config (merge,
    /// append-only, existing entries preserved), or write the generated
    /// plugin/extension script for script-based tools. Returns true if changed.
    @discardableResult
    func install(binaryPath: String) throws -> Bool {
        guard self != .claude else {
            return try HooksPatcher.install(binaryPath: binaryPath)
        }
        if installsAsScript {
            let script = scriptContents(binaryPath: binaryPath)
            if let existing = try? String(contentsOf: configURL, encoding: .utf8),
               existing == script {
                return false
            }
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: configURL, atomically: true, encoding: .utf8)
            return true
        }
        var root = try readJSON(configURL)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for (toolEvent, aerieEvent, flags) in eventMap {
            var entries = hooks[toolEvent] as? [[String: Any]] ?? []
            let command = "\(binaryPath) hook \(aerieEvent) --source \(rawValue)\(flags)"
            let already = entries.contains { entryContainsAerie($0) }
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

    /// Remove aerie entries from the tool's config. Returns true if changed.
    @discardableResult
    func uninstall(binaryPath: String) throws -> Bool {
        guard self != .claude else {
            return try HooksPatcher.uninstall(binaryPath: binaryPath)
        }
        if installsAsScript {
            guard FileManager.default.fileExists(atPath: configURL.path) else { return false }
            try FileManager.default.removeItem(at: configURL)
            return true
        }
        var root = try readJSON(configURL)
        guard var hooks = root["hooks"] as? [String: Any] else { return false }
        var changed = false
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryContainsAerie($0) }
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

    /// Generated plugin/extension source for script-based integrations.
    /// Both funnel tool events into the same `aerie hook` stdin contract the
    /// JSON-config tools use, with fields renamed to Claude-hook shape.
    func scriptContents(binaryPath: String) -> String {
        switch self {
        case .opencode:
            return """
            // Generated by `aerie install` — do not edit (regenerated on install).
            // Forwards opencode session/tool/permission events to the aerie notch HUD.
            export const AeriePlugin = async ({ directory }) => {
              const notify = (hookEvent, payload, extra = []) => {
                try {
                  const proc = Bun.spawn(
                    [\(jsString(binaryPath)), "hook", hookEvent, "--source", "opencode", ...extra],
                    { stdin: "pipe", stdout: "ignore", stderr: "ignore" });
                  proc.stdin.write(JSON.stringify(payload));
                  proc.stdin.end();
                  // fire-and-forget: never block opencode's event loop
                } catch {}
              };
              return {
                event: async ({ event }) => {
                  const p = event.properties;
                  switch (event.type) {
                    case "session.created":
                      // subagent sessions carry parentID — skip, parent covers them
                      if (!p.info.parentID)
                        notify("SessionStart", { session_id: p.info.id, cwd: p.info.directory });
                      break;
                    case "session.status":
                      // busy = model is working even before any tool call
                      if (p.status?.type === "busy")
                        notify("UserPromptSubmit", { session_id: p.sessionID, cwd: directory });
                      break;
                    case "session.idle":
                      notify("Stop", { session_id: p.sessionID, cwd: directory });
                      break;
                    case "session.deleted":
                      notify("SessionEnd", { session_id: p.info.id });
                      break;
                    case "permission.updated":
                      notify("Notification",
                        { session_id: p.sessionID, cwd: directory, message: p.title },
                        ["--notification-type", "permission_prompt"]);
                      break;
                    case "message.part.updated": {
                      const part = p.part;
                      if (part.type !== "tool") break;
                      if (part.state.status === "running")
                        notify("PreToolUse", {
                          session_id: part.sessionID, cwd: directory,
                          tool_name: part.tool, tool_input: part.state.input ?? {},
                        });
                      else if (part.state.status === "completed")
                        notify("PostToolUse",
                          { session_id: part.sessionID, cwd: directory, tool_name: part.tool });
                      break;
                    }
                  }
                },
              };
            };
            """
        case .pi:
            return """
            // Generated by `aerie install` — do not edit (regenerated on install).
            // Forwards Pi session/tool events to the aerie notch HUD.
            import { spawn } from "node:child_process";

            export default function (pi) {
              let sessionId = null;
              const notify = (hookEvent, payload, extra = []) => {
                try {
                  const proc = spawn(
                    \(jsString(binaryPath)),
                    ["hook", hookEvent, "--source", "pi", ...extra],
                    { stdio: ["pipe", "ignore", "ignore"] });
                  proc.stdin.write(JSON.stringify(payload));
                  proc.stdin.end();
                  proc.unref(); // fire-and-forget
                } catch {}
              };
              const sid = (ctx) => {
                try { sessionId = ctx?.sessionManager?.getSessionId() ?? sessionId; } catch {}
                return sessionId ?? "pi-unknown";
              };

              pi.on("session_start", async (event, ctx) => {
                notify("SessionStart", { session_id: sid(ctx), cwd: ctx?.cwd });
              });
              pi.on("tool_call", async (event, ctx) => {
                notify("PreToolUse", {
                  session_id: sid(ctx), cwd: ctx?.cwd,
                  tool_name: event.toolName, tool_input: event.input ?? {},
                });
              });
              pi.on("tool_result", async (event, ctx) => {
                notify("PostToolUse",
                  { session_id: sid(ctx), cwd: ctx?.cwd, tool_name: event.toolName });
              });
              pi.on("agent_settled", async (event, ctx) => {
                notify("Stop", { session_id: sid(ctx), cwd: ctx?.cwd });
              });
              pi.on("session_shutdown", async (event, ctx) => {
                notify("SessionEnd", { session_id: sid(ctx) });
              });
            }
            """
        default:
            return "" // JSON-config tools never call this
        }
    }

    /// JS string literal with escaping for embedding paths.
    private func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: helpers

    private func entryContainsAerie(_ entry: [String: Any]) -> Bool {
        // flat schema (Cursor): command at top level
        if let cmd = entry["command"] as? String, cmd.contains("aerie hook ") {
            return true
        }
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains {
            ($0["command"] as? String)?.contains("aerie hook ") == true
        }
    }

    enum ConfigError: LocalizedError {
        case unreadable(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let p): return "cannot read \(p)"
            case .malformed(let p):
                return "\(p) is not valid JSON — fix or move it, then retry (aerie will not overwrite it)"
            }
        }
    }

    /// Missing file → empty config (fresh install). Unreadable or malformed
    /// file → throw: silently treating a broken config as empty would make
    /// install() overwrite the user's real configuration.
    private func readJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else {
            throw ConfigError.unreadable(url.path)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw ConfigError.malformed(url.path)
        }
        return dict
    }

    private func writeJSON(_ root: [String: Any], to url: URL) throws {
        ConfigWriter.backup(url, label: "aerie")
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try ConfigWriter.writeThroughSymlinks(data, to: url)
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
