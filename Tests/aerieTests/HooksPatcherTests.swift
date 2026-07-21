import XCTest
@testable import aerie

final class HooksPatcherTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerie-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Shape mirrors the real ~/.claude/settings.json: claude-rpc hooks on the
    /// same events plus unrelated top-level keys.
    private func writeFixture() -> URL {
        let fixture: [String: Any] = [
            "model": "opus",
            "statusLine": ["type": "command", "command": "whatever"],
            "hooks": [
                "Stop": [[
                    "matcher": "",
                    "hooks": [["type": "command",
                               "command": "node /opt/homebrew/Cellar/claude-rpc/1.3.1/src/hook.js Stop"]],
                ]],
                "PreToolUse": [[
                    "matcher": "",
                    "hooks": [["type": "command",
                               "command": "node /opt/homebrew/Cellar/claude-rpc/1.3.1/src/hook.js PreToolUse"]],
                ]],
            ],
        ]
        let url = tmp.appendingPathComponent("settings.json")
        let data = try! JSONSerialization.data(withJSONObject: fixture)
        try! data.write(to: url)
        return url
    }

    private func readBack(_ url: URL) -> [String: Any] {
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testInstallAppendsWithoutClobbering() throws {
        let url = writeFixture()
        let changed = try HooksPatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: url)
        XCTAssertTrue(changed)

        let root = readBack(url)
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertNotNil(root["statusLine"])

        let hooks = root["hooks"] as! [String: Any]
        // all 7 events present
        for event in HooksPatcher.events {
            let entries = hooks[event] as! [[String: Any]]
            let ours = entries.filter { e in
                ((e["hooks"] as! [[String: Any]]).first?["command"] as! String)
                    .contains("aerie hook \(event)")
            }
            XCTAssertEqual(ours.count, 1, "missing aerie entry for \(event)")
        }
        // claude-rpc entries untouched
        let stop = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as! String).contains("claude-rpc"))
    }

    func testInstallIsIdempotent() throws {
        let url = writeFixture()
        _ = try HooksPatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: url)
        let changedAgain = try HooksPatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: url)
        XCTAssertFalse(changedAgain)
    }

    func testUninstallRemovesOnlyOurs() throws {
        let url = writeFixture()
        _ = try HooksPatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: url)
        // simulate the binary having moved: uninstall matches on "aerie hook "
        let changed = try HooksPatcher.uninstall(binaryPath: "/somewhere/else/aerie", settingsURL: url)
        XCTAssertTrue(changed)

        let hooks = readBack(url)["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 1)
        XCTAssertTrue(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as! String).contains("claude-rpc"))
        // events that only had our entry are dropped entirely
        XCTAssertNil(hooks["SessionStart"])
    }

    func testInstallIntoMissingFile() throws {
        let url = tmp.appendingPathComponent("fresh.json")
        let changed = try HooksPatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: url)
        XCTAssertTrue(changed)
        let hooks = readBack(url)["hooks"] as! [String: Any]
        XCTAssertEqual(hooks.count, HooksPatcher.events.count)
    }
}

extension HooksPatcherTests {
    func testCopilotManifestGeneration() {
        let manifest = ToolIntegration.copilot.copilotManifest(binaryPath: "/usr/local/bin/aerie")
        XCTAssertTrue(manifest.contains(#""PreToolUse""#))
        XCTAssertTrue(manifest.contains("aerie hook PreToolUse --source copilot"))
        // valid JSON
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(manifest.utf8)))
    }
}
