import SwiftUI

/// Root view for the panel: collapsed pill hugging the notch, or the
/// expanded session list unfolding below it. The panel itself never resizes;
/// this view just draws the current shape at the top-center.
struct NotchRootView: View {
    @Bindable var hud: HUDState
    let geometry: NotchGeometry
    let onToggle: () -> Void

    @State private var hoverOpenTask: Task<Void, Never>?
    @State private var mouseWasInPanel = false

    var body: some View {
        VStack(spacing: 0) {
            if hud.isExpanded {
                // grow out of the notch, no fade: scale from the top anchor
                // starting at roughly the collapsed pill's footprint
                ExpandedView(hud: hud, geometry: geometry, onToggle: onToggle)
                    .transition(.scale(scale: 0.12, anchor: .top))
                    .onHover { inside in
                        // The card starts tiny and may not be under the cursor
                        // yet — only treat an exit as real after one entry, or
                        // it collapses (and re-expands) in a loop.
                        if inside { mouseWasInPanel = true }
                        guard hud.expandedByHover, !inside, mouseWasInPanel else { return }
                        mouseWasInPanel = false
                        withAnimation(.spring(duration: 0.3)) {
                            hud.isExpanded = false
                            hud.expandedByHover = false
                        }
                    }
                    .onDisappear { mouseWasInPanel = false }
            } else {
                // While idle the pill is tucked behind the physical notch but
                // still hit-testable there (if expandWhenIdle), so hover/click
                // on the notch itself opens the panel.
                CollapsedView(hud: hud, geometry: geometry)
                    // extend the tappable region past the drawn pill to match
                    // the window's slop-padded hit mask
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
                    .onHover { inside in
                        hoverOpenTask?.cancel()
                        guard inside, hud.settings.hoverToExpand,
                              hud.isVisible || hud.settings.expandWhenIdle else { return }
                        // small dwell so brushing past the menu bar doesn't trigger
                        hoverOpenTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            guard !Task.isCancelled, !hud.isExpanded else { return }
                            withAnimation(.spring(duration: 0.3)) {
                                hud.isExpanded = true
                                hud.expandedByHover = true
                            }
                        }
                    }
                    .transition(.identity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchGeometry.panelWidth, height: NotchGeometry.panelHeight, alignment: .top)
        .animation(.spring(duration: 0.3), value: hud.isExpanded)
    }
}

private func stateColor(_ state: SessionState) -> Color {
    switch state {
    case .needsInput: return .red
    case .working: return .orange
    case .idle: return .secondary.opacity(0.6)
    }
}

/// The notch-hugging pill, NotchNook-compact: a status dot on the left wing,
/// session count on the right, black center matching the notch. The summary
/// text lives in the expanded panel only.
struct CollapsedView: View {
    var hud: HUDState
    let geometry: NotchGeometry

