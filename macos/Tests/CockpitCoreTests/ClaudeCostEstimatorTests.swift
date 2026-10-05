import XCTest
@testable import CockpitCore

final class ModelPricingTests: XCTestCase {
    func testKnownModelHasItsPublishedRates() {
        XCTAssertEqual(
            ModelPricing.rates(for: "claude-opus-5-5"),
            TokenRates(input: 4, output: 20, cacheWrite5Minutes: 5, cacheWrite1Hour: 8, cacheRead: 0.20)
        )
    }

    func testDatedSnapshotIsPricedAsItsBaseModel() {
        XCTAssertEqual(
            ModelPricing.rates(for: "claude-haiku-4-5-20251001"),
            TokenRates(input: 1, output: 5, cacheWrite5Minutes: 1.25, cacheWrite1Hour: 2, cacheRead: 0.1)
        )
    }

    func testUnknownModelHasNoRates() {
        XCTAssertNil(ModelPricing.rates(for: "some-other-model"))
    }

    func testNewerVersionIsNotMistakenForTheModelItsNameStartsWith() {
        XCTAssertNil(ModelPricing.rates(for: "claude-opus-5-9"))
    }
}

final class CostTextTests: XCTestCase {
    func testSmallAmountsShowCents() {
        XCTAssertEqual(CostText.text(3.4, isPartial: false), "~$3.40")
        XCTAssertEqual(CostText.text(0, isPartial: false), "~$0.00")
    }

    func testAmountsFromTenDollarsAreRoundedToWholeDollars() {
        XCTAssertEqual(CostText.text(10, isPartial: false), "~$10")
        XCTAssertEqual(CostText.text(139.6, isPartial: false), "~$140")
    }

    func testPartialTotalIsMarked() {
        XCTAssertEqual(CostText.text(12, isPartial: true), "~$12+")
    }
}

