import Foundation

/// One NDJSON request per connection; the app replies with one NDJSON line
/// (immediately, or — for `approval` — when the user decides).
struct WireRequest: Codable {
    let cmd: String    // event | status | reset | ping | quit | approval | approval_resolve
    var sessionID: String?
    var event: String?
    var source: String?             // originating agent tool, e.g. "claude"
    var cwd: String?
    var toolName: String?
    var toolFile: String?
    var toolCommand: String?
    var toolDescription: String?
    var toolPattern: String?
    var toolURL: String?
    var notificationType: String?
    var message: String?
    var model: String?
    // approval request (cmd: "approval")
    var toolInputJSON: String?      // FULL tool_input, 8KiB clip — user must
                                    // see everything before approving
    var timeoutS: Int?
    var canAllow: Bool?             // false for tools where allow is unreliable
    // approval_resolve
    var approvalID: String?
    var decision: String?           // "allow" | "deny"
    // terminal identity (SessionStart) for jump
    var termProgram: String?
    var tmuxPane: String?
    var itermSession: String?
    var tty: String?

    enum CodingKeys: String, CodingKey {
        case cmd
        case sessionID = "session_id"
        case event
        case source
        case cwd
        case toolName = "tool_name"
        case toolFile = "tool_file"
        case toolCommand = "tool_command"
        case toolDescription = "tool_description"
        case toolPattern = "tool_pattern"
        case toolURL = "tool_url"
        case notificationType = "notification_type"
        case message
        case model
        case toolInputJSON = "tool_input_json"
        case timeoutS = "timeout_s"
        case canAllow = "can_allow"
        case approvalID = "approval_id"
        case decision
        case termProgram = "term_program"
        case tmuxPane = "tmux_pane"
        case itermSession = "iterm_session"
        case tty
    }
}

struct WireApprovalInfo: Codable {
    let id: String
    let sessionID: String
    let source: String
    let project: String
    let toolName: String?
    let toolInputJSON: String
    let expiresInS: Int
    let canAllow: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case source, project
        case toolName = "tool_name"
        case toolInputJSON = "tool_input_json"
        case expiresInS = "expires_in_s"
        case canAllow = "can_allow"
    }
}

struct WireSessionInfo: Codable {
    let id: String
    let project: String
    let source: String
    let model: String?
    let state: String
    let activity: String
    let ageSeconds: Int
    var terminal: String?    // debug/doctor: "iTerm2 %1 /dev/ttys002"

    enum CodingKeys: String, CodingKey {
        case id, project, source, model, state, activity, terminal
        case ageSeconds = "age_s"
    }
}

struct WireResponse: Codable {
    var ok: Bool
    var error: String?
    var aggregate: String?
    var summary: String?
    var sessions: [WireSessionInfo]?
    /// source → unix epoch of last event seen (doctor/health)
    var lastSeenBySource: [String: Double]?
    /// approval reply: "allow" | "deny" | "none"; also the id on submit
    var decision: String?
    var approvalID: String?
    var approvals: [WireApprovalInfo]?
    var version: String?

    enum CodingKeys: String, CodingKey {
        case ok, error, aggregate, summary, sessions, version, decision, approvals
        case lastSeenBySource = "last_seen_by_source"
        case approvalID = "approval_id"
    }
}

// Bump this alongside every `git tag vX.Y.Z` — it drifted from actual
// releases before (stuck at 0.1.0 through the v0.1.1/v0.1.2 cuts) with
// nothing to catch it; `aerie doctor`'s update check now depends on this
// being accurate.
let aerieVersion = "0.1.4"

func aerieDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aerie")
}

/// Create ~/.aerie owner-only; tighten pre-existing dirs too. Payload
/// snapshots and logs land here — no reason for group/other access.
func ensurePrivateAerieDirectory() {
    let dir = aerieDirectory()
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: dir.path)
}

func socketPath() -> String {
    aerieDirectory().appendingPathComponent("daemon.sock").path
}

func log(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let url = aerieDirectory().appendingPathComponent("aerie.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        ensurePrivateAerieDirectory()
        try? Data(line.utf8).write(to: url)
    }
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
}
