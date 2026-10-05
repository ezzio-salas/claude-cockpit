import XCTest
@testable import CockpitCore

final class UsageFetcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Writes an executable shell script standing in for the `claude` CLI.
    private func fakeCLI(_ body: String, named name: String = "claude") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testReturnsWhatTheCLIPrints() async throws {
        let cli = try fakeCLI(#"echo "Current session: 5% used""#)

        let result = await UsageFetcher(command: cli.path).fetch()

        XCTAssertEqual(result, .success("Current session: 5% used\n"))
    }

    func testAsksTheCLIForUsageWithoutLoadingUserConfiguration() async throws {
        let cli = try fakeCLI(#"printf '[%s]' "$@""#)

        let result = await UsageFetcher(command: cli.path).fetch()

        XCTAssertEqual(result, .success("[-p][/usage][--no-session-persistence][--setting-sources][][--strict-mcp-config]"))
    }

    func testNonZeroExitIsAFailureCarryingTheOutput() async throws {
        let cli = try fakeCLI("echo 'not logged in' >&2\nexit 3")

        let result = await UsageFetcher(command: cli.path).fetch()

        XCTAssertEqual(result, .failure(.failed(exitCode: 3, output: "not logged in\n")))
    }

    func testCLIThatOutlivesTheTimeoutIsStopped() async throws {
        let cli = try fakeCLI("exec sleep 30")

        let result = await UsageFetcher(command: cli.path, timeout: 0.3).fetch()

        XCTAssertEqual(result, .failure(.timedOut))
    }

    func testCLIThatIgnoresPoliteTerminationIsStillStoppedOnTime() async throws {
        let cli = try fakeCLI("trap '' TERM\nsleep 5")
        let started = Date()

        let result = await UsageFetcher(command: cli.path, timeout: 0.3).fetch()

        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testMissingExecutableIsReportedAsNotFound() async {
        let missing = directory.appendingPathComponent("no-such-claude")

        let result = await UsageFetcher(command: missing.path).fetch()

        XCTAssertEqual(result, .failure(.cliNotFound))
    }

    func testCommandNameIsFoundInTheSearchDirectories() throws {
        let cli = try fakeCLI("true", named: "claude-work")
        let elsewhere = directory.appendingPathComponent("empty")

        let resolved = UsageFetcher.resolve("claude-work", searchDirectories: [elsewhere, directory])

        XCTAssertEqual(resolved?.path, cli.path)
    }

    func testCommandNameThatExistsNowhereIsNotResolved() {
        XCTAssertNil(UsageFetcher.resolve("no-such-claude-\(UUID().uuidString)", searchDirectories: [directory]))
    }

    func testCommandGivenAsAPathIsUsedAsIsAndNeverSearchedFor() throws {
        let cli = try fakeCLI("true", named: "claude-work")

        XCTAssertEqual(UsageFetcher.resolve(cli.path, searchDirectories: [])?.path, cli.path)
        XCTAssertNil(UsageFetcher.resolve("./claude-work", searchDirectories: [directory]))
    }

    func testFileThatIsNotExecutableIsNotResolved() throws {
        let file = directory.appendingPathComponent("claude-work")
        try "not a program".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertNil(UsageFetcher.resolve(file.path, searchDirectories: []))
    }
}
