import Foundation

/// `aerie statusline [--chain '<original command>']` — registered as Claude
/// Code's statusLine command. Claude pipes a status JSON on stdin that
/// includes `rate_limits` (the ONLY local source of subscription quota);
/// we tee that to ~/.aerie/claude-usage.json, then hand stdin to the user's
/// original statusline so their display is untouched (byte-for-byte).
enum StatuslineCommand {
    static func run(args: [String]) -> Never {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()

        // Keep the last raw payload around for schema debugging — whether
        // Claude ever calls us, and whether the payload actually carries
        // rate_limits, was previously invisible (no log line, no receipt).
        ensurePrivateAerieDirectory()
        let payloadDir = aerieDirectory().appendingPathComponent("last-payloads")
        try? FileManager.default.createDirectory(
            at: payloadDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: payloadDir.path)
        let payloadDest = payloadDir.appendingPathComponent("statusline.json")
        try? stdin.prefix(4096).write(to: payloadDest)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: payloadDest.path)

        // tee rate_limits (best-effort; display must never break on failure)
        if let obj = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
           let rl = obj["rate_limits"] as? [String: Any] {
            var out: [String: Any] = ["captured_at": Date().timeIntervalSince1970]
            for key in ["five_hour", "seven_day"] {
                if let w = rl[key] as? [String: Any] { out[key] = w }
            }
            if out.count > 1 {
                ensurePrivateAerieDirectory()
                let dest = aerieDirectory().appendingPathComponent("claude-usage.json")
                if let data = try? JSONSerialization.data(withJSONObject: out) {
                    try? data.write(to: dest, options: .atomic)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: dest.path)
                }
            }
        }

        // chain the user's original statusline, stdout passthrough verbatim
        if let i = args.firstIndex(of: "--chain"), i + 1 < args.count {
            let chained = args[i + 1]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", chained]
            let inPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = FileHandle.standardOutput
            p.standardError = FileHandle.standardError
            do {
                try p.run()
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
                p.waitUntilExit()
                exit(p.terminationStatus)
            } catch {
                // fall through to our own minimal line
            }
        }

        // no chain (or it failed): emit a minimal line of our own
        var parts: [String] = []
        if let obj = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] {
            if let model = obj["model"] as? [String: Any],
               let name = model["display_name"] as? String ?? model["id"] as? String {
                parts.append(name)
            } else if let model = obj["model"] as? String {
                parts.append(model)
            }
            if let rl = obj["rate_limits"] as? [String: Any] {
                if let fh = rl["five_hour"] as? [String: Any],
                   let pct = fh["used_percentage"] as? Double {
                    parts.append("5h \(Int(pct))%")
                }
                if let sd = rl["seven_day"] as? [String: Any],
                   let pct = sd["used_percentage"] as? Double {
                    parts.append("7d \(Int(pct))%")
                }
            }
        }
        print(parts.isEmpty ? "aerie" : parts.joined(separator: " · "))
        exit(0)
    }
}
