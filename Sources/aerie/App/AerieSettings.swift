import Foundation
import Observation

/// User-tunable behavior, persisted to UserDefaults.
@MainActor
@Observable
final class AerieSettings {
    /// Tools aerie can integrate with; drives the wizard and settings pane.
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
    /// The hardware notch edge isn't exactly the reported inset — on 2x
    /// retina it can sit on a half-point boundary — so this is tunable in
    /// 0.5pt steps, live from settings.
    var seamOffset: Double {
        didSet { defaults.set(seamOffset, forKey: "seamOffsetPt") }
    }
    /// Sources shown in the HUD — opt-in: everything is off until enabled
    /// (normally by the setup wizard). Sessions from unenabled sources are
    /// still tracked, just not shown.
    var enabledSources: Set<String> {
        didSet { defaults.set(Array(enabledSources), forKey: "enabledSources") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverToExpand = defaults.object(forKey: "hoverToExpand") as? Bool ?? false
        expandWhenIdle = defaults.object(forKey: "expandWhenIdle") as? Bool ?? true
        hideInFullscreen = defaults.object(forKey: "hideInFullscreen") as? Bool ?? true
        needsSetup = !(defaults.object(forKey: "setupCompleted") as? Bool ?? false)
        let initialEnabled: Set<String>
        if let stored = defaults.stringArray(forKey: "enabledSources") {
            initialEnabled = Set(stored)
        } else if defaults.object(forKey: "setupCompleted") != nil
            || defaults.object(forKey: "disabledSources") != nil {
            // migrate pre-opt-in installs: enabled = known minus old disabled
            let disabled = Set(defaults.stringArray(forKey: "disabledSources") ?? [])
            initialEnabled = Set(ToolIntegration.allCases.map(\.rawValue))
                .subtracting(disabled)
            defaults.set(Array(initialEnabled), forKey: "enabledSources")
        } else {
            initialEnabled = [] // fresh install: all tools off until the wizard
        }
        enabledSources = initialEnabled
        // migrate from the short-lived integer key if present
        seamOffset = defaults.object(forKey: "seamOffsetPt") as? Double
            ?? (defaults.object(forKey: "seamOffset") as? Int).map(Double.init)
            ?? 0
    }

    func isEnabled(_ source: String) -> Bool {
        enabledSources.contains(source)
    }

    func setEnabled(_ source: String, _ enabled: Bool) {
        if enabled {
            enabledSources.insert(source)
        } else {
            enabledSources.remove(source)
        }
    }
}
