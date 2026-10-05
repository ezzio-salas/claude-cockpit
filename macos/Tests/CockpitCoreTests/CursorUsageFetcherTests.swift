import CryptoKit
import XCTest
@testable import CockpitCore

/// The Cursor CLI is stood in for by shell scripts on a real pseudo-terminal.
final class CursorUsageFetcherTests: XCTestCase {
    private var directory: URL!
    private var chats: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        chats = directory.appendingPathComponent("chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func fakeCLI(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("cursor-agent")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private var workspace: URL { directory.appendingPathComponent("workspace") }

    private func fetch(_ cli: URL, timeout: TimeInterval = 10) async -> Result<CursorUsage, CursorUsageFetcher.FetchError> {
        await CursorUsageFetcher(command: cli.path, timeout: timeout, chats: chats, workspace: workspace).fetch()
    }

    // MARK: - Fetching

    func testTypesTheCommandAndReadsTheTable() async throws {
        let recorded = directory.appendingPathComponent("invocation.txt")
        let cli = try fakeCLI("""
        printf '%s\\n' "$@" > \(recorded.path)
        echo "Cursor Agent"
        read command
        [ "$command" = "/usage" ] || exit 3
        echo ' Included        42% used'
        echo ' On-Demand       $1.50      Resets Oct 17'
        sleep 30
        """)
        let started = Date()

        let result = await fetch(cli)

        XCTAssertEqual(result, .success(CursorUsage(
            allowances: [CursorUsage.Allowance(label: "INCLUDED", percentUsed: 42)],
            resets: "Oct 17",
            onDemand: "$1.50"
        )))
        XCTAssertEqual(try String(contentsOf: recorded, encoding: .utf8), "--trust\n")
        // It does not wait for the CLI to exit, which an interactive one never does.
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testMissingCLI() async {
        let result = await fetch(directory.appendingPathComponent("nope"))

        XCTAssertEqual(result, .failure(.cliNotFound))
    }

    func testACLIThatExitsReportsWhatItPrinted() async throws {
        let cli = try fakeCLI("echo 'Not logged in'\nexit 1")

        let result = await fetch(cli)

        guard case .failure(.unrecognized(let drawn)) = result else {
            return XCTFail("Expected an unrecognized screen, got \(result)")
        }
        XCTAssertTrue(drawn.contains("Not logged in"))
    }

    func testACLIThatNeverShowsUsageTimesOutAndIsKilled() async throws {
        let cli = try fakeCLI("echo 'Cursor Agent'\nsleep 30")
        let started = Date()

        let result = await fetch(cli, timeout: 2)

        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A CLI asking something else -- here with echo off -- must not be answered blind.
    func testEnterIsNotPressedOnAScreenThatDidNotTakeTheCommand() async throws {
        let answered = directory.appendingPathComponent("answered.txt")
        let cli = try fakeCLI("""
        stty -echo
        echo "Sign in to continue? [Y/n]"
        read answer
        echo "$answer" > \(answered.path)
        sleep 30
        """)

        let result = await fetch(cli)

        guard case .failure(.unrecognized) = result else {
            return XCTFail("Expected an unrecognized screen, got \(result)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: answered.path))
    }

    // MARK: - Workspace

    /// Whatever is in the workspace would run with the CLI's trust, so it is not started.
    func testAWorkspaceThatIsNotEmptyIsNotTrusted() async throws {
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".cursor"), withIntermediateDirectories: true
        )
        let cli = try fakeCLI("echo 'Cursor Agent'\nsleep 30")

        let result = await fetch(cli, timeout: 5)

        guard case .failure(.launchFailed(let reason)) = result else {
            return XCTFail("Expected a refused launch, got \(result)")
        }
        XCTAssertTrue(reason.contains("not empty"), reason)
    }

    func testTheWorkspaceIsPrivateToTheUser() async throws {
        let cli = try fakeCLI("echo 'Cursor Agent'\nexit 0")

        _ = await fetch(cli, timeout: 5)

        let permissions = try FileManager.default.attributesOfItem(atPath: workspace.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
    }

    // MARK: - Session records

    @discardableResult
    private func session(
        _ name: String, of owner: URL? = nil, cwd: URL? = nil, hasConversation: Bool = false, extra: String? = nil
    ) throws -> URL {
        let digest = Insecure.MD5.hash(data: Data((owner ?? workspace).path.utf8))
        let record = chats
            .appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        let meta: [String: Any] = ["cwd": (cwd ?? workspace).path, "hasConversation": hasConversation]
        try JSONSerialization.data(withJSONObject: meta).write(to: record.appendingPathComponent("meta.json"))
        try Data(#"["/usage"]"#.utf8).write(to: record.appendingPathComponent("prompt_history.json"))
        if let extra {
            try Data("kept".utf8).write(to: record.appendingPathComponent(extra))
        }
        return record
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testEmptySessionsOfTheWorkspaceAreRemoved() throws {
        let empty = try session("empty")

        CursorUsageFetcher.discardEmptySessions(of: workspace, in: chats)

        XCTAssertFalse(exists(empty))
    }

    func testSessionsThatAreNotPlainlyOursAreKept() throws {
        let elsewhere = directory.appendingPathComponent("another-project")
        let kept = [
            try session("conversation", hasConversation: true),
            try session("elsewhere", cwd: elsewhere),
            try session("other-workspace", of: elsewhere, cwd: elsewhere),
        ]
        let unexpected = try session("unexpected", extra: "store.db")
        let unreadable = try session("unreadable")
        try Data("not json".utf8).write(to: unreadable.appendingPathComponent("meta.json"))

        CursorUsageFetcher.discardEmptySessions(of: workspace, in: chats)

        for record in kept + [unreadable] {
            XCTAssertTrue(exists(record.appendingPathComponent("meta.json")), record.lastPathComponent)
        }
        XCTAssertTrue(exists(unexpected.appendingPathComponent("store.db")))
    }

    func testNoChatsDirectoryAtAll() {
        CursorUsageFetcher.discardEmptySessions(of: workspace, in: directory.appendingPathComponent("absent"))
    }
}
