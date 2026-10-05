import XCTest
@testable import CockpitCore

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, zone: String) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

final class UsageParserTests: XCTestCase {
    private let newYork = "America/New_York"
    private var now: Date { date(2026, 10, 5, 12, 0, zone: newYork) }

    func testParsesEveryUsageLineOfARealReport() {
        let report = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 12% used · resets Oct 5 at 2:45pm (America/New_York)
        Current week (all models): 34% used · resets Oct 8 at 9am (America/New_York)
        Current week (Fable): 5% used · resets Oct 8 at 9am (America/New_York)

        What's contributing to your limits usage?
        Last 24h · 40 requests · 5 sessions
          30% of your usage was at >150k context
        """

        XCTAssertEqual(UsageParser.parse(report, now: now), [
            UsageMeter(label: "SESSION", percentUsed: 12, reset: .at(date(2026, 10, 5, 14, 45, zone: newYork))),
            UsageMeter(label: "WEEK", percentUsed: 34, reset: .at(date(2026, 10, 8, 9, 0, zone: newYork))),
            UsageMeter(label: "WEEK · FABLE", percentUsed: 5, reset: .at(date(2026, 10, 8, 9, 0, zone: newYork))),
        ])
    }

    func testReadsResetTimeInTheZoneItNames() {
        let meters = UsageParser.parse("Current session: 5% used · resets Oct 5 at 3pm (Asia/Tokyo)", now: now)

        XCTAssertEqual(meters.first?.reset, .at(date(2026, 10, 5, 6, 0, zone: "UTC")))
    }

    func testTwelveOClockIsMidnightForAmAndNoonForPm() {
        let midnight = UsageParser.parse("Current session: 5% used · resets Oct 6 at 12am (UTC)", now: now)
        let noon = UsageParser.parse("Current session: 5% used · resets Oct 6 at 12:30pm (UTC)", now: now)

        XCTAssertEqual(midnight.first?.reset, .at(date(2026, 10, 6, 0, 0, zone: "UTC")))
        XCTAssertEqual(noon.first?.reset, .at(date(2026, 10, 6, 12, 30, zone: "UTC")))
    }

    func testKeepsUnrecognizedResetTextVerbatim() {
        let meters = UsageParser.parse("Current session: 40% used · resets tomorrow morning", now: now)

        XCTAssertEqual(meters, [UsageMeter(label: "SESSION", percentUsed: 40, reset: .unparsed("tomorrow morning"))])
    }

    func testUnknownLimitNameBecomesItsOwnLabel() {
        let meters = UsageParser.parse("Current month: 12% used · resets Nov 1 at 9am (UTC)", now: now)

        XCTAssertEqual(meters.first?.label, "MONTH")
    }

    func testReportWithoutUsageLinesYieldsNoMeters() {
        XCTAssertEqual(UsageParser.parse("Please run /login to sign in.", now: now), [])
        XCTAssertEqual(UsageParser.parse("", now: now), [])
    }

    func testPercentAboveOneHundredIsCapped() {
        let meters = UsageParser.parse("Current session: 104% used · resets Oct 5 at 3pm (UTC)", now: now)

        XCTAssertEqual(meters.first?.percentUsed, 100)
    }

    func testJanuaryResetReadInDecemberFallsInTheNextYear() {
        let lateDecember = date(2026, 12, 30, 10, 0, zone: "UTC")

        let meters = UsageParser.parse("Current week (all models): 9% used · resets Jan 2 at 9am (UTC)", now: lateDecember)

        XCTAssertEqual(meters.first?.reset, .at(date(2027, 1, 2, 9, 0, zone: "UTC")))
    }

    func testDecemberResetReadJustAfterNewYearFallsInThePreviousYear() {
        let newYear = date(2027, 1, 1, 0, 30, zone: "UTC")

        let meters = UsageParser.parse("Current session: 9% used · resets Dec 31 at 11pm (UTC)", now: newYear)

        XCTAssertEqual(meters.first?.reset, .at(date(2026, 12, 31, 23, 0, zone: "UTC")))
    }
}

final class UsageMeterTests: XCTestCase {
    func testSeverityThresholds() {
        func severity(_ percent: Int) -> UsageMeter.Severity {
            UsageMeter(label: "SESSION", percentUsed: percent, reset: .unparsed("")).severity
        }

        XCTAssertEqual(severity(0), .normal)
        XCTAssertEqual(severity(69), .normal)
        XCTAssertEqual(severity(70), .elevated)
        XCTAssertEqual(severity(89), .elevated)
        XCTAssertEqual(severity(90), .critical)
        XCTAssertEqual(severity(100), .critical)
    }
}
