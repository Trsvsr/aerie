import Foundation

enum SessionState: String, Codable, Comparable {
    case idle
    case working
    case needsInput

    private var rank: Int {
        switch self {
        case .idle: return 0
        case .working: return 1
        case .needsInput: return 2
        }
    }

    static func < (lhs: SessionState, rhs: SessionState) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Aggregate state for the whole machine.
enum AggregateState: String, Codable {
    case off        // no live sessions worth showing
    case working
    case needsInput
}

/// Immutable per-session row handed to the UI / status command.
struct SessionRow: Identifiable, Equatable, Sendable {
    let id: String
    let project: String
    let source: String          // originating tool ("claude", …)
    let model: String?          // short display name, e.g. "fable-5"
    let state: SessionState
    let activity: String
    let lastEvent: Date
    let firstEvent: Date
}

/// A finished session, kept briefly for the "recent" panel section.
/// Summary only — no commands, prompts, or transcripts.
struct RecentSession: Identifiable, Equatable, Sendable {
    let id: String
    let project: String
    let source: String
    let model: String?
    let endedAt: Date
    let duration: TimeInterval
    let finalActivity: String
}

/// Pure per-session state machine + aggregation. No I/O; clock injected for tests.
final class SessionStore {
    struct Session {
        var state: SessionState
        var lastEvent: Date
        var firstEvent: Date
        var cwd: String?
        var activity: String
        var source: String = "claude"
        var model: String?
    }

    /// "claude-fable-5" → "fable-5", "gpt-5.2-codex" stays, strip dates.
    static func shortModelName(_ raw: String) -> String {
        var s = raw
        for prefix in ["claude-", "models/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        // trailing -YYYYMMDD date stamp
        if let r = s.range(of: #"-20\d{6}$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        return s
    }

    struct TTLs {
        var working: TimeInterval = 15 * 60
        var needsInput: TimeInterval = 2 * 60 * 60
        var idle: TimeInterval = 60 * 60
    }

    private(set) var sessions: [String: Session] = [:]
    /// Newest-first ring of ended sessions (SessionEnd or working→idle
    /// completion), capped at `recentsCap`.
    private(set) var recents: [RecentSession] = []
    var recentsCap = 20
    /// Timestamp of the last event seen per source — integration health.
    private(set) var lastSeenBySource: [String: Date] = [:]
    var ttls = TTLs()
    let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Notification types that mean the agent is genuinely blocked on the
    /// user (permission dialogs etc.) — these pulse red. Idle notifications
    /// ("Claude is waiting for your input" after a finished turn) are NOT
    /// here: finished-and-idle isn't an emergency and shouldn't flash.
    static let needsInputNotifications: Set<String> = [
        "permission_prompt", "agent_needs_input", "permission_needed",
    ]

    /// Notification types that just mean the turn ended and the agent is
    /// parked waiting — treated as idle.
    static let idleNotifications: Set<String> = [
        "idle_prompt", "waiting_for_input",
    ]

    func apply(_ req: WireRequest) {
        guard let sessionID = req.sessionID, let event = req.event else { return }
        let ts = now()
        lastSeenBySource[req.source ?? sessions[sessionID]?.source ?? "claude"] = ts

        switch event {
        case "SessionEnd":
            if let s = sessions[sessionID] {
                pushRecent(id: sessionID, s, endedAt: ts)
            }
            sessions[sessionID] = nil
            return
        case "SessionStart":
            sessions[sessionID] = Session(
                state: .idle, lastEvent: ts, firstEvent: ts, cwd: req.cwd,
                activity: "session started", source: req.source ?? "claude")
            return
        default:
            break
        }

        var s = sessions[sessionID]
            ?? Session(state: .idle, lastEvent: ts, firstEvent: ts, cwd: req.cwd,
                       activity: "", source: req.source ?? "claude")
        s.lastEvent = ts
        if let cwd = req.cwd { s.cwd = cwd }
        if let source = req.source { s.source = source }
        if let model = req.model { s.model = Self.shortModelName(model) }

        switch event {
        case "UserPromptSubmit":
            s.state = .working
            s.activity = "thinking…"
        case "PreToolUse":
            s.state = .working
            s.activity = ActivityFormatter.format(
                toolName: req.toolName, file: req.toolFile, command: req.toolCommand,
                description: req.toolDescription, pattern: req.toolPattern, url: req.toolURL)
        case "PostToolUse":
            s.state = .working
            s.activity = "thinking…"
        case "Stop":
            s.state = .idle
            s.activity = "done — waiting for you"
        case "Notification":
            if let t = req.notificationType, Self.needsInputNotifications.contains(t) {
                s.state = .needsInput
                s.activity = ActivityFormatter.needsInputLine(message: req.message)
            } else if let t = req.notificationType, Self.idleNotifications.contains(t) {
                s.state = .idle
                s.activity = "waiting for you"
            }
            // other notification types just refresh lastEvent
        default:
            break // unknown events refresh lastEvent only
        }
        sessions[sessionID] = s
    }

    /// Demote/remove stale sessions (terminals killed without SessionEnd, etc.).
    func sweep() {
        let ts = now()
        for (id, s) in sessions {
            let age = ts.timeIntervalSince(s.lastEvent)
            switch s.state {
            case .working where age > ttls.working,
                 .needsInput where age > ttls.needsInput:
                var demoted = s
                demoted.state = .idle
                demoted.activity = "stale"
                sessions[id] = demoted
            case .idle where age > ttls.idle:
                pushRecent(id: id, s, endedAt: s.lastEvent)
                sessions[id] = nil
            default:
                break
            }
        }
    }

    private func pushRecent(id: String, _ s: Session, endedAt: Date) {
        recents.insert(RecentSession(
            id: id,
            project: s.cwd.map { ($0 as NSString).lastPathComponent } ?? "?",
            source: s.source,
            model: s.model,
            endedAt: endedAt,
            duration: endedAt.timeIntervalSince(s.firstEvent),
            finalActivity: s.activity), at: 0)
        if recents.count > recentsCap { recents.removeLast(recents.count - recentsCap) }
    }

    func aggregate() -> AggregateState {
        guard let top = sessions.values.map(\.state).max() else { return .off }
        switch top {
        case .needsInput: return .needsInput
        case .working: return .working
        case .idle: return .off
        }
    }

    /// needsInput first, then working, then idle; most-recent first within each.
    func rows() -> [SessionRow] {
        sessions
            .map { id, s in
                SessionRow(
                    id: id,
                    project: s.cwd.map { ($0 as NSString).lastPathComponent } ?? "?",
                    source: s.source,
                    model: s.model,
                    state: s.state,
                    activity: s.activity,
                    lastEvent: s.lastEvent,
                    firstEvent: s.firstEvent)
            }
            .sorted {
                if $0.state != $1.state { return $0.state > $1.state }
                return $0.lastEvent > $1.lastEvent
            }
    }

    /// The one-liner for the collapsed widget: top-priority session's line.
    func summary() -> String? {
        guard let top = rows().first, aggregate() != .off else { return nil }
        return "\(top.project): \(top.activity)"
    }

    func reset() {
        sessions.removeAll()
    }
}
