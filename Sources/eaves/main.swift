import Foundation

// Hand-rolled CLI — small enough that swift-argument-parser isn't worth a dep.

let usage = """
eaves — Claude Code agent status in the MacBook notch

usage:
  eaves [app]                       run the notch HUD (socket listener included)
  eaves app --headless              run the socket listener without UI (dev)
  eaves hook <EventName>            (reads Claude Code hook JSON on stdin)
  eaves install [--dry-run]         install LaunchAgent + Claude Code hooks
  eaves uninstall                   remove LaunchAgent + hooks
  eaves status                      show live sessions
  eaves send --session ID --event NAME [...]   inject a fake event
  eaves reset | quit
"""

func currentBinaryPath() -> String {
    // Resolve symlinks so hooks/plist point at the real binary.
    let raw = CommandLine.arguments[0]
    let url = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    return url.resolvingSymlinksInPath().standardizedFileURL.path
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "app"

switch cmd {
case "app":
    if args.contains("--headless") {
        runHeadless()
    } else {
        runApp()
    }

case "hook":
    HookCommand.run(args: Array(args.dropFirst()))

case "install":
    let dryRun = args.contains("--dry-run")
    let bin = currentBinaryPath()
    do {
        let changed = try HooksPatcher.install(binaryPath: bin, dryRun: dryRun)
        if dryRun {
            print(changed ? "(dry run — no changes written)" : "hooks already installed")
            print("would install LaunchAgent at \(LaunchAgent.plistURL().path) → \(bin) app")
        } else {
            print(changed ? "hooks installed in ~/.claude/settings.json" : "hooks already installed")
            try LaunchAgent.install(binaryPath: bin)
            print("LaunchAgent installed and started (\(LaunchAgent.label))")
            print("note: restart running Claude Code sessions to pick up the new hooks")
        }
    } catch {
        FileHandle.standardError.write(Data("eaves: install failed: \(error)\n".utf8))
        exit(1)
    }

case "uninstall":
    LaunchAgent.uninstall()
    do {
        let changed = try HooksPatcher.uninstall(binaryPath: currentBinaryPath())
        print(changed ? "hooks removed from ~/.claude/settings.json" : "no eaves hooks found")
    } catch {
        FileHandle.standardError.write(Data("eaves: hook removal failed: \(error)\n".utf8))
    }
    print("LaunchAgent removed")

case "status":
    statusCommand()
case "reset":
    controlRequest(WireRequest(cmd: "reset"))
case "quit":
    controlRequest(WireRequest(cmd: "quit"))
case "send":
    sendCommand(args)

case "-h", "--help", "help":
    print(usage)

default:
    print(usage)
    exit(1)
}

/// Socket listener + state without any UI; prints snapshots to stderr.
func runHeadless() {
    let core = EavesCore()
    core.onSnapshot = { snap in
        log("snapshot: \(snap.aggregate.rawValue) — \(snap.summary ?? "-") (\(snap.rows.count) sessions)")
    }
    core.onQuit = { exit(0) }
    do {
        try core.start()
    } catch {
        log("fatal: \(error)")
        exit(1)
    }
    log("headless core listening at \(socketPath())")
    dispatchMain()
}
