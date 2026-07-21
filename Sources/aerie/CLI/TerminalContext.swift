import Foundation

/// Captures the terminal identity of the CLI that spawned this hook process,
/// so the app can jump back to the right pane later. SessionStart only —
/// keeps the hot event path at zero extra cost.
///
/// Gotcha this design encodes: under tmux, ITERM_SESSION_ID is frozen to
/// whatever pane launched the tmux SERVER (possibly long gone). So inside
/// tmux the only trustworthy handle is TMUX_PANE; outside it, the tty —
/// which the hook doesn't have directly (no controlling terminal), so we
/// walk up the process tree asking `ps` until a real tty appears.
enum TerminalContext {
    struct Captured {
        var termProgram: String?
        var tmuxPane: String?
        var itermSession: String?
        var tty: String?
    }

    static func capture() -> Captured {
        let env = ProcessInfo.processInfo.environment
        var c = Captured()
        c.termProgram = env["LC_TERMINAL"] ?? env["TERM_PROGRAM"]
        if env["TMUX"] != nil {
            c.tmuxPane = env["TMUX_PANE"]
        }
        c.itermSession = env["ITERM_SESSION_ID"]
        c.tty = findAncestorTTY()
        return c
    }

    /// Walk PPIDs (≤4 levels) until a process with a real tty shows up.
    private static func findAncestorTTY() -> String? {
        var pid = getppid()
        for _ in 0..<4 {
            guard pid > 1 else { return nil }
            guard let out = ps(["-o", "tty=,ppid=", "-p", "\(pid)"]) else { return nil }
            let parts = out.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return nil }
            let tty = String(parts[0])
            if tty != "??" { return "/dev/\(tty)" }
            pid = Int32(parts[1]) ?? 1
        }
        return nil
    }

    private static func ps(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
