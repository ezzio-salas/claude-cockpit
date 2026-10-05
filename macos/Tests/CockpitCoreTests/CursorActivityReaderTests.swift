import SQLite3
import XCTest
@testable import CockpitCore

final class CursorActivityReaderTests: XCTestCase {
    private var directory: URL!
    private var database: URL!
    private var calendar: Calendar!
    /// Monday 5 October 2026, 15:00 UTC.
    private var now: Date!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("ai-code-tracking.db")

        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 15))!
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func execute(_ sql: String) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(database.path, &handle) == SQLITE_OK,
              sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
        else { throw XCTSkip("could not prepare the test database: \(String(cString: sqlite3_errmsg(handle)))") }
    }

    private func createTrackingTable() throws {
        try execute("""
        CREATE TABLE ai_code_hashes (
            hash TEXT PRIMARY KEY, source TEXT NOT NULL, fileExtension TEXT, fileName TEXT,
            requestId TEXT, conversationId TEXT, timestamp INTEGER, model TEXT, createdAt INTEGER NOT NULL
        );
        """)
    }

    /// Records one tracked chunk of code, `hoursAgo` before `now`.
    private func track(request: String?, model: String?, hoursAgo: Double, source: String = "composer") throws {
        let createdAt = Int64((now.timeIntervalSince1970 - hoursAgo * 3_600) * 1_000)
        let quoted: (String?) -> String = { $0.map { "'\($0)'" } ?? "NULL" }
        try execute("""
        INSERT INTO ai_code_hashes (hash, source, requestId, model, createdAt)
        VALUES ('\(UUID().uuidString)', '\(source)', \(quoted(request)), \(quoted(model)), \(createdAt));
        """)
    }

    private func read() throws -> CursorActivity? {
        try CursorActivityReader(database: database).read(now: now, calendar: calendar)
    }

    func testCountsEachRequestOnceHoweverManyChunksItProduced() throws {
        try createTrackingTable()
        try track(request: "a", model: "grok", hoursAgo: 1)
        try track(request: "a", model: "grok", hoursAgo: 1)
        try track(request: "a", model: "grok", hoursAgo: 1)
        try track(request: "b", model: "grok", hoursAgo: 2)

        XCTAssertEqual(try read(), CursorActivity(requestsToday: 2, requestsLast7Days: 2, topModel: "grok"))
    }

    func testTodayStartsAtMidnightAndTheWeekReachesBackSevenDays() throws {
        try createTrackingTable()
        try track(request: "at-midnight", model: "grok", hoursAgo: 15)
        try track(request: "late-yesterday", model: "grok", hoursAgo: 15.01)
        try track(request: "six-days-ago", model: "grok", hoursAgo: 6 * 24)
        try track(request: "eight-days-ago", model: "grok", hoursAgo: 8 * 24)

        let activity = try read()

        XCTAssertEqual(activity?.requestsToday, 1)
        XCTAssertEqual(activity?.requestsLast7Days, 3)
    }

    func testTopModelIsTheOneWithTheMostRequestsThisWeek() throws {
        try createTrackingTable()
        try track(request: "a", model: "composer", hoursAgo: 1)
        try track(request: "a", model: "composer", hoursAgo: 1)
        try track(request: "a", model: "composer", hoursAgo: 1)
        try track(request: "b", model: "grok", hoursAgo: 30)
        try track(request: "c", model: "grok", hoursAgo: 40)
        try track(request: "old-1", model: "opus", hoursAgo: 9 * 24)
        try track(request: "old-2", model: "opus", hoursAgo: 9 * 24)
        try track(request: "old-3", model: "opus", hoursAgo: 9 * 24)

        XCTAssertEqual(try read()?.topModel, "grok")
    }

    func testCodeTheUserTypedIsNotCountedAsARequest() throws {
        try createTrackingTable()
        try track(request: nil, model: nil, hoursAgo: 1, source: "human")
        try track(request: "typed", model: "grok", hoursAgo: 1, source: "human")

        XCTAssertEqual(try read(), CursorActivity(requestsToday: 0, requestsLast7Days: 0, topModel: nil))
    }

    func testNoTrackedCodeIsZeroActivityWithNoTopModel() throws {
        try createTrackingTable()

        XCTAssertEqual(try read(), CursorActivity(requestsToday: 0, requestsLast7Days: 0, topModel: nil))
    }

    func testMissingDatabaseMeansCursorIsNotInUse() throws {
        XCTAssertNil(try read())
    }

    func testDatabaseWithoutTheTrackingTableIsAnError() throws {
        try execute("CREATE TABLE something_else (id INTEGER);")

        XCTAssertThrowsError(try read())
    }

    func testFileThatIsNotADatabaseIsAnError() throws {
        try "not a database, just some text that is long enough to fill a header".write(
            to: database, atomically: true, encoding: .utf8
        )

        XCTAssertThrowsError(try read())
    }
}
