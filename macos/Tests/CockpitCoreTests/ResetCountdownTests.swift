import XCTest
@testable import CockpitCore

final class ResetCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func countdown(after seconds: TimeInterval) -> String {
        ResetCountdown.text(until: now.addingTimeInterval(seconds), now: now)
    }

    func testDaysAndHours() {
        XCTAssertEqual(countdown(after: 2 * 86_400 + 5 * 3_600 + 59 * 60), "resets in 2d 5h")
        XCTAssertEqual(countdown(after: 86_400), "resets in 1d 0h")
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(countdown(after: 3 * 3_600 + 12 * 60), "resets in 3h 12m")
        XCTAssertEqual(countdown(after: 3_600), "resets in 1h 0m")
    }

    func testMinutesOnly() {
        XCTAssertEqual(countdown(after: 12 * 60 + 40), "resets in 12m")
        XCTAssertEqual(countdown(after: 60), "resets in 1m")
    }

    func testUnderAMinute() {
        XCTAssertEqual(countdown(after: 59), "resets in <1m")
    }

    func testResetTimeReachedOrPassed() {
        XCTAssertEqual(countdown(after: 0), "resets now")
        XCTAssertEqual(countdown(after: -300), "resets now")
    }
}
