import Foundation
import Observation

/// UI-facing state, observed by SwiftUI. Fed snapshots from the core queue.
@MainActor
@Observable
final class HUDState {
    var snapshot: Snapshot = .empty
    var isExpanded = false
    /// True when the panel was opened by hovering (auto-closes on mouse
    /// exit); click-opened panels stay until dismissed.
    var expandedByHover = false
    /// Settings pane visible inside the expanded panel.
    var showSettings = false
    /// Setup wizard pane visible (first run, or opened from settings).
    /// Takes precedence over showSettings while true.
    var showWizard = false

    /// Ephemeral "just finished" presentation: shown for ~5s after a session
    /// transitions working/needsInput → idle (or ends), before the pill
    /// tucks away. Closes the "did it finish or die?" loop.
    struct Completion: Equatable {
        let project: String
        let source: String
        let duration: TimeInterval
    }
    var lingering: Completion?
    /// Completions queue up (bounded) and display sequentially — two agents
    /// finishing together each get their moment instead of the last one
    /// silently winning.
    private var lingerQueue: [Completion] = []
    private var lingerTask: Task<Void, Never>?
    /// Previous snapshot's per-session states, for transition detection.
    private var priorStates: [String: SessionState] = [:]
    private var priorFirstEvents: [String: Date] = [:]

    let settings: AerieSettings

    init(settings: AerieSettings) {
        self.settings = settings
    }

    /// Sessions after the per-tool visibility filter from settings.
    var displayRows: [SessionRow] {
        snapshot.rows.filter { settings.isEnabled($0.source) }
    }

    /// Aggregate over the *displayed* sessions, so hiding a tool also
    /// hides its contribution to the widget state.
    var displayAggregate: AggregateState {
        guard let top = displayRows.map(\.state).max() else { return .off }
        switch top {
        case .needsInput: return .needsInput
        case .working: return .working
        case .idle: return .off
        }
    }

    /// Pill shows while any session is active OR a completion is lingering.
    var isVisible: Bool { displayAggregate != .off || lingering != nil }

    func apply(_ snap: Snapshot) {
        detectCompletions(snap)
        snapshot = snap
        // Note: going idle no longer force-collapses — the panel is
        // reachable (and useful, via settings) while idle.
    }

    private func detectCompletions(_ snap: Snapshot) {
        let visibleRows = snap.rows.filter { settings.isEnabled($0.source) }
        // a session completed if it was active before and is now idle or gone
        for (id, oldState) in priorStates where oldState != .idle {
            let newRow = visibleRows.first { $0.id == id }
            if newRow == nil || newRow?.state == .idle {
                let ended = newRow ?? snap.recents.first { $0.id == id }.map {
                    SessionRow(id: $0.id, project: $0.project, source: $0.source,
                               model: $0.model, state: .idle, activity: $0.finalActivity,
                               lastEvent: $0.endedAt,
                               firstEvent: $0.endedAt.addingTimeInterval(-$0.duration))
                }
                guard let ended else { continue }
                showLinger(Completion(
                    project: ended.project,
                    source: ended.source,
                    duration: Date().timeIntervalSince(
                        priorFirstEvents[id] ?? ended.firstEvent)))
            }
        }
        priorStates = Dictionary(uniqueKeysWithValues: visibleRows.map { ($0.id, $0.state) })
        priorFirstEvents = Dictionary(uniqueKeysWithValues: visibleRows.map { ($0.id, $0.firstEvent) })
    }

    private func showLinger(_ c: Completion) {
        guard lingerQueue.count < 8 else { return } // bounded; drop overflow
        lingerQueue.append(c)
        drainLingerQueue()
    }

    private func drainLingerQueue() {
        guard lingering == nil, !lingerQueue.isEmpty else { return }
        lingering = lingerQueue.removeFirst()
        lingerTask = Task { @MainActor in
            // shorten each slot when more are waiting so a burst drains
            let hold: Double = lingerQueue.isEmpty ? 5 : 2.5
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            lingering = nil
            drainLingerQueue()
        }
    }
}
