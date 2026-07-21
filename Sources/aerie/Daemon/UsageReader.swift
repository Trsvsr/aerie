import Foundation

/// Provider quota snapshot for the panel's usage section.
struct ProviderUsage: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let label: String          // "5h", "7d"
        let usedPercent: Double
        let resetsAt: Date?
    }
    let provider: String           // "claude" | "codex"
    let windows: [Window]
    let capturedAt: Date

    var isStale: Bool { Date().timeIntervalSince(capturedAt) > 2 * 3600 }
}

/// Reads quota state from purely local sources: Codex writes rate_limits
/// into its session rollout files; Claude's flows through our statusline
/// wrapper into ~/.aerie/claude-usage.json.
enum UsageReader {
    static func read() -> [ProviderUsage] {
        var out: [ProviderUsage] = []
        if let claude = readClaude() { out.append(claude) }
        if let codex = readCodex() { out.append(codex) }
        return out
    }

    // MARK: Claude — teed by `aerie statusline`

    static func readClaude(
        path: String = aerieDirectory().appendingPathComponent("claude-usage.json").path
    ) -> ProviderUsage? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var windows: [ProviderUsage.Window] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            guard let w = obj[key] as? [String: Any],
                  let pct = w["used_percentage"] as? Double else { continue }
            let resets = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            windows.append(.init(label: label, usedPercent: pct, resetsAt: resets))
        }
        guard !windows.isEmpty else { return nil }
        let captured = (obj["captured_at"] as? Double)
            .map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        return ProviderUsage(provider: "claude", windows: windows, capturedAt: captured)
    }

    // MARK: Codex — session rollout files

    static func readCodex(
        sessionsDir: String = NSString(string: "~/.codex/sessions").expandingTildeInPath
    ) -> ProviderUsage? {
        guard let newest = newestRollout(in: sessionsDir) else { return nil }
        guard let usage = scanRollout(newest) else { return nil }
        return usage
    }

    /// Newest rollout-*.jsonl by walking year/month/day directories
    /// descending, then file mtime.
    static func newestRollout(in dir: String) -> URL? {
        let fm = FileManager.default
        func newestSubdir(_ path: String) -> String? {
            (try? fm.contentsOfDirectory(atPath: path))?
                .filter { Int($0) != nil }
                .sorted(by: >)
                .first
        }
        guard let y = newestSubdir(dir),
              let m = newestSubdir("\(dir)/\(y)"),
              let d = newestSubdir("\(dir)/\(y)/\(m)") else { return nil }
        let dayDir = "\(dir)/\(y)/\(m)/\(d)"
        let files = ((try? fm.contentsOfDirectory(atPath: dayDir)) ?? [])
            .filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            .map { URL(fileURLWithPath: "\(dayDir)/\($0)") }
        return files.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return (a ?? .distantPast) < (b ?? .distantPast)
        }
    }

    /// Read the tail of a rollout file; last non-null rate_limits wins
    /// (recent lines sometimes carry null — scan backward).
    static func scanRollout(_ url: URL) -> ProviderUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\""),
                  let obj = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any] else { continue }
            // rate_limits may nest under payload or sit at top level
            let container = (obj["payload"] as? [String: Any]) ?? obj
            guard let rl = container["rate_limits"] as? [String: Any] else { continue }
            var windows: [ProviderUsage.Window] = []
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any],
                      let pct = w["used_percent"] as? Double else { continue }
                let mins = w["window_minutes"] as? Double ?? 0
                let label = mins >= 10_000 ? "7d" : (mins > 0 ? "\(Int(mins / 60))h" : key)
                let resets = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                windows.append(.init(label: label, usedPercent: pct, resetsAt: resets))
            }
            guard !windows.isEmpty else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            return ProviderUsage(provider: "codex", windows: windows, capturedAt: mtime ?? Date())
        }
        return nil
    }
}
