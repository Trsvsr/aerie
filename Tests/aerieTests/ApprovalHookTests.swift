import XCTest
@testable import aerie

final class ApprovalHookTests: XCTestCase {
    // MARK: decisionOutput — the fail-open output contract. "none" (daemon
    // absent, timeout, malformed response — anything that isn't a real
    // decision) must produce nil for every source, so the tool's own
    // prompt flow always takes over rather than aerie emitting something
    // that could be mistaken for a real decision.

    func testNoneDecisionNeverProducesOutputForAnySource() {
        for source in ["claude", "codex", "cursor", "opencode", "unknown-tool"] {
            XCTAssertNil(ApprovalHook.decisionOutput(source: source, decision: "none"),
                         "fail-open must emit nothing for source \(source)")
        }
    }

    func testClaudeDecisionOutput() {
        XCTAssertEqual(
            ApprovalHook.decisionOutput(source: "claude", decision: "allow"),
            #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"approved in aerie"}}"#)
        XCTAssertEqual(
            ApprovalHook.decisionOutput(source: "claude", decision: "deny"),
            #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"denied in aerie"}}"#)
    }

    func testCodexDecisionOutput() {
        XCTAssertEqual(
            ApprovalHook.decisionOutput(source: "codex", decision: "allow"),
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        XCTAssertEqual(
            ApprovalHook.decisionOutput(source: "codex", decision: "deny"),
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in aerie."}}}"#)
    }

    func testCursorOnlySupportsDeny() {
        // cursor's "allow" is unreliable by design — nil lets cursor's own
        // prompt take over rather than aerie claiming an allow it can't back.
        XCTAssertNil(ApprovalHook.decisionOutput(source: "cursor", decision: "allow"))
        XCTAssertEqual(
            ApprovalHook.decisionOutput(source: "cursor", decision: "deny"),
            #"{"permission":"deny","userMessage":"Denied in aerie."}"#)
    }

    func testUnknownSourceOrDecisionProducesNoOutput() {
        XCTAssertNil(ApprovalHook.decisionOutput(source: "opencode", decision: "allow"))
        XCTAssertNil(ApprovalHook.decisionOutput(source: "claude", decision: "garbage"))
    }

    // MARK: AllowlistMirror.matches — rule-shape parsing

    func testAllowlistExactToolMatch() {
        XCTAssertTrue(AllowlistMirror.matches(rule: "Read", tool: "Read", command: nil))
        XCTAssertFalse(AllowlistMirror.matches(rule: "Read", tool: "Write", command: nil))
    }

    func testAllowlistWildcardMatch() {
        XCTAssertTrue(AllowlistMirror.matches(rule: "Bash(*)", tool: "Bash", command: "rm -rf /"))
        XCTAssertFalse(AllowlistMirror.matches(rule: "Bash(*)", tool: "Write", command: nil))
    }

    func testAllowlistPrefixMatch() {
        XCTAssertTrue(AllowlistMirror.matches(rule: "Bash(git:*)", tool: "Bash", command: "git status"))
        XCTAssertTrue(AllowlistMirror.matches(rule: "Bash(git:*)", tool: "Bash", command: "git"))
        XCTAssertFalse(AllowlistMirror.matches(rule: "Bash(git:*)", tool: "Bash", command: "github-cli status"))
        XCTAssertFalse(AllowlistMirror.matches(rule: "Bash(git:*)", tool: "Bash", command: nil))
    }

    func testAllowlistExactCommandMatch() {
        XCTAssertTrue(AllowlistMirror.matches(rule: "Bash(npm test)", tool: "Bash", command: "npm test"))
        XCTAssertFalse(AllowlistMirror.matches(rule: "Bash(npm test)", tool: "Bash", command: "npm test --watch"))
    }

    func testAllowlistMalformedRuleNeverMatches() {
        // no closing paren, or tool name mismatch inside the parens — both
        // must fail conservatively (fall through to the notch), never crash.
        XCTAssertFalse(AllowlistMirror.matches(rule: "Bash(git:*", tool: "Bash", command: "git status"))
        XCTAssertFalse(AllowlistMirror.matches(rule: "Write(foo)", tool: "Bash", command: "foo"))
    }
}
