import XCTest
@testable import eaves

final class SessionStoreTests: XCTestCase {
    var clock: Date!
    var store: SessionStore!

    override func setUp() {
        clock = Date(timeIntervalSince1970: 1_000_000)
        store = SessionStore(now: { self.clock })
    }

    private func event(
        _ event: String, session: String = "s1", cwd: String? = "/Users/t/src/demo",
        tool: String? = nil, file: String? = nil, command: String? = nil,
        notificationType: String? = nil, message: String? = nil
    ) {
        store.apply(WireRequest(
            cmd: "event", sessionID: session, event: event, cwd: cwd,
            toolName: tool, toolFile: file, toolCommand: command,
            notificationType: notificationType, message: message))
    }

    func testLifecycle() {
        event("SessionStart")
        XCTAssertEqual(store.sessions["s1"]?.state, .idle)
        XCTAssertEqual(store.aggregate(), .off)

        event("UserPromptSubmit")
        XCTAssertEqual(store.sessions["s1"]?.state, .working)
        XCTAssertEqual(store.sessions["s1"]?.activity, "thinking…")
        XCTAssertEqual(store.aggregate(), .working)

        event("PreToolUse", tool: "Edit", file: "/x/y/Daemon.swift")
        XCTAssertEqual(store.sessions["s1"]?.activity, "editing Daemon.swift")

        event("PostToolUse", tool: "Edit")
        XCTAssertEqual(store.sessions["s1"]?.activity, "thinking…")

        event("Stop")
        XCTAssertEqual(store.sessions["s1"]?.state, .idle)
        XCTAssertEqual(store.aggregate(), .off)

        event("SessionEnd")
        XCTAssertNil(store.sessions["s1"])
    }

    func testNeedsInputFromNotification() {
        event("UserPromptSubmit")
        event("Notification", notificationType: "permission_prompt",
              message: "Claude needs your permission to use Bash")
        XCTAssertEqual(store.sessions["s1"]?.state, .needsInput)
        XCTAssertEqual(store.sessions["s1"]?.activity, "needs permission: Bash")
        XCTAssertEqual(store.aggregate(), .needsInput)
    }

    func testIrrelevantNotificationOnlyRefreshes() {
        event("UserPromptSubmit")
        event("Notification", notificationType: "something_else")
        XCTAssertEqual(store.sessions["s1"]?.state, .working)
    }

    func testIdleNotificationGoesIdleNotRed() {
        event("UserPromptSubmit")
        event("Notification", notificationType: "idle_prompt",
              message: "Claude is waiting for your input")
        XCTAssertEqual(store.sessions["s1"]?.state, .idle)
        XCTAssertEqual(store.aggregate(), .off)
    }

    func testUnknownSessionEventCreatesEntry() {
        // Events can arrive for sessions started before the app launched.
        event("PreToolUse", tool: "Bash", command: "ls")
        XCTAssertEqual(store.sessions["s1"]?.state, .working)
    }

    func testCwdRetainedWhenLaterEventOmitsIt() {
        event("SessionStart", cwd: "/Users/t/src/demo")
        event("UserPromptSubmit", cwd: nil)
        XCTAssertEqual(store.sessions["s1"]?.cwd, "/Users/t/src/demo")
    }

    func testOrderingNeedsInputFirstThenRecency() {
        event("UserPromptSubmit", session: "working-old", cwd: "/a")
        clock = clock.addingTimeInterval(10)
        event("UserPromptSubmit", session: "working-new", cwd: "/b")
        clock = clock.addingTimeInterval(10)
        event("Notification", session: "blocked", cwd: "/c", notificationType: "permission_prompt")
        clock = clock.addingTimeInterval(10)
        event("Stop", session: "idle1", cwd: "/d")

        let ids = store.rows().map(\.id)
        XCTAssertEqual(ids, ["blocked", "working-new", "working-old", "idle1"])
    }

    func testSummaryPrefersBlockedSession() {
        event("PreToolUse", session: "busy", cwd: "/Users/t/src/busyproj", tool: "Bash", command: "make")
        event("Notification", session: "blocked", cwd: "/Users/t/src/blockedproj",
              notificationType: "permission_prompt", message: "Claude needs your permission to use Edit")
        XCTAssertEqual(store.summary(), "blockedproj: needs permission: Edit")
    }

    func testSummaryNilWhenOff() {
        event("SessionStart")
        XCTAssertNil(store.summary())
    }

    func testSweepDemotesAndReaps() {
        event("UserPromptSubmit")
        clock = clock.addingTimeInterval(16 * 60)   // > working TTL (15m)
        store.sweep()
        XCTAssertEqual(store.sessions["s1"]?.state, .idle)

        clock = clock.addingTimeInterval(61 * 60)   // > idle TTL (60m)
        store.sweep()
        XCTAssertNil(store.sessions["s1"])
    }

    func testSweepKeepsFreshSessions() {
        event("UserPromptSubmit")
        clock = clock.addingTimeInterval(60)
        store.sweep()
        XCTAssertEqual(store.sessions["s1"]?.state, .working)
    }
}
