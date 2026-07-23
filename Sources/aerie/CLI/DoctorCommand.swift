import Foundation

/// `aerie doctor` — per-integration health check: is the tool present, are
/// hooks installed, and have events actually flowed? "Installed" is not the
/// same as "working"; this shows the receipts.
enum DoctorCommand {
    static func run() -> Never {
        // Ask the app for last-seen-per-source; degrade gracefully if down.
        var lastSeen: [String: Date] = [:]
        var appAlive = false
        if let resp = try? SocketClient.request(WireRequest(cmd: "status"), timeoutMS: 800),
           resp.ok {
            appAlive = true
            for (source, epoch) in resp.lastSeenBySource ?? [:] {
                lastSeen[source] = Date(timeIntervalSince1970: epoch)
            }
        }

        print(appAlive
            ? "app: running (socket \(socketPath()))"
            : "app: NOT REACHABLE at \(socketPath()) — is the LaunchAgent loaded?")
        print("")
        print(pad("TOOL", 18) + pad("DETECTED", 10) + pad("HOOKS", 12) + "EVENTS")

        for tool in ToolIntegration.allCases {
            let detected = tool.isDetected
            let installed = tool.isInstalled
            let hooksCol: String
            if !detected {
                hooksCol = "—"
            } else if installed {
                hooksCol = "installed"
            } else {
                hooksCol = "MISSING"
            }
            let eventsCol: String
            if let seen = lastSeen[tool.rawValue] {
                eventsCol = "seen \(agoLabel(seen))"
            } else if installed {
                eventsCol = appAlive ? "never seen since app start" : "unknown (app down)"
            } else {
                eventsCol = "—"
            }
            print(pad(tool.displayName, 18) + pad(detected ? "yes" : "no", 10)
                + pad(hooksCol, 12) + eventsCol)
        }

        // Payload snapshots are receipts of the hook client actually firing.
        let payloadDir = aerieDirectory().appendingPathComponent("last-payloads")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: payloadDir, includingPropertiesForKeys: [.contentModificationDateKey]),
           !files.isEmpty {
            print("\nlast hook payloads (\(payloadDir.path)):")
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? nil
                print("  \(pad(f.deletingPathExtension().lastPathComponent, 20))"
                    + (mtime.map { agoLabel($0) } ?? "?"))
            }
        }

        // Usage tracking reads two purely local sources; report on each so
        // "usage isn't showing" is diagnosable instead of a silent black box.
        print("\nusage tracking:")
        if let c = UsageReader.readClaude() {
            print("  claude: captured \(agoLabel(c.capturedAt))\(c.isStale ? " (stale)" : "")")
        } else {
            print("  claude: no data — checking last-payloads/statusline.json will show"
                + " whether Claude is calling the statusLine command at all, and whether"
                + " that payload includes \"rate_limits\"")
        }
        if let x = UsageReader.readCodex() {
            print("  codex:  captured \(agoLabel(x.capturedAt))\(x.isStale ? " (stale)" : "")")
        } else {
            print("  codex:  no rollout with rate_limits found under ~/.codex/sessions")
        }

        if let update = updateMessage(latestTag: fetchLatestReleaseTag(), currentVersion: aerieVersion) {
            print("\n\(update)")
        }

        // Common gotchas worth surfacing every time.
        var notes: [String] = []
        if ToolIntegration.codex.isInstalled {
            notes.append("codex: hooks must be trusted once via /hooks inside a codex session")
        }
        if ToolIntegration.claude.isInstalled {
            notes.append("claude: sessions started before hook install won't report until restarted")
        }
        if !notes.isEmpty {
            print("\nnotes:")
            for n in notes { print("  - \(n)") }
        }
        exit(appAlive ? 0 : 1)
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count)
    }

    private static func agoLabel(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    /// Pure comparison so this is testable without a real network call.
    /// nil = nothing to report (up to date, or the fetch failed/timed out —
    /// doctor must never hang or fail just because GitHub is unreachable).
    /// Not full semver — just "different from what's installed" — fine for
    /// this project's plain vX.Y.Z tags.
    static func updateMessage(latestTag: String?, currentVersion: String) -> String? {
        guard let latestTag else { return nil }
        let latest = latestTag.hasPrefix("v") ? String(latestTag.dropFirst()) : latestTag
        guard !latest.isEmpty, latest != currentVersion else { return nil }
        return "update available: \(currentVersion) -> \(latest)"
            + " (brew upgrade aerie, or github.com/Trsvsr/aerie/releases)"
    }

    /// Best-effort, short-timeout fetch — never let a network hiccup make
    /// `doctor` hang or fail. Returns nil on any error, offline, or timeout.
    private static func fetchLatestReleaseTag() -> String? {
        guard let url = URL(string: "https://api.github.com/repos/Trsvsr/aerie/releases/latest")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        // required by GitHub's API — unauthenticated requests with no UA are rejected
        request.setValue("aerie-doctor", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var tag: String?
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            tag = obj["tag_name"] as? String
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        return tag
    }
}
