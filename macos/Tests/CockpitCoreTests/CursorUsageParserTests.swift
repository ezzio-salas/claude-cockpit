import XCTest
@testable import CockpitCore

final class CursorUsageParserTests: XCTestCase {
    private static let bar = String(repeating: "█", count: 40)

    /// What the CLI draws for `/usage`, escape sequences included, with the bars shortened.
    private static let screen = [
        "Loading usage data...\u{1B}[39m\r\n\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[G",
        "\u{1B}[38;2;244;231;161m────────\u{1B}[39m\r\n",
        " \u{1B}[1m\u{1B}[38;2;244;231;161mUsage\u{1B}[39m\u{1B}[22m\u{1B}[2m • \u{1B}[22mTeam",
        "          \u{1B}[2mResets Oct 17\u{1B}[22m\r\n",
        " \u{1B}[2mMonthly plan and on-demand usage\u{1B}[22m\r\n\r\n",
        " \u{1B}[2mCategory\u{1B}[22m        \u{1B}[2mCurrent\u{1B}[22m             \u{1B}[2mUsage\u{1B}[22m\r\n",
        " Included        100% used           \u{1B}[36m\(bar)\u{1B}[39m\r\n",
        " \u{1B}[2m  Auto\u{1B}[22m          \u{1B}[2m0% used\u{1B}[22m             \u{1B}[2m░░░░\u{1B}[22m\r\n",
        " \u{1B}[2m  API\u{1B}[22m           \u{1B}[2m100% used\u{1B}[22m           \u{1B}[35m\(bar)\u{1B}[39m\r\n",
        " On-Demand       $482.19             \u{1B}[2m————\u{1B}[22m\r\n\r\n",
        " \u{1B}[2mNo personal limit\u{1B}[22m\r\n\r\n",
        " \u{1B}[2mView in dashboard: \u{1B}[22m\u{1B}]8;;https://cursor.com/dashboard?tab=usage\u{07}",
        "\u{1B}[4m\u{1B}[34mcursor.com/dashboard?tab=usage\u{1B}[39m\u{1B}[24m\u{1B}]8;;\u{07}\r\n\r\n",
        " \u{1B}[2mEsc to close\u{1B}[22m\r\n\u{1B}[?2004l",
    ].joined()

    private func allowance(_ label: String, _ percentUsed: Int) -> CursorUsage.Allowance {
        CursorUsage.Allowance(label: label, percentUsed: percentUsed)
    }

    func testParsesTheRealScreen() {
        XCTAssertEqual(CursorUsageParser.parse(Self.screen), CursorUsage(
            allowances: [allowance("INCLUDED", 100), allowance("AUTO", 0), allowance("API", 100)],
            resets: "Oct 17",
            onDemand: "$482.19"
        ))
    }

    func testARedrawnRowKeepsItsPlaceAndItsLatestFigure() {
        let screen = " Included 10% used\r\n Auto 5% used\r\n\u{1B}[2A Included 12% used\r\n"

        XCTAssertEqual(
            CursorUsageParser.parse(screen)?.allowances, [allowance("INCLUDED", 12), allowance("AUTO", 5)]
        )
    }

    func testAPlanWithoutOnDemandSpendOrAResetDate() {
        XCTAssertEqual(
            CursorUsageParser.parse(" Included        42% used\r\n"),
            CursorUsage(allowances: [allowance("INCLUDED", 42)], resets: nil, onDemand: nil)
        )
    }

    func testAPercentageAboveOneHundredIsCapped() {
        XCTAssertEqual(CursorUsageParser.parse("Included 250% used")?.allowances, [allowance("INCLUDED", 100)])
    }

    func testOnDemandSpendWithAThousandsSeparator() {
        XCTAssertEqual(CursorUsageParser.parse("On-Demand       $1,482.19")?.onDemand, "$1,482.19")
    }

    func testAScreenWithoutTheTableIsNotUsage() {
        for screen in ["", "Loading usage data...", "\u{1B}[2K\u{1B}[1A Plan, search, build"] {
            XCTAssertNil(CursorUsageParser.parse(screen))
        }
    }
}
