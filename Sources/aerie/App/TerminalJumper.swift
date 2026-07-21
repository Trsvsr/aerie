import AppKit

/// Focus the terminal pane a session lives in. Priority ladder:
/// tmux pane → iTerm2 tty-match → Terminal.app tty-match → activate the
/// host app → open the cwd. Every rung degrades gracefully to the next.
@MainActor
enum TerminalJumper {
    static func jump(to row: SessionRow) {
        let ref = row.terminal
        // 1. tmux: the pane id is the only handle that survives tmux's
        //    env-freezing (ITERM_SESSION_ID points at the launching pane).
        if let pane = ref?.tmuxPane, jumpTmux(pane: pane) {
            activateHostApp(ref)
            return
        }
        // 2/3. tty match inside the terminal app's scripting model
        if let tty = ref?.tty {
            let program = ref?.termProgram ?? ""
            if program.localizedCaseInsensitiveContains("iterm"),
               runAppleScript(itermScript(tty: tty)) {
                return
            }
            if program == "Apple_Terminal",
               runAppleScript(terminalAppScript(tty: tty)) {
                return
            }
        }
        // 4. at least raise the right app / place
        if activateHostApp(ref) { return }
        if let cwd = row.cwd {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        }
    }

    // MARK: rungs

    private static func jumpTmux(pane: String) -> Bool {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmux = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return false }
        // select the window containing the pane, then switch the client to it
        let select = run(tmux, ["select-window", "-t", pane])
        let switchOK = run(tmux, ["switch-client", "-t", pane])
        return select || switchOK
    }

    @discardableResult
    private static func activateHostApp(_ ref: TerminalRef?) -> Bool {
        let bundleIDs: [String: String] = [
            "iTerm2": "com.googlecode.iterm2",
            "iTerm.app": "com.googlecode.iterm2",
            "Apple_Terminal": "com.apple.Terminal",
            "WarpTerminal": "dev.warp.Warp-Stable",
            "ghostty": "com.mitchellh.ghostty",
            "WezTerm": "com.github.wez.wezterm",
            "kitty": "net.kovidgoyal.kitty",
            "vscode": "com.microsoft.VSCode",
        ]
        guard let program = ref?.termProgram,
              let bundleID = bundleIDs[program] ?? bundleIDs.first(where: {
                  program.localizedCaseInsensitiveContains($0.key)
              })?.value,
              let app = NSRunningApplication.runningApplications(
                  withBundleIdentifier: bundleID).first
        else { return false }
        return app.activate()
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select s
                            tell t to select
                            select w
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    private static func terminalAppScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set frontmost of w to true
                        activate
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    /// Runs an AppleScript; true only if it found and focused the target.
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error {
            // most common: TCC automation consent not granted
            log("terminal jump applescript failed: \(error)")
            return false
        }
        return result.stringValue == "found"
    }

    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
