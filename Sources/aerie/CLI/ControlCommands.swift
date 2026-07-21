import Foundation

func controlRequest(_ req: WireRequest) -> Never {
    do {
        let resp = try SocketClient.request(req, timeoutMS: 1000)
        if let data = try? JSONEncoder().encode(resp), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        exit(resp.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(
            Data("aerie: app not reachable at \(socketPath()) (\(error))\n".utf8))
        exit(1)
    }
}

/// `aerie approve <id>` / `aerie deny <id>` — resolve a pending approval
/// from the command line (testing, scripting). Same-user trust boundary.
func approvalResolveCommand(decision: String, args: [String]) -> Never {
    guard let id = args.first(where: { !$0.hasPrefix("--") }) else {
        // no id: resolve the oldest pending approval
        if let resp = try? SocketClient.request(WireRequest(cmd: "status"), timeoutMS: 1000),
           let first = resp.approvals?.first {
            controlRequest(WireRequest(cmd: "approval_resolve",
                                       approvalID: first.id, decision: decision))
        }
        print("usage: aerie \(decision == "allow" ? "approve" : "deny") <approval-id>  (no pending approvals)")
        exit(1)
    }
    controlRequest(WireRequest(cmd: "approval_resolve", approvalID: id, decision: decision))
}

func statusCommand() -> Never {
    do {
        let resp = try SocketClient.request(WireRequest(cmd: "status"), timeoutMS: 1000)
        print("aggregate: \(resp.aggregate ?? "?")")
        if let s = resp.summary { print("summary:   \(s)") }
        for a in resp.approvals ?? [] {
            let input = a.toolInputJSON.split(whereSeparator: \.isNewline)
                .joined(separator: " ").prefix(80)
            print("  APPROVAL \(a.id.prefix(8)) [\(a.source)] \(a.project) \(a.toolName ?? "?") — \(input) (\(a.expiresInS)s left)")
        }
        for row in resp.sessions ?? [] {
            let age = row.ageSeconds < 120 ? "\(row.ageSeconds)s" : "\(row.ageSeconds / 60)m"
            let model = row.model.map { " [\($0)]" } ?? ""
            print("  [\(row.state)] \(row.project)\(model) — \(row.activity) (\(age) ago, \(row.id.prefix(8)))")
        }
        if (resp.sessions ?? []).isEmpty { print("  (no sessions)") }
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("aerie: app not reachable at \(socketPath()) (\(error))\n".utf8))
        exit(1)
    }
}

/// `aerie send --session s1 --event PreToolUse [--source claude] [--cwd DIR]
///  [--tool Edit] [--file F] [--command C] [--description D]
///  [--notification-type T] [--message M] [--model M]`
/// Fake-event injector for demos and manual testing.
func sendCommand(_ args: [String]) -> Never {
    func val(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    guard let session = val("--session"), let event = val("--event") else {
        print("usage: aerie send --session ID --event NAME [--source TOOL] [--cwd DIR] [--tool NAME] [--file F] [--command C] [--description D] [--notification-type T] [--message M] [--model M]")
        exit(1)
    }
    controlRequest(WireRequest(
        cmd: "event", sessionID: session, event: event,
        source: val("--source"),
        cwd: val("--cwd"), toolName: val("--tool"), toolFile: val("--file"),
        toolCommand: val("--command"), toolDescription: val("--description"),
        toolPattern: val("--pattern"), toolURL: val("--url"),
        notificationType: val("--notification-type"), message: val("--message"),
        model: val("--model")))
}
