import XCTest
@testable import aerie

final class UsageTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerie-usage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testClaudeUsageFileParsing() throws {
        let f = tmp.appendingPathComponent("claude-usage.json")
        try #"{"captured_at": \#(Date().timeIntervalSince1970), "five_hour": {"used_percentage": 42.5, "resets_at": \#(Date().timeIntervalSince1970 + 3600)}, "seven_day": {"used_percentage": 71.0}}"#
            .write(to: f, atomically: true, encoding: .utf8)
        let usage = UsageReader.readClaude(path: f.path)
        XCTAssertEqual(usage?.provider, "claude")
        XCTAssertEqual(usage?.windows.count, 2)
        XCTAssertEqual(usage?.windows.first?.usedPercent, 42.5)
        XCTAssertFalse(usage!.isStale)
    }

    func testClaudeUsageMissingFileNil() {
        XCTAssertNil(UsageReader.readClaude(path: tmp.appendingPathComponent("nope.json").path))
    }

    func testCodexRolloutBackwardScan() throws {
        let day = tmp.appendingPathComponent("2026/07/19")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let f = day.appendingPathComponent("rollout-test.jsonl")
        // populated rate_limits mid-file, null later — backward scan must find the populated one
        let lines = [
            #"{"payload":{"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":10080,"resets_at":1785008665}}}}"#,
            #"{"payload":{"other":"stuff"}}"#,
            #"{"payload":{"rate_limits":null}}"#,
        ].joined(separator: "\n")
        try lines.write(to: f, atomically: true, encoding: .utf8)
        let usage = UsageReader.readCodex(sessionsDir: tmp.path)
        XCTAssertEqual(usage?.provider, "codex")
        XCTAssertEqual(usage?.windows.first?.usedPercent, 12.5)
        XCTAssertEqual(usage?.windows.first?.label, "7d")
    }

    func testCodexNoRolloutNil() {
        XCTAssertNil(UsageReader.readCodex(sessionsDir: tmp.path))
    }

    func testStatuslineWrapAndRestore() throws {
        let settings = tmp.appendingPathComponent("settings.json")
        try #"{"statusLine":{"type":"command","command":"bun run /x/statusline.ts"},"model":"opus"}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        try HooksPatcher.StatuslinePatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: settings)
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        var sl = (root["statusLine"] as! [String: Any])["command"] as! String
        XCTAssertTrue(sl.hasPrefix("/usr/local/bin/aerie statusline --chain"))
        XCTAssertTrue(sl.contains("bun run /x/statusline.ts"))
        XCTAssertEqual(root["model"] as? String, "opus")
        // idempotent
        try HooksPatcher.StatuslinePatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: settings)
        // restore
        try HooksPatcher.StatuslinePatcher.uninstall(settingsURL: settings)
        root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        sl = (root["statusLine"] as! [String: Any])["command"] as! String
        XCTAssertEqual(sl, "bun run /x/statusline.ts")
    }

    func testStatuslineInstallNoExisting() throws {
        let settings = tmp.appendingPathComponent("fresh.json")
        try #"{}"#.write(to: settings, atomically: true, encoding: .utf8)
        try HooksPatcher.StatuslinePatcher.install(binaryPath: "/bin/aerie", settingsURL: settings)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((root["statusLine"] as! [String: Any])["command"] as? String, "/bin/aerie statusline")
    }
}
