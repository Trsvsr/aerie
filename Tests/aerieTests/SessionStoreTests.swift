import XCTest
@testable import aerie

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

extension SessionStoreTests {
    private func approvalReq(
        session: String = "s1", source: String = "claude", cwd: String = "/tmp/proj",
        tool: String = "Bash", inputJSON: String = #"{"command":"rm -rf build"}"#,
        canAllow: Bool = true
    ) -> WireRequest {
        WireRequest(
            cmd: "approval", sessionID: session, source: source, cwd: cwd,
            toolName: tool, toolInputJSON: inputJSON, canAllow: canAllow)
    }

    func testApprovalFlipsSessionToNeedsInput() {
        store.apply(WireRequest(cmd: "event", sessionID: "s1", event: "UserPromptSubmit", cwd: "/tmp/proj"))
        store.addApproval(approvalReq(), id: "a1", timeout: 50)
        XCTAssertEqual(store.sessions["s1"]?.state, .needsInput)
        XCTAssertTrue(store.sessions["s1"]!.activity.hasPrefix("awaiting approval"))
        XCTAssertEqual(store.approvals.count, 1)
        XCTAssertEqual(store.aggregate(), .needsInput)
    }

    func testApprovalResolveAllowReturnsToWorking() {
        store.addApproval(approvalReq(), id: "a1", timeout: 50)
        let resolved = store.resolveApproval(id: "a1", decision: "allow")
        XCTAssertEqual(resolved?.id, "a1")
        XCTAssertEqual(store.sessions["s1"]?.state, .working)
        XCTAssertTrue(store.approvals.isEmpty)
    }

    func testApprovalResolveDenyLeavesNeedsInput() {
        store.addApproval(approvalReq(), id: "a1", timeout: 50)
        _ = store.resolveApproval(id: "a1", decision: "deny")
        XCTAssertEqual(store.sessions["s1"]?.state, .needsInput)
    }

    func testApprovalFIFOOrdering() {
        store.addApproval(approvalReq(session: "s1"), id: "a1", timeout: 50)
        clock = clock.addingTimeInterval(1)
        store.addApproval(approvalReq(session: "s2", cwd: "/tmp/two"), id: "a2", timeout: 50)
        XCTAssertEqual(store.approvals.map(\.id), ["a1", "a2"])
    }

    func testApprovalExpiry() {
        store.addApproval(approvalReq(), id: "a1", timeout: 50)
        clock = clock.addingTimeInterval(51)
        let expired = store.expireApprovals()
        XCTAssertEqual(expired, ["a1"])
        XCTAssertTrue(store.approvals.isEmpty)
    }

    func testResolveUnknownApprovalIsNil() {
        XCTAssertNil(store.resolveApproval(id: "nope", decision: "allow"))
    }

    func testCanAllowCarriedThrough() {
        store.addApproval(approvalReq(source: "cursor", canAllow: false), id: "a1", timeout: 50)
        XCTAssertEqual(store.approvals.first?.canAllow, false)
    }

    func testResetClearsApprovals() {
        store.addApproval(approvalReq(), id: "a1", timeout: 50)
        store.reset()
        XCTAssertTrue(store.approvals.isEmpty)
    }
}
