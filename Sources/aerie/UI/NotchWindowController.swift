import AppKit
import SwiftUI

/// Geometry of the notch (or fallback pill) on the chosen screen, in points.
struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    static let wingWidth: CGFloat = 36
    static let panelWidth: CGFloat = 520
    static let panelHeight: CGFloat = 380

    var collapsedWidth: CGFloat { notchWidth + 2 * Self.wingWidth }

    static func detect(on screen: NSScreen) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // safeAreaInsets.top matches the physical notch (38pt here). The
            // menu-bar row is 1pt taller — that thin sliver of menu bar
            // showing under the notch is real; don't paint over it.
            return NotchGeometry(
                notchWidth: screen.frame.width - left.width - right.width,
                notchHeight: screen.safeAreaInsets.top,
                hasNotch: true)
        }
        // Fallback pill under the menu bar line on notchless screens.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            notchWidth: 180,
            notchHeight: max(menuBarHeight, 24),
            hasNotch: false)
    }
}

/// Owns the panel: screen selection, placement, visibility, expand/collapse,
/// and the outside-click/Esc monitors.
@MainActor
final class NotchWindowController {
    private let hud: HUDState
    private var panel: NotchPanel?
    private var hosting: ClippedHostingView<NotchRootView>?
    private var geometry = NotchGeometry(notchWidth: 180, notchHeight: 32, hasNotch: false)
    private var globalClickMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: Any?
    private var fullscreenObservers: [Any] = []
    private var fullscreenPollTimer: Timer?
    private var hiddenForFullscreen = false

    init(hud: HUDState) {
        self.hud = hud
    }

