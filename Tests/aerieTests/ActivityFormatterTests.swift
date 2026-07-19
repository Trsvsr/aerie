import XCTest
@testable import aerie

final class ActivityFormatterTests: XCTestCase {
    private func fmt(
        tool: String?, file: String? = nil, command: String? = nil,
        description: String? = nil, pattern: String? = nil, url: String? = nil
    ) -> String {
        ActivityFormatter.format(
            toolName: tool, file: file, command: command,
            description: description, pattern: pattern, url: url)
    }

    func testTable() {
        XCTAssertEqual(fmt(tool: "Edit", file: "/a/b/Foo.swift"), "editing Foo.swift")
        XCTAssertEqual(fmt(tool: "MultiEdit", file: "/a/Foo.swift"), "editing Foo.swift")
        XCTAssertEqual(fmt(tool: "Write", file: "/a/new.md"), "writing new.md")
        XCTAssertEqual(fmt(tool: "Read", file: "/a/conf.json"), "reading conf.json")
        XCTAssertEqual(fmt(tool: "Bash", command: "swift build"), "running: swift build")
        XCTAssertEqual(
            fmt(tool: "Bash", command: "swift build", description: "Build the project"),
            "running: Build the project")
        XCTAssertEqual(fmt(tool: "Grep", pattern: "TODO"), "searching TODO")
        XCTAssertEqual(fmt(tool: "WebFetch", url: "https://api.github.com/x"), "fetching api.github.com")
        XCTAssertEqual(fmt(tool: "WebSearch"), "searching web")
        XCTAssertEqual(fmt(tool: "Task", description: "Explore codebase"), "agent: Explore codebase")
        XCTAssertEqual(fmt(tool: "TodoWrite"), "updating plan")
        XCTAssertEqual(fmt(tool: "SomethingNew"), "using SomethingNew")
        XCTAssertEqual(fmt(tool: nil), "working")
    }

    func testMCPToolNames() {
        XCTAssertEqual(fmt(tool: "mcp__notion__notion-search"), "notion-search (notion)")
    }

    func testBashCommandFlattenedAndTruncated() {
        let long = "for f in $(ls); do\n  echo $f\n  cat $f | grep -c thing\ndone "
            + String(repeating: "extra ", count: 30)
        let out = fmt(tool: "Bash", command: long)
        XCTAssertTrue(out.hasPrefix("running: for f in $(ls); do echo"))
        XCTAssertFalse(out.contains("\n"))
        XCTAssertLessThanOrEqual(out.count, "running: ".count + 120)
    }

    func testNeedsInputLine() {
        XCTAssertEqual(
            ActivityFormatter.needsInputLine(message: "Claude needs your permission to use Bash"),
            "needs permission: Bash")
        XCTAssertEqual(
            ActivityFormatter.needsInputLine(message: "Claude is waiting for your input"),
            "waiting for you")
        XCTAssertEqual(ActivityFormatter.needsInputLine(message: nil), "needs input")
        XCTAssertEqual(ActivityFormatter.needsInputLine(message: "Permission required"), "needs permission")
    }

    func testTruncateMiddleEllipsis() {
        XCTAssertEqual(ActivityFormatter.truncate("short", max: 36), "short")
        let long = String(repeating: "a", count: 30) + String(repeating: "b", count: 30)
        let out = ActivityFormatter.truncate(long, max: 21)
        XCTAssertEqual(out.count, 21)
        XCTAssertTrue(out.contains("…"))
        XCTAssertTrue(out.hasPrefix("aaa"))
        XCTAssertTrue(out.hasSuffix("bbb"))
    }
}
