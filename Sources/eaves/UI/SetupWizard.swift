import SwiftUI

/// First-run pane inside the expanded card: pick which detected tools to
/// wire up. Installs/uninstalls hook entries per toggle and marks setup done.
/// Reachable later from settings via "set up tools again".
struct SetupWizardPane: View {
    var hud: HUDState
    @State private var selection: [ToolIntegration: Bool] = [:]
    @State private var results: [ToolIntegration: String] = [:]
    @State private var applied = false

    private var detected: [ToolIntegration] {
        ToolIntegration.allCases.filter(\.isDetected)
    }
    private var undetected: [ToolIntegration] {
        ToolIntegration.allCases.filter { !$0.isDetected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("welcome to eaves")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("pick the agent CLIs to watch — eaves adds a hook entry to each tool's config (existing hooks untouched, backups taken)")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(detected, id: \.self) { tool in
                    Toggle(isOn: binding(tool)) {
                        HStack(spacing: 8) {
                            SourceBadge(source: tool.rawValue, state: .working, size: 12)
                            Text(tool.displayName)
                            if let note = results[tool] {
                                Text(note)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                        }
                    }
                }
                if detected.isEmpty {
                    Text("no supported CLIs detected")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                ForEach(undetected, id: \.self) { tool in
                    HStack(spacing: 8) {
                        SourceBadge(source: tool.rawValue, state: .off, size: 12)
                        Text("\(tool.displayName) — not detected")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }

            HStack {
                Button("cancel") { close() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button(applied ? "done" : "apply") {
                    if applied {
                        close()
                    } else {
                        apply()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
        .onAppear {
            for tool in ToolIntegration.allCases {
                selection[tool] = tool.isDetected && (tool.isInstalled || tool == .claude)
            }
        }
    }

    private func close() {
        withAnimation(.spring(duration: 0.25)) {
            hud.showWizard = false
            hud.settings.needsSetup = false
        }
    }

    private func binding(_ tool: ToolIntegration) -> Binding<Bool> {
        Binding(
            get: { selection[tool] ?? false },
            set: { selection[tool] = $0; applied = false })
    }

    private func apply() {
        let binary = currentBinaryPath()
        for tool in detected {
            let want = selection[tool] ?? false
            do {
                if want {
                    let changed = try tool.install(binaryPath: binary)
                    results[tool] = changed ? "hooks added" : "already set up"
                    hud.settings.setEnabled(tool.rawValue, true)
                    if tool == .codex {
                        results[tool]! += " — run /hooks in codex to trust"
                    }
                } else if tool.isInstalled {
                    _ = try tool.uninstall(binaryPath: binary)
                    results[tool] = "hooks removed"
                }
            } catch {
                results[tool] = "failed: \(error.localizedDescription)"
            }
        }
        applied = true
    }
}