    func start() {
        buildPanel()
        if hud.settings.needsSetup {
            // first run: open straight into the setup wizard
            hud.isExpanded = true
            hud.showWizard = true
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        startFullscreenWatch()
        withObservationTracking()
    }

    // MARK: fullscreen detection

    /// There's no public "fullscreen changed" notification, so re-check on
    /// app activation and space changes, plus a slow poll as a safety net
    /// (catches same-app transitions like a video player going fullscreen).
    private func startFullscreenWatch() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            fullscreenObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFullscreenState() }
            })
        }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateFullscreenState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenPollTimer = timer
        updateFullscreenState()
    }

    /// The active space is a fullscreen space iff the window server shows
    /// WindowManager's "Fullscreen Backdrop" window. (Heuristics based on
    /// menu-bar visibility don't work: the Window Server keeps a Menubar
    /// window and an unchanged visibleFrame even in fullscreen spaces.)
    private func fullscreenAppIsFrontmost() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "WindowManager"
            else { return false }
            // Name check works when we can read names…
            if let name = w[kCGWindowName as String] as? String {
                return name.contains("Fullscreen")
            }
            // …without screen-recording permission names are nil; fall back
            // to the backdrop's distinctive layer (Wallpaper sits at -2147483624,
            // the Fullscreen Backdrop two levels above it).
            return (w[kCGWindowLayer as String] as? Int) == -2147483622
        }
    }

    private func updateFullscreenState() {
        let shouldHide = hud.settings.hideInFullscreen && fullscreenAppIsFrontmost()
        guard shouldHide != hiddenForFullscreen else { return }
        hiddenForFullscreen = shouldHide
        guard let panel else { return }
        if shouldHide {
            hud.isExpanded = false
            hud.expandedByHover = false
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Re-runs itself whenever HUDState changes; drives visibility + monitors.
    private func withObservationTracking() {
        Observation.withObservationTracking {
            applyState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.withObservationTracking() }
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// safeAreaInsets.top reads 0 while a fullscreen space is active — the
    /// notch "disappears" from the API even though the hardware hasn't moved.
    /// Keep the last real notch geometry so a reposition during fullscreen
    /// doesn't rebuild the widget as the no-notch fallback pill.
    private func detectGeometry(on screen: NSScreen) -> NotchGeometry {
        let fresh = NotchGeometry.detect(on: screen)
        if !fresh.hasNotch, geometry.hasNotch,
           screen.frame.width == cachedNotchScreenWidth {
            return geometry
        }
        if fresh.hasNotch { cachedNotchScreenWidth = screen.frame.width }
        return fresh
    }
    private var cachedNotchScreenWidth: CGFloat = 0

    private func buildPanel() {
        guard let screen = targetScreen() else { return }
        geometry = detectGeometry(on: screen)

        let frame = NSRect(
            x: screen.frame.midX - NotchGeometry.panelWidth / 2,
            y: screen.frame.maxY - NotchGeometry.panelHeight,
            width: NotchGeometry.panelWidth,
            height: NotchGeometry.panelHeight)

        let panel = NotchPanel(frame: frame)
        let root = NotchRootView(hud: hud, geometry: geometry) { [weak self] in
            self?.toggleExpanded()
        }
        let hosting = ClippedHostingView(rootView: root)
        hosting.interactiveRect = { [weak self] in self?.currentInteractiveRect() ?? .zero }
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        applyState()
        panel.orderFrontRegardless()
    }

    private func reposition() {
        guard let panel, let screen = targetScreen() else { return }
        geometry = detectGeometry(on: screen)
        hosting?.rootView = NotchRootView(hud: hud, geometry: geometry) { [weak self] in
            self?.toggleExpanded()
        }
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - NotchGeometry.panelWidth / 2,
                y: screen.frame.maxY - NotchGeometry.panelHeight,
                width: NotchGeometry.panelWidth,
                height: NotchGeometry.panelHeight),
            display: true)
        // re-derive mouse pass-through and alpha for the NEW display —
        // otherwise a notched↔notchless switch keeps the old behavior
        // until some unrelated HUD property changes
        applyState()
    }

    /// Interactive shape in view coordinates (origin bottom-left):
    /// collapsed pill hugging the top edge, the whole expanded card, or —
    /// when idle with expand-when-idle on — just the notch footprint.
    private func currentInteractiveRect() -> NSRect {
        if hud.isExpanded {
            // only the card's actual rendered height — the panel window is
            // taller, and a full-panel rect swallows clicks below the card
            let cardHeight = min(max(hud.expandedContentHeight, 60), NotchGeometry.panelHeight)
            return NSRect(
                x: 0, y: NotchGeometry.panelHeight - cardHeight,
                width: NotchGeometry.panelWidth, height: cardHeight)
        }
        // Side slop only: clicks a little wide of the pill still count, but
        // no bottom slop — the pill ends ~1pt above the menu bar's bottom
        // edge, so any downward slop reaches into app content below the
        // menu bar and EATS real clicks meant for other windows.
        let sideSlop: CGFloat = 8
        if hud.isVisible {
            return NSRect(
                x: (NotchGeometry.panelWidth - geometry.collapsedWidth) / 2 - sideSlop,
                y: NotchGeometry.panelHeight - geometry.notchHeight,
                width: geometry.collapsedWidth + 2 * sideSlop,
                height: geometry.notchHeight)
        }
        if hud.settings.expandWhenIdle, geometry.hasNotch {
            // idle: exactly the physical notch footprint — never below it
            return NSRect(
                x: (NotchGeometry.panelWidth - geometry.notchWidth) / 2,
                y: NotchGeometry.panelHeight - geometry.notchHeight,
                width: geometry.notchWidth,
                height: geometry.notchHeight)
        }
        return .zero
    }

    private func applyState() {
        guard let panel else { return }
        let visible = hud.isVisible
        _ = hud.isExpanded  // establish observation dependency

        // stay interactive while idle if the notch is an expand target
        panel.ignoresMouseEvents = !visible
            && !hud.isExpanded
            && !(hud.settings.expandWhenIdle && geometry.hasNotch)
        if geometry.hasNotch {
            // The collapsed shape hides behind the physical notch when idle
            // (wings animate to zero width in SwiftUI) — no window fade.
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = visible ? 1 : 0
            }
        }

        if hud.isExpanded {
            panel.allowsKey = true
            panel.makeKey()
            installMonitors()
        } else {
            panel.allowsKey = false
            removeMonitors()
        }
    }

    private func toggleExpanded() {
        withAnimation(.spring(duration: 0.3)) {
            if hud.isExpanded && hud.expandedByHover {
                // The user reached for the pill, hover beat them to opening,
                // and their click landed on the header. They wanted it open —
                // pin it instead of closing.
                hud.expandedByHover = false
            } else {
                hud.isExpanded.toggle()
                hud.expandedByHover = false
            }
        }
    }

    private func collapse() {
        guard hud.isExpanded else { return }
        withAnimation(.spring(duration: 0.3)) {
            hud.isExpanded = false
            hud.expandedByHover = false
        }
    }

    private func installMonitors() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.collapse() } // Esc
                    return
                }
                if let panel = self.panel, event.window === panel {
                    let p = event.locationInWindow
                    if !self.currentInteractiveRect().contains(p) { self.collapse() }
                } else {
                    self.collapse()
                }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalClickMonitor = nil
        localMonitor = nil
    }
}
