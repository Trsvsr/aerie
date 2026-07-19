import Foundation
import Observation

/// User-tunable behavior, persisted to UserDefaults.
@MainActor
@Observable
final class EavesSettings {
    /// Tools eaves can integrate with; drives the wizard and settings pane.
    /// Sources not in this list still work (dot fallback).
    static let knownTools: [ToolIntegration] = ToolIntegration.allCases

    /// First-run setup wizard not yet completed.
    var needsSetup: Bool {
        didSet { defaults.set(!needsSetup, forKey: "setupCompleted") }
    }

    var hoverToExpand: Bool {
        didSet { defaults.set(hoverToExpand, forKey: "hoverToExpand") }
    }
    /// Allow opening the panel by hovering/clicking the notch when no
    /// sessions are active.
    var expandWhenIdle: Bool {
        didSet { defaults.set(expandWhenIdle, forKey: "expandWhenIdle") }
    }
    /// Hide the HUD entirely while a fullscreen app is frontmost.
    var hideInFullscreen: Bool {
        didSet { defaults.set(hideInFullscreen, forKey: "hideInFullscreen") }
    }
    /// Points added to safeAreaInsets.top for the active pill's height.
    /// The hardware notch edge isn't exactly the reported inset; only the
    /// user can see the true seam, so this is tunable live from settings.
    var seamOffset: Int {
        didSet { defaults.set(seamOffset, forKey: "seamOffset") }
    }
    /// Sources hidden from the HUD (sessions still tracked, just not shown).
    var disabledSources: Set<String> {
        didSet { defaults.set(Array(disabledSources), forKey: "disabledSources") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverToExpand = defaults.object(forKey: "hoverToExpand") as? Bool ?? true
        expandWhenIdle = defaults.object(forKey: "expandWhenIdle") as? Bool ?? true
        hideInFullscreen = defaults.object(forKey: "hideInFullscreen") as? Bool ?? true
        disabledSources = Set(defaults.stringArray(forKey: "disabledSources") ?? [])
        needsSetup = !(defaults.object(forKey: "setupCompleted") as? Bool ?? false)
        seamOffset = defaults.object(forKey: "seamOffset") as? Int ?? -1
    }

    func isEnabled(_ source: String) -> Bool {
        !disabledSources.contains(source)
    }

    func setEnabled(_ source: String, _ enabled: Bool) {
        if enabled {
            disabledSources.remove(source)
        } else {
            disabledSources.insert(source)
        }
    }
}
