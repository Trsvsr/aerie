import Foundation

/// tool_name + tool_input fragments → short human activity line.
enum ActivityFormatter {
    static func format(
        toolName: String?, file: String?, command: String?,
        description: String?, pattern: String?, url: String?
    ) -> String {
        guard let tool = toolName, !tool.isEmpty else { return "working" }

        func basename(_ p: String) -> String { (p as NSString).lastPathComponent }

        // Tool vocabularies: Claude Code (PascalCase), Codex (shell,
        // apply_patch, …), Gemini CLI (snake_case run_shell_command, …).
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch", "edit", "replace":
            if let f = file { return "editing \(basename(f))" }
            return "editing"
        case "Write", "write_file":
            if let f = file { return "writing \(basename(f))" }
            return "writing"
        case "Read", "read_file", "read_many_files":
            if let f = file { return "reading \(basename(f))" }
            return "reading"
        case "Bash", "shell", "local_shell", "run_shell_command", "run_command", "run_terminal_cmd":
            // generous caps — the expanded view wraps to two lines; the
            // collapsed summary truncates separately at render time
            if let d = description, !d.isEmpty { return "running: \(oneLine(d, max: 120))" }
            if let c = command, !c.isEmpty { return "running: \(oneLine(c, max: 120))" }
            return "running command"
        case "Grep", "Glob", "grep", "glob", "search_file_content", "find_files":
            if let p = pattern, !p.isEmpty { return "searching \(oneLine(p, max: 60))" }
            return "searching"
        case "WebFetch", "web_fetch", "fetch":
            if let u = url, let host = URL(string: u)?.host { return "fetching \(host)" }
            return "fetching web page"
        case "WebSearch", "web_search", "google_web_search":
            return "searching web"
        case "Task", "Agent", "spawn_agent":
            if let d = description, !d.isEmpty { return "agent: \(oneLine(d, max: 100))" }
            return "running agent"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "update_plan", "save_memory":
            return "updating plan"
        default:
            // mcp__server__tool → "tool (server)"
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    let server = parts[1]
                    let name = parts.dropFirst(2).joined(separator: "_")
                    return "\(name) (\(server))"
                }
            }
            return "using \(tool)"
        }
    }

    /// Line for needsInput state; pulls the tool name out of Claude's
    /// permission message ("Claude needs your permission to use Bash").
    static func needsInputLine(message: String?) -> String {
        guard let msg = message, !msg.isEmpty else { return "needs input" }
        if let range = msg.range(of: "permission to use ") {
            let tool = msg[range.upperBound...]
                .prefix(while: { !$0.isWhitespace && $0 != "." && $0 != "," })
            if !tool.isEmpty { return "needs permission: \(tool)" }
        }
        if msg.lowercased().contains("permission") { return "needs permission" }
        if msg.lowercased().contains("waiting for your input") { return "waiting for you" }
        return "needs input"
    }

    /// Collapse whitespace/newlines and middle-truncate to `max` characters.
    static func oneLine(_ s: String, max: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return truncate(flat, max: max)
    }

    /// Middle-ellipsis truncation shared by collapsed and expanded renderings.
    static func truncate(_ s: String, max: Int) -> String {
        guard s.count > max, max > 1 else { return s }
        let head = (max - 1) * 2 / 3
        let tail = max - 1 - head
        return "\(s.prefix(head))…\(s.suffix(tail))"
    }
}
