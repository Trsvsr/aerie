import AppKit
import SwiftUI

/// `aerie app` entry: manual NSApplication (no @main — argv dispatch happens
/// first in main.swift).
func runApp() {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core = AerieCore()
    private let hud = HUDState(settings: AerieSettings())
    private var windowController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        warnAboutOtherNotchApps()

        let sounds = SoundPlayer()
        sounds.volume = Float(hud.settings.soundVolume)
        hud.sounds = sounds
        hud.resolveApproval = { [core] id, decision in
            core.resolveApproval(id: id, decision: decision)
        }

        core.onSnapshot = { [hud] snap in
            Task { @MainActor in hud.apply(snap) }
        }
        core.onQuit = {
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
        do {
            try core.start()
        } catch {
            log("fatal: \(error)")
            NSApplication.shared.terminate(nil)
            return
        }
        log("aerie listening at \(socketPath())")

        let wc = NotchWindowController(hud: hud)
        wc.start()
        windowController = wc
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.stop()
    }

    private func warnAboutOtherNotchApps() {
        let rivals = ["NotchNook", "boringNotch", "Peninsula", "TopNotch"]
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName, rivals.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                log("warning: another notch app is running (\(name)) — expect overlapping UI")
            }
        }
    }
}
