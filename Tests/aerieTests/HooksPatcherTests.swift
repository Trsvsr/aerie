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

    /// A binary-path change (e.g. dev build path -> Homebrew Cellar path, or
    /// one Cellar version -> the next after brew upgrade) must correct the
    /// existing entry in place, not leave it stale pointing at a binary that
    /// may no longer exist. Regression test for a real bug: entryIsOurs
    /// matches on the generic "aerie hook " marker, so a plain re-run of
    /// install alone (no uninstall first) previously left the old path
    /// untouched once any "ours" entry — at any path — was already present.
    func testInstallUpdatesStaleBinaryPath() throws {
        let url = writeFixture()
        let oldPath = "/Users/trevor/.local/bin/aerie"
        let newPath = "/opt/homebrew/Cellar/aerie/0.1.2/bin/aerie"
        _ = try HooksPatcher.install(binaryPath: oldPath, settingsURL: url)

        let changed = try HooksPatcher.install(binaryPath: newPath, settingsURL: url)
        XCTAssertTrue(changed, "install must report a change when correcting a stale path")

        let hooks = readBack(url)["hooks"] as! [String: Any]
        for event in HooksPatcher.events {
            let entries = hooks[event] as! [[String: Any]]
            let ours = entries.filter { e in
                ((e["hooks"] as! [[String: Any]]).first?["command"] as! String)
                    .contains("aerie hook \(event)")
            }
            XCTAssertEqual(ours.count, 1, "expected exactly one aerie entry for \(event)")
            let cmd = (ours[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
            XCTAssertTrue(cmd.hasPrefix(newPath), "expected updated path for \(event), got: \(cmd)")
            XCTAssertFalse(cmd.hasPrefix(oldPath), "stale old path left in place for \(event)")
        }
        // claude-rpc entries still untouched throughout
        let stop = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2)
    }

    func testInstallRejectsMalformedJSON() throws {
        let url = tmp.appendingPathComponent("settings.json")
        try Data("{ not valid json".utf8).write(to: url)
        XCTAssertThrowsError(try HooksPatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: url)) { error in
            XCTAssertTrue((error as NSError).localizedDescription.contains("not valid JSON"))
        }
        // refuses to touch it — original malformed content preserved verbatim
        let stillThere = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(stillThere, "{ not valid json")
    }

    /// Regression test for a real, live bug: a bare `aerie uninstall` (run
    /// e.g. during a LaunchAgent/binary-path switch, with no intent to touch
    /// the separately-toggled approval hook at all) was silently deleting
    /// the --approve-flagged PreToolUse entry that ToolIntegration.
    /// installApproval manages independently, and the following `aerie
    /// install` never restored it — Claude Code permission prompts stopped
    /// reaching the notch with no error anywhere. Confirmed happening live
    /// today from repeated uninstall/install cycles during binary swaps.
    func testUninstallNeverTouchesApprovalEntry() throws {
        let url = writeFixture()
        _ = try HooksPatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: url)

        // simulate ToolIntegration.installApproval's own entry shape
        var root = readBack(url)
        var hooks = root["hooks"] as! [String: Any]
        var pre = hooks["PreToolUse"] as! [[String: Any]]
        pre.append([
            "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
            "hooks": [["type": "command",
                       "command": "/usr/local/bin/aerie hook PreToolUse --approve --source claude",
                       "timeout": 60]],
        ])
        hooks["PreToolUse"] = pre
        root["hooks"] = hooks
        try! JSONSerialization.data(withJSONObject: root).write(to: url)

        _ = try HooksPatcher.uninstall(binaryPath: "/usr/local/bin/aerie", settingsURL: url)

        let afterUninstall = readBack(url)["hooks"] as! [String: Any]
        let preAfter = afterUninstall["PreToolUse"] as! [[String: Any]]
        XCTAssertTrue(preAfter.contains { e in
            ((e["hooks"] as! [[String: Any]]).first?["command"] as! String).contains("--approve")
        }, "uninstall must not remove the independently-managed approval entry")

        // and a subsequent install (e.g. after switching binary paths) must
        // not replace/collapse it into the plain entry either
        _ = try HooksPatcher.install(binaryPath: "/opt/homebrew/bin/aerie", settingsURL: url)
        let afterReinstall = readBack(url)["hooks"] as! [String: Any]
        let preFinal = afterReinstall["PreToolUse"] as! [[String: Any]]
        let approvalEntries = preFinal.filter { e in
            ((e["hooks"] as! [[String: Any]]).first?["command"] as! String).contains("--approve")
        }
        XCTAssertEqual(approvalEntries.count, 1, "approval entry must survive a plain install untouched")
    }

    func testInstallWritesThroughSymlink() throws {
        // Simulates a dotfiles-managed settings.json: the real file lives
        // elsewhere and ~/.claude/settings.json is a symlink to it.
        let realDir = tmp.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realFile = realDir.appendingPathComponent("claude-settings.json")
        try JSONSerialization.data(withJSONObject: ["model": "opus"])
            .write(to: realFile)

        let linkPath = tmp.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: realFile)

        let changed = try HooksPatcher.install(binaryPath: "/usr/local/bin/aerie", settingsURL: linkPath)
        XCTAssertTrue(changed)

        // the symlink itself must still be a symlink, not replaced by a
        // plain file (which would silently detach it from the dotfiles repo)
        let attrs = try FileManager.default.attributesOfItem(atPath: linkPath.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)

        // and the real target file must have received the actual write
        let real = readBack(realFile)
        XCTAssertEqual(real["model"] as? String, "opus")
        XCTAssertNotNil(real["hooks"])
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
