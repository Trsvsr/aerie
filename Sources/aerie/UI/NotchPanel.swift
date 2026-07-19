import AppKit
import SwiftUI

/// Borderless, non-activating panel that sits over the notch. Always sized to
/// the expanded maximum; the hosting view clips hit-testing to the currently
/// interactive shape so clicks outside the visible widget fall through.
final class NotchPanel: NSPanel {
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    // AppKit clamps borderless windows below the menu bar; we live on the
    // menu bar row, so keep the frame exactly where we put it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        // Must come after isFloatingPanel — its setter resets level to .floating.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
}

/// NSHostingView that only accepts clicks inside `interactiveRect`
/// (in window coordinates, bottom-left origin); everything else passes
/// through to whatever is below.
final class ClippedHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: () -> NSRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's space, which may be flipped —
        // normalize to window coordinates before testing.
        let inWindow = convert(convert(point, from: superview), to: nil)
        guard interactiveRect().contains(inWindow) else { return nil }
        return super.hitTest(point)
    }

    // The panel is never key while collapsed; without this the first click
    // is swallowed as an activation click instead of reaching the view.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
