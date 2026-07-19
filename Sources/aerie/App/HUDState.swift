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

    var isVisible: Bool { displayAggregate != .off }

    func apply(_ snap: Snapshot) {
        snapshot = snap
        // Note: going idle no longer force-collapses — the panel is
        // reachable (and useful, via settings) while idle.
    }
}
