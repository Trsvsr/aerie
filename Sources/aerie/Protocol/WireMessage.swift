import Foundation

/// One NDJSON request per connection; the app replies with one NDJSON line.
struct WireRequest: Codable {
    let cmd: String                 // event | status | reset | ping | quit
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

    enum CodingKeys: String, CodingKey {
        case id, project, source, model, state, activity
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
    var version: String?

    enum CodingKeys: String, CodingKey {
        case ok, error, aggregate, summary, sessions, version
        case lastSeenBySource = "last_seen_by_source"
    }
}

let aerieVersion = "0.1.0"

func aerieDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aerie")
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
        try? FileManager.default.createDirectory(at: aerieDirectory(), withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: url)
    }
}
