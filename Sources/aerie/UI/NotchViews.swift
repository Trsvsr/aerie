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
                // Symmetric: the collapse is the exact reverse of the expand.
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
        // When idle, run narrower AND shorter than the physical notch so the
        // flares and bottom corners tuck fully behind it instead of peeking out.
        // When active, the height is safeAreaInsets.top + seamOffset — the
        // hardware's true edge isn't exactly the reported inset and only the
        // user can see the seam, so the offset is tunable in settings.
        let centerWidth = visible ? geometry.notchWidth : geometry.notchWidth - 44
        let height = visible
            ? geometry.notchHeight + hud.settings.seamOffset
            : geometry.notchHeight - 10
        // Distinct tools among non-idle sessions, priority order, capped at 3.
        let activeSources = Array(hud.displayRows
            .filter { $0.state != .idle }
            .map(\.source)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(3))
        // Wings widen with their content, symmetrically so the pill stays
        // centered: each extra stacked badge adds its width minus overlap
        // (11 - 3 = 8pt); the completion linger shows check + badge on the
        // left and a duration like "1h12m" on the right, which need ~14pt
        // beyond the single-badge baseline.
        let showsLinger = hud.lingering != nil && activeSources.isEmpty
        let stackExtra = CGFloat(max(activeSources.count - 1, 0)) * 8
        let lingerExtra: CGFloat = showsLinger ? 14 : 0
        let wingWidth = NotchGeometry.wingWidth + stackExtra + lingerExtra
        HStack(spacing: 0) {
            // left wing: overlapped badge stack of every running tool.
            // The side wall is inset 8pt by the top flare, so center within
            // the visible wing (wall → notch), not the full frame.
            HStack {
                Spacer(minLength: 0)
                if let linger = hud.lingering, activeSources.isEmpty {
                    // completion linger: green check + the finished tool
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        SourceBadge(source: linger.source, state: .off, size: 11)
                    }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if activeSources.isEmpty {
                    SourceBadge(
                        source: hud.displayRows.first?.source ?? "claude",
                        state: hud.displayAggregate,
                        size: 13)
                        .transition(.opacity)
                } else {
                    HStack(spacing: -3) {
                        ForEach(Array(activeSources.enumerated()), id: \.element) { i, source in
                            SourceBadge(
                                source: source,
                                state: i == 0 ? hud.displayAggregate : .working,
                                size: 11)
                                // black disc separates overlapped badges
                                .background(Circle().fill(.black).frame(width: 15, height: 15))
                                .zIndex(Double(activeSources.count - i))
                        }
                    }
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            // animate content swaps (badges ↔ checkmark), not just width
            .animation(.spring(duration: 0.35, bounce: 0.3), value: showsLinger)
            .animation(.default, value: activeSources)
            .padding(.leading, 8)
            .frame(width: geometry.hasNotch ? (visible ? wingWidth : 0) : wingWidth)
            .clipped()
            .opacity(visible ? 1 : 0)

            // center: the physical notch (keep it black, draw nothing)
            if geometry.hasNotch {
                Spacer().frame(width: max(centerWidth, 0))
            }

            // right wing: linger → final duration; blocked sessions → "N!";
            // solo → running duration; fleet → count
            HStack {
                Spacer(minLength: 0)
                let blocked = hud.displayRows.filter { $0.state == .needsInput }.count
                if let linger = hud.lingering, hud.displayAggregate == .off {
                    Text(compactDurationText(linger.duration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.green.opacity(0.9))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if blocked > 0, hud.displayRows.count > 1 {
                    Text("\(blocked)!")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.red)
                } else if hud.displayRows.count == 1, let solo = hud.displayRows.first {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(compactDuration(from: solo.firstEvent, to: context.date))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                } else {
                    Text("\(hud.displayRows.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            .animation(.spring(duration: 0.35, bounce: 0.3), value: showsLinger)
            .padding(.trailing, 8)
            .frame(width: geometry.hasNotch ? (visible ? wingWidth : 0) : wingWidth)
            .clipped()
            .opacity(visible ? 1 : 0)
        }
        .frame(height: height)
        .background(
            // 8/12 verified by eye against the hardware (notchbay.com claims
            // 4/8, but that rendered too boxy on this panel — trust the eye)
            NotchShape(topRadius: 8, bottomRadius: 12).fill(.black)
        )
        .contentShape(Rectangle())
        .animation(.spring(duration: 0.35, bounce: 0.25), value: visible)
    }

    /// "47s", "4m", "1h12m" — coarse on purpose; the pill isn't a stopwatch.
    private func compactDuration(from start: Date, to now: Date) -> String {
        compactDurationText(now.timeIntervalSince(start))
    }

    private func compactDurationText(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
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
                        RecentsSection(hud: hud)
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
                Button("Quit aerie") { NSApplication.shared.terminate(nil) }
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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            // hit area must track the card, not the full panel window
            hud.expandedContentHeight = height
        }
    }
}

/// Collapsed-by-default list of recently finished sessions.
struct RecentsSection: View {
    var hud: HUDState
    @State private var open = false

    private var recents: [RecentSession] {
        hud.snapshot.recents.filter { hud.settings.isEnabled($0.source) }
    }

    var body: some View {
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(duration: 0.25)) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("RECENT")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(recents.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.25))
                        Spacer()
                    }
                    .foregroundStyle(.white.opacity(0.35))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 30)
                .padding(.vertical, 6)

                if open {
                    ForEach(recents.prefix(8)) { r in
                        HStack(spacing: 10) {
                            SourceBadge(source: r.source, state: .off, size: 11)
                            Text(r.project)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(r.finalActivity)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                                .lineLimit(1)
                            Spacer()
                            Text(durationLabel(r.duration))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func durationLabel(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
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
                Toggle("Auto-open on approval requests", isOn: $settings.autoExpandOnApproval)
                HStack(spacing: 8) {
                    Toggle("Sounds", isOn: $settings.soundsEnabled)
                    if settings.soundsEnabled {
                        Slider(value: Binding(
                            get: { settings.soundVolume },
                            set: { settings.soundVolume = $0; hud.sounds?.volume = Float($0) }
                        ), in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 80)
                        Button {
                            hud.sounds?.play(.completion)
                        } label: {
                            Image(systemName: "play.circle")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                ForEach(AerieSettings.knownTools, id: \.rawValue) { tool in
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
                HStack(spacing: 6) {
                    Text(row.project)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    if let model = row.model {
                        Text(model)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(.white.opacity(0.08)))
                    }
                }
                // Wrap to two lines before truncating — most lines are one
                // line anyway, so rows only grow when there's real content.
                Text(row.activity)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
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
struct NotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = bottomRadius
        // Bottom corners, tuned against photos of the hardware notch: the
        // real corners are tight — a quick ~r turn with only a whisper of
        // easing, not a long squircle sprawl. Keep two cubics for the
        // continuous curvature but confine them to ~1.05r.
        let ext = r * 1.05
        let lx = rect.minX + topRadius     // left wall x
        let rx = rect.maxX - topRadius     // right wall x

        // top-left, at the bezel
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // concave curve inward: bezel → side wall
        p.addQuadCurve(
            to: CGPoint(x: lx, y: rect.minY + topRadius),
            control: CGPoint(x: lx, y: rect.minY))
        // left wall down to where the corner easing begins
        p.addLine(to: CGPoint(x: lx, y: rect.maxY - ext))
        // bottom-left corner: wall → bottom edge, tight turn
        p.addCurve(
            to: CGPoint(x: lx + r * 0.5, y: rect.maxY - r * 0.13),
            control1: CGPoint(x: lx, y: rect.maxY - r * 0.45),
            control2: CGPoint(x: lx + r * 0.15, y: rect.maxY - r * 0.27))
        p.addCurve(
            to: CGPoint(x: lx + ext, y: rect.maxY),
            control1: CGPoint(x: lx + r * 0.75, y: rect.maxY - r * 0.03),
            control2: CGPoint(x: lx + r * 0.9, y: rect.maxY))
        // bottom edge
        p.addLine(to: CGPoint(x: rx - ext, y: rect.maxY))
        // bottom-right corner: bottom edge → wall, tight turn
        p.addCurve(
            to: CGPoint(x: rx - r * 0.5, y: rect.maxY - r * 0.13),
            control1: CGPoint(x: rx - r * 0.9, y: rect.maxY),
            control2: CGPoint(x: rx - r * 0.75, y: rect.maxY - r * 0.03))
        p.addCurve(
            to: CGPoint(x: rx, y: rect.maxY - ext),
            control1: CGPoint(x: rx - r * 0.15, y: rect.maxY - r * 0.27),
            control2: CGPoint(x: rx, y: rect.maxY - r * 0.45))
        // right wall up
        p.addLine(to: CGPoint(x: rx, y: rect.minY + topRadius))
        // concave curve outward: side wall → bezel
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rx, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
