import Foundation

/// `aerie hook <Event> --approve --source <tool>` — the ONE hook path that
/// may block: it asks the notch for a permission decision and waits.
///
/// Fail-open invariant: every failure mode (app down, timeout, malformed
/// payload, user ignores) exits 0 with NO stdout → the tool's normal
/// terminal prompt takes over. We never break an agent by being absent.
enum ApprovalHook {
    static let toolInputLimit = 8 * 1024
    /// Hook-side read timeout. Ladder: server auto-none 50s < this 55s <
    /// hook-entry timeout in tool config 60s.
    static let readTimeoutMS = 55_000

    static func run(source: String, stdin: Data) -> Never {
        guard let obj = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let sessionID = obj["session_id"] as? String
                ?? obj["conversation_id"] as? String
        else { exit(0) }

        // Fast-exit: modes that never prompt shouldn't detour through us.
        // "auto" is Claude Code's Auto Mode — it never shows the user a real
        // permission prompt, so blocking on the notch here just adds a stall
        // that fails open after readTimeoutMS with no actual decision made.
        if let mode = obj["permission_mode"] as? String,
           ["bypassPermissions", "dontAsk", "auto"].contains(mode) {
            exit(0)
        }

        let toolName = obj["tool_name"] as? String
        let toolInput = obj["tool_input"] as? [String: Any]
        let command = toolInput?["command"] as? String
            ?? obj["command"] as? String   // cursor beforeShellExecution

        // Fast-exit: Claude allowlist mirror — if settings would auto-allow,
        // don't add notch latency. A miss is safe (user just gets asked).
        if source == "claude",
           AllowlistMirror.isAllowed(tool: toolName, command: command,
                                     cwd: obj["cwd"] as? String) {
            exit(0)
        }

        let inputJSON: String
        if let toolInput,
           let data = try? JSONSerialization.data(
               withJSONObject: toolInput, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            inputJSON = String(s.prefix(toolInputLimit))
        } else if let command {
            inputJSON = String(command.prefix(toolInputLimit))
        } else {
            inputJSON = "(no input details)"
        }

        let req = WireRequest(
            cmd: "approval",
            sessionID: sessionID,
            source: source,
            cwd: obj["cwd"] as? String
                ?? (obj["workspace_roots"] as? [String])?.first,
            toolName: toolName,
            toolCommand: command.map { String($0.prefix(250)) },
            toolInputJSON: inputJSON,
            timeoutS: 50,
            canAllow: source != "cursor")

        let decision: String
        do {
            let resp = try SocketClient.request(
                req, sendTimeoutMS: 150, readTimeoutMS: readTimeoutMS)
            decision = resp.decision ?? "none"
        } catch {
            decision = "none"   // app down / parked read timed out → terminal
        }

        if let output = decisionOutput(source: source, decision: decision) {
            print(output)
        }
        exit(0)
    }

    /// Map the notch decision to each tool's hook-output schema.
    /// nil = emit nothing → the tool's own prompt flow continues (fail-open).
    static func decisionOutput(source: String, decision: String) -> String? {
        switch (source, decision) {
        case ("claude", "allow"):
            return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"approved in aerie"}}"#
        case ("claude", "deny"):
            return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"denied in aerie"}}"#
        case ("codex", "allow"):
            return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case ("codex", "deny"):
            return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in aerie."}}}"#
        case ("cursor", "deny"):
            return #"{"permission":"deny","userMessage":"Denied in aerie."}"#
        default:
            return nil   // none, or cursor allow (unreliable — let cursor ask)
        }
    }
}

/// Best-effort mirror of Claude Code's `permissions.allow` rules: if the
/// call would be auto-allowed anyway, skip the notch entirely. Conservative
/// by design — anything not clearly allowed falls through to the notch.
enum AllowlistMirror {
    static func isAllowed(tool: String?, command: String?, cwd: String?) -> Bool {
        guard let tool else { return false }
        var rules: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "\(home)/.claude/settings.json",
            "\(home)/.claude/settings.local.json",
        ]
        if let cwd {
            paths.append("\(cwd)/.claude/settings.json")
            paths.append("\(cwd)/.claude/settings.local.json")
        }
        for p in paths {
            guard let data = FileManager.default.contents(atPath: p),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let perms = obj["permissions"] as? [String: Any],
                  let allow = perms["allow"] as? [String] else { continue }
            rules.append(contentsOf: allow)
        }
        return rules.contains { matches(rule: $0, tool: tool, command: command) }
    }

    /// Supported rule shapes: "Tool", "Tool(*)", "Bash(prefix:*)",
    /// "Bash(exact command)". Everything else → no match (conservative).
    static func matches(rule: String, tool: String, command: String?) -> Bool {
        if rule == tool { return true }
        guard rule.hasPrefix("\(tool)("), rule.hasSuffix(")") else { return false }
        let inner = String(rule.dropFirst(tool.count + 1).dropLast())
        if inner == "*" { return true }
        guard let command else { return false }
        if inner.hasSuffix(":*") {
            let prefix = String(inner.dropLast(2))
            return command == prefix || command.hasPrefix(prefix + " ")
        }
        return command == inner
    }
}