    var body: some View {
        // When idle the wings collapse to zero width, leaving a shape exactly
        // the size of the physical notch — invisible, black on black. Activity
        // springs the wings outward, so the notch appears to grow sideways.
        let visible = hud.isVisible
        let wing: CGFloat = visible ? NotchGeometry.wingWidth : 0
        // When idle, run narrower AND shorter than the physical notch so the
        // flares and bottom corners tuck fully behind it instead of peeking out.
        // When active, the height is safeAreaInsets.top + seamOffset — the
        // hardware's true edge isn't exactly the reported inset and only the
        // user can see the seam, so the offset is tunable in settings.
        let centerWidth = visible ? geometry.notchWidth : geometry.notchWidth - 44
        let height = visible
            ? geometry.notchHeight + hud.settings.seamOffset
            : geometry.notchHeight - 10
        HStack(spacing: 0) {
            // left wing: logo of the top-priority session's tool.
            // The side wall is inset 8pt by the top flare, so center within
            // the visible wing (wall → notch), not the full frame.
            HStack {
                Spacer(minLength: 0)
                SourceBadge(
                    source: hud.displayRows.first?.source ?? "claude",
                    state: hud.displayAggregate,
                    size: 13)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(width: geometry.hasNotch ? wing : NotchGeometry.wingWidth)
            .clipped()
            .opacity(visible ? 1 : 0)

            // center: the physical notch (keep it black, draw nothing)
            if geometry.hasNotch {
                Spacer().frame(width: max(centerWidth, 0))
            }

            // right wing (mirror: wall inset on the trailing side)
            HStack {
                Spacer(minLength: 0)
                Text("\(hud.displayRows.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
            }
            .padding(.trailing, 8)
            .frame(width: geometry.hasNotch ? wing : NotchGeometry.wingWidth)
            .clipped()
            .opacity(visible ? 1 : 0)
        }
        .frame(height: height)
        .background(
            NotchShape(topRadius: 8, bottomRadius: 12).fill(.black)
        )
        .contentShape(Rectangle())
        .animation(.spring(duration: 0.35, bounce: 0.25), value: visible)
    }
}

/// The expanded card: session list or the settings pane.
struct ExpandedView: View {
    @Bindable var hud: HUDState
    let geometry: NotchGeometry
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header bar doubles as the collapse control
            HStack {
                SourceBadge(
                    source: hud.displayRows.first?.source ?? "claude",
                    state: hud.displayAggregate,
                    size: 12)
                Text(hud.showWizard ? "setup" : (hud.showSettings ? "settings" : "agents"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 30)
            .frame(height: max(geometry.notchHeight, 28))
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            Divider().overlay(.white.opacity(0.1))
                .padding(.horizontal, 14)  // stay inside the flared side walls

            if hud.showWizard {
                SetupWizardPane(hud: hud)
            } else if hud.showSettings {
                SettingsPane(hud: hud)
            } else if hud.displayRows.isEmpty {
                Text("no active sessions")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(hud.displayRows) { row in
                            SessionRowView(row: row)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 280)
            }

            Divider().overlay(.white.opacity(0.1))
                .padding(.horizontal, 14)  // stay inside the flared side walls
            HStack {
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        if hud.showWizard {
                            // leave the wizard (also covers first run: don't
                            // nag again — setup stays reachable from settings)
                            hud.showWizard = false
                            hud.settings.needsSetup = false
                        } else {
                            hud.showSettings.toggle()
                        }
                        // engaging with panes = engaged; no auto-close on mouse-out
                        hud.expandedByHover = false
                    }
                } label: {
                    Image(systemName: (hud.showWizard || hud.showSettings) ? "list.bullet" : "gearshape")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Quit eaves") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 8)
        }
        .frame(width: NotchGeometry.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            // solid black: with any translucency the bright menu bar bleeds
            // through the top strip and the card stops reading as the notch
            NotchShape(topRadius: 10, bottomRadius: 18).fill(.black)
        )
    }
}

/// Settings inside the expanded card: behavior toggles + per-tool visibility.
struct SettingsPane: View {
    var hud: HUDState

    var body: some View {
        @Bindable var settings = hud.settings
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("BEHAVIOR")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                Toggle("Expand on hover", isOn: $settings.hoverToExpand)
                Toggle("Open from notch when idle", isOn: $settings.expandWhenIdle)
                Toggle("Hide in fullscreen apps", isOn: $settings.hideInFullscreen)
                HStack(spacing: 8) {
                    Text("Notch seam")
                    Stepper(
                        String(format: "%+.1f pt", settings.seamOffset),
                        value: $settings.seamOffset, in: -6...4, step: 0.5)
                        .fixedSize()
                    Text("adjust until the widget meets the notch edge")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("TOOLS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                ForEach(EavesSettings.knownTools, id: \.rawValue) { tool in
                    Toggle(isOn: Binding(
                        get: { settings.isEnabled(tool.rawValue) },
                        set: { settings.setEnabled(tool.rawValue, $0) }
                    )) {
                        HStack(spacing: 8) {
                            SourceBadge(source: tool.rawValue, state: .working, size: 12)
                            Text(tool.displayName)
                            if !tool.isDetected {
                                Text("not detected")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.3))
                            } else if !tool.isInstalled {
                                Text("hooks not installed")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange.opacity(0.6))
                            }
                        }
                    }
                }
                Button("set up tool hooks…") {
                    withAnimation(.spring(duration: 0.25)) {
                        hud.showWizard = true
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.8))
        .tint(Color(red: 0.85, green: 0.44, blue: 0.24))
        .padding(.horizontal, 30)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionRowView: View {
    let row: SessionRow

    var body: some View {
        HStack(spacing: 10) {
            SourceBadge(
                source: row.source,
                state: row.state == .idle ? .off : (row.state == .needsInput ? .needsInput : .working),
                size: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.project)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(ActivityFormatter.truncate(row.activity, max: 60))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(relativeAge(from: row.lastEvent, to: context.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 9)
    }

    private func relativeAge(from: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(from)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

/// The notch silhouette: concave top corners (the S-curve flaring into the
/// bezel) and convex rounded bottom corners. The body sits inset by
/// `topRadius` on each side; the top edge spans the full rect width.
/// `centerCutoutWidth` raises the bottom edge by `centerCutoutInset` across
/// the middle span — used to keep the pill's center tucked behind the
/// physical notch (whose real edge isn't pixel-exactly safeAreaInsets.top)
/// so no black hairline peeks below the hardware.
struct NotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 12
    var centerCutoutWidth: CGFloat = 0
    var centerCutoutInset: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // top-left, at the bezel
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // concave curve inward: bezel → side wall
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        // left wall down
        p.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        // convex bottom-left corner
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY))
        if centerCutoutWidth > 0 {
            // bottom edge steps up behind the physical notch (hidden by it)
            let cutStart = rect.midX - centerCutoutWidth / 2
            let cutEnd = rect.midX + centerCutoutWidth / 2
            p.addLine(to: CGPoint(x: cutStart, y: rect.maxY))
            p.addLine(to: CGPoint(x: cutStart, y: rect.maxY - centerCutoutInset))
            p.addLine(to: CGPoint(x: cutEnd, y: rect.maxY - centerCutoutInset))
            p.addLine(to: CGPoint(x: cutEnd, y: rect.maxY))
        }
        // bottom edge
        p.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        // convex bottom-right corner
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
        // right wall up
        p.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        // concave curve outward: side wall → bezel
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
