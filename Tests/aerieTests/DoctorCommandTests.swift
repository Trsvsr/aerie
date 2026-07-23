import XCTest
@testable import aerie

final class DoctorCommandTests: XCTestCase {
    func testUpToDateReportsNothing() {
        XCTAssertNil(DoctorCommand.updateMessage(latestTag: "v0.1.2", currentVersion: "0.1.2"))
    }

    func testOutdatedReportsUpdate() {
        let msg = DoctorCommand.updateMessage(latestTag: "v0.2.0", currentVersion: "0.1.2")
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("0.1.2"))
        XCTAssertTrue(msg!.contains("0.2.0"))
    }

    func testHandlesTagWithoutVPrefix() {
        // GitHub releases could in principle be tagged without the "v" —
        // don't choke on it either way.
        XCTAssertNil(DoctorCommand.updateMessage(latestTag: "0.1.2", currentVersion: "0.1.2"))
        XCTAssertNotNil(DoctorCommand.updateMessage(latestTag: "0.2.0", currentVersion: "0.1.2"))
    }

    /// Network failure, offline, timeout, malformed API response — all
    /// surface as a nil tag. doctor must stay silent, not crash or print
    /// garbage, when it can't reach GitHub.
    func testNilTagReportsNothing() {
        XCTAssertNil(DoctorCommand.updateMessage(latestTag: nil, currentVersion: "0.1.2"))
    }

    func testEmptyTagReportsNothing() {
        XCTAssertNil(DoctorCommand.updateMessage(latestTag: "v", currentVersion: "0.1.2"))
    }
}
