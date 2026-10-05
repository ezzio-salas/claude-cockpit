import Foundation
import SQLite3

/// How much the Cursor agent has been used on this machine, counted from Cursor's own code-tracking database.
public struct CursorActivity: Equatable, Sendable {
    /// Agent requests since local midnight that produced code.
    public let requestsToday: Int
    public let requestsLast7Days: Int
    /// The model behind the most requests in the last 7 days; nil when there were none.
    public let topModel: String?

    public init(requestsToday: Int, requestsLast7Days: Int, topModel: String?) {
        self.requestsToday = requestsToday
        self.requestsLast7Days = requestsLast7Days
        self.topModel = topModel
    }
}

/// Reads `CursorActivity` from the SQLite database Cursor keeps for attributing code to AI.
/// The database is opened read-only; nothing is sent anywhere.
public struct CursorActivityReader: Sendable {
    public struct ReadError: Error, Equatable {
        public let message: String
    }

    public static let defaultDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/ai-tracking/ai-code-tracking.db")

    /// Rows with source `human` are code the user typed, tracked for comparison.
    private static let requestCount = """
    SELECT count(DISTINCT requestId) FROM ai_code_hashes WHERE source != 'human' AND createdAt >= ?
    """
    private static let topModel = """
    SELECT model FROM ai_code_hashes
    WHERE source != 'human' AND model IS NOT NULL AND createdAt >= ?
    GROUP BY model ORDER BY count(DISTINCT requestId) DESC, model LIMIT 1
    """

    private let database: URL

    public init(database: URL = CursorActivityReader.defaultDatabase) {
        self.database = database
    }

    /// Returns nil when the database does not exist, which means Cursor is not in use on this machine.
    public func read(now: Date, calendar: Calendar = .current) throws -> CursorActivity? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }

        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw Self.error(from: connection)
        }
        // Cursor writes to this database while it runs; wait briefly rather than fail on a momentary lock.
        sqlite3_busy_timeout(connection, 1_000)

        let startOfToday = calendar.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        return CursorActivity(
            requestsToday: try Self.firstValue(of: Self.requestCount, since: startOfToday, in: connection) {
                Int(sqlite3_column_int64($0, 0))
            } ?? 0,
            requestsLast7Days: try Self.firstValue(of: Self.requestCount, since: weekAgo, in: connection) {
                Int(sqlite3_column_int64($0, 0))
            } ?? 0,
            topModel: try Self.firstValue(of: Self.topModel, since: weekAgo, in: connection) {
                sqlite3_column_text($0, 0).map { String(cString: $0) }
            } ?? nil
        )
    }

    /// Runs `sql` with `since` bound as its one parameter (in the database's milliseconds) and reads the first row.
    private static func firstValue<Value>(
        of sql: String,
        since: Date,
        in connection: OpaquePointer?,
        read: (OpaquePointer?) -> Value
    ) throws -> Value? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(from: connection)
        }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1_000))

        switch sqlite3_step(statement) {
        case SQLITE_ROW: return read(statement)
        case SQLITE_DONE: return nil
        default: throw error(from: connection)
        }
    }

    private static func error(from connection: OpaquePointer?) -> ReadError {
        ReadError(message: String(cString: sqlite3_errmsg(connection)))
    }
}