final class ClaudeCostEstimatorTests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar!
    /// Monday 5 October 2026, 15:00 UTC.
    private var now: Date!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 15))!
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// One transcript line for an assistant reply, `hoursAgo` before `now`.
    private func reply(
        _ id: String,
        model: String = "claude-opus-5-5",
        hoursAgo: Double = 1,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite5Minutes: Int = 0,
        cacheWrite1Hour: Int = 0
    ) throws -> String {
        let timestamps = ISO8601DateFormatter()
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "requestId": "request-\(id)",
            "timestamp": timestamps.string(from: now.addingTimeInterval(-hoursAgo * 3_600)),
            "message": [
                "id": id,
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation_input_tokens": cacheWrite5Minutes + cacheWrite1Hour,
                    "cache_creation": [
                        "ephemeral_5m_input_tokens": cacheWrite5Minutes,
                        "ephemeral_1h_input_tokens": cacheWrite1Hour,
                    ],
                ],
            ] as [String: Any],
        ] as [String: Any])
        return String(decoding: line, as: UTF8.self)
    }

    private func write(_ lines: [String], to path: String) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func estimate(with estimator: ClaudeCostEstimator? = nil) async -> ClaudeCost? {
        await (estimator ?? ClaudeCostEstimator(transcripts: directory)).estimate(now: now, calendar: calendar)
    }

    func testPricesEveryKindOfTokenAtItsOwnRate() async throws {
        try write([
            try reply(
                "a", input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                cacheWrite5Minutes: 1_000_000, cacheWrite1Hour: 1_000_000
            ),
        ], to: "project/session.jsonl")

        let cost = await estimate()

        // Opus 5.5: $4 input + $20 output + $0.20 cache read + $5 and $8 cache writes.
        XCTAssertEqual(try XCTUnwrap(cost).last7Days.dollars, 37.20, accuracy: 0.0001)
    }

    func testEachModelIsPricedAtItsOwnRates() async throws {
        try write([
            try reply("opus", model: "claude-opus-5-5", output: 1_000_000),
            try reply("fable", model: "claude-fable-5-1", output: 1_000_000),
        ], to: "project/session.jsonl")

        let cost = await estimate()

        XCTAssertEqual(try XCTUnwrap(cost).last7Days.dollars, 20 + 50, accuracy: 0.0001)
    }

    func testReplyWrittenAsSeveralLinesIsCountedOnceAtItsFinalSize() async throws {
        try write([
            try reply("a", input: 1_000_000, output: 100_000),
            try reply("a", input: 1_000_000, output: 500_000),
            try reply("a", input: 1_000_000, output: 500_000),
        ], to: "project/session.jsonl")

        let cost = await estimate()

        XCTAssertEqual(try XCTUnwrap(cost).last7Days.dollars, 4 + 10, accuracy: 0.0001)
    }

    func testReplyCopiedIntoAResumedSessionIsCountedOnce() async throws {
        try write([try reply("a", output: 1_000_000)], to: "project/first.jsonl")
        try write([try reply("a", output: 1_000_000), try reply("b", output: 1_000_000)], to: "project/resumed.jsonl")

        let cost = await estimate()

        XCTAssertEqual(try XCTUnwrap(cost).last7Days.dollars, 40, accuracy: 0.0001)
    }

    func testTodayStartsAtMidnightAndTheWeekReachesBackSevenDays() async throws {
        try write([
            try reply("at-midnight", hoursAgo: 15, output: 1_000_000),
            try reply("late-yesterday", hoursAgo: 15.01, output: 1_000_000),
            try reply("six-days-ago", hoursAgo: 6 * 24, output: 1_000_000),
            try reply("eight-days-ago", hoursAgo: 8 * 24, output: 1_000_000),
        ], to: "project/session.jsonl")

        let estimated = await estimate()
        let cost = try XCTUnwrap(estimated)

        XCTAssertEqual(cost.today.dollars, 20, accuracy: 0.0001)
        XCTAssertEqual(cost.last7Days.dollars, 60, accuracy: 0.0001)
    }

    func testSubagentTranscriptsInNestedFoldersAreIncluded() async throws {
        try write([try reply("main", output: 1_000_000)], to: "project/session.jsonl")
        try write([try reply("sub", output: 1_000_000)], to: "project/session/subagents/agent.jsonl")

        let cost = await estimate()

        XCTAssertEqual(try XCTUnwrap(cost).last7Days.dollars, 40, accuracy: 0.0001)
    }

    func testModelWithoutAPriceIsReportedAndLeftOutOfTheTotals() async throws {
        try write([
            try reply("known", output: 1_000_000),
            try reply("unknown", model: "claude-future-9", output: 1_000_000),
        ], to: "project/session.jsonl")

        let cost = await estimate()

        XCTAssertEqual(cost, ClaudeCost(
            today: CostWindow(dollars: 20, unpricedModels: ["claude-future-9"]),
            last7Days: CostWindow(dollars: 20, unpricedModels: ["claude-future-9"])
        ))
    }

    /// An unpriced model used earlier in the week must not mark today's figure incomplete.
    func testAnUnpricedModelMarksOnlyThePeriodItWasUsedIn() async throws {
        try write([
            try reply("today", output: 1_000_000),
            try reply("days-ago", model: "claude-future-9", hoursAgo: 4 * 24, output: 1_000_000),
        ], to: "project/session.jsonl")

        let cost = try XCTUnwrap(await estimate())

        XCTAssertEqual(cost.last7Days.unpricedModels, ["claude-future-9"])
        XCTAssertTrue(cost.last7Days.isPartial)
        XCTAssertEqual(cost.today.unpricedModels, [])
        XCTAssertFalse(cost.today.isPartial)
    }

    func testLinesThatAreNotFinishedRepliesAreIgnored() async throws {
        try write([
            #"{"type":"user","message":{"role":"user","content":"what is my \"usage\"?"}}"#,
            #"{"type":"assistant","message":{"id":"x","model":"<synthetic>","usage":{"output_tokens":1000000}},"timestamp":"2026-10-05T14:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"usage":"#,
            try reply("real", output: 1_000_000),
        ], to: "project/session.jsonl")

        let cost = await estimate()

        XCTAssertEqual(cost, ClaudeCost(today: CostWindow(dollars: 20), last7Days: CostWindow(dollars: 20)))
    }

    func testRepliesAddedSinceTheLastEstimateAreCounted() async throws {
        let estimator = ClaudeCostEstimator(transcripts: directory)
        try write([try reply("a", output: 1_000_000)], to: "project/session.jsonl")
        let before = await estimate(with: estimator)

        try write([try reply("a", output: 1_000_000), try reply("b", output: 1_000_000)], to: "project/session.jsonl")
        let after = await estimate(with: estimator)

        XCTAssertEqual(try XCTUnwrap(before).last7Days.dollars, 20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(after).last7Days.dollars, 40, accuracy: 0.0001)
    }

    func testNoTranscriptsIsZeroCost() async {
        let cost = await estimate()

        XCTAssertEqual(cost, ClaudeCost(today: CostWindow(dollars: 0), last7Days: CostWindow(dollars: 0)))
    }

    func testMissingDirectoryMeansThereIsNothingToEstimate() async {
        let missing = ClaudeCostEstimator(transcripts: directory.appendingPathComponent("nowhere"))

        let cost = await estimate(with: missing)

        XCTAssertNil(cost)
    }
}
