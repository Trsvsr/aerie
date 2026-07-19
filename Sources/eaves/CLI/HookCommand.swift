import Foundation

/// `eaves hook <EventName>` — invoked by Claude Code hooks. Reads the hook
/// JSON from stdin, forwards a compact event to the app, and exits 0 no
/// matter what: a broken app must never block Claude Code.
enum HookCommand {
    static let fieldLimit = 250

    /// argv shape: eaves hook <Event> [--source claude|codex|gemini]
    ///             [--notification-type T]
    /// Payloads from all supported tools are Claude-hook-shaped (session_id,
    /// cwd, tool_name, tool_input, …), so one parser serves everyone.
    static func run(args: [String]) {
        let eventFromArgv = args.first(where: { !$0.hasPrefix("--") })
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let source = flag("--source") ?? "claude"
        let forcedNotificationType = flag("--notification-type")

        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              // Cursor sends conversation_id instead of session_id
              let sessionID = obj["session_id"] as? String
                ?? obj["conversation_id"] as? String,
              let event = eventFromArgv ?? obj["hook_event_name"] as? String
        else { exit(0) }

        func clip(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return String(s.prefix(fieldLimit))
        }

        var toolInput = obj["tool_input"] as? [String: Any]
        var toolName = obj["tool_name"] as? String
        // Antigravity nests args under toolCall
        if let toolCall = obj["toolCall"] as? [String: Any] {
            let args = toolCall["args"] as? [String: Any]
            toolName = toolName ?? toolCall["name"] as? String ?? args?["ToolName"] as? String
            if toolInput == nil, let args {
                toolInput = [
                    "command": args["CommandLine"] as Any,
                    "file_path": args["FilePath"] as Any,
                ]
            }
        }
        // Cursor sends workspace_roots instead of cwd on some events
        let cwd = obj["cwd"] as? String
            ?? (obj["workspace_roots"] as? [String])?.first
        var notificationType = forcedNotificationType ?? obj["notification_type"] as? String
        let message = obj["message"] as? String
        // Some payloads only carry the reason in `message`; sniff as a
        // fallback — but keep idle phrasing distinct from permission
        // phrasing, they drive very different UI (red pulse vs calm idle).
        if notificationType == nil, event == "Notification", let msg = message {
            let m = msg.lowercased()
            if m.contains("permission") {
                notificationType = "permission_prompt"
            } else if m.contains("waiting for your input") || m.contains("is waiting") {
                notificationType = "idle_prompt"
            }
        }

        let req = WireRequest(
            cmd: "event",
            sessionID: sessionID,
            event: event,
            source: source,
            cwd: clip(cwd),
            toolName: clip(toolName),
            toolFile: clip(toolInput?["file_path"] as? String
                ?? toolInput?["notebook_path"] as? String),
            toolCommand: clip(toolInput?["command"] as? String),
            toolDescription: clip(toolInput?["description"] as? String),
            toolPattern: clip(toolInput?["pattern"] as? String
                ?? toolInput?["query"] as? String),
            toolURL: clip(toolInput?["url"] as? String),
            notificationType: notificationType,
            message: clip(message)
        )
        _ = try? SocketClient.request(req, timeoutMS: 150)
        exit(0)
    }
}
