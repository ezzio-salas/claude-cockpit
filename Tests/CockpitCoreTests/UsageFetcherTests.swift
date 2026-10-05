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
    private func fakeCLI(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("claude")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testReturnsWhatTheCLIPrints() async throws {
        let cli = try fakeCLI(#"echo "Current session: 5% used""#)

        let result = await UsageFetcher(executable: cli).fetch()

        XCTAssertEqual(result, .success("Current session: 5% used\n"))
    }

    func testAsksTheCLIForUsageWithoutLoadingUserConfiguration() async throws {
        let cli = try fakeCLI(#"printf '[%s]' "$@""#)

        let result = await UsageFetcher(executable: cli).fetch()

        XCTAssertEqual(result, .success("[-p][/usage][--no-session-persistence][--setting-sources][][--strict-mcp-config]"))
    }

    func testNonZeroExitIsAFailureCarryingTheOutput() async throws {
        let cli = try fakeCLI("echo 'not logged in' >&2\nexit 3")

        let result = await UsageFetcher(executable: cli).fetch()

        XCTAssertEqual(result, .failure(.failed(exitCode: 3, output: "not logged in\n")))
    }

    func testCLIThatOutlivesTheTimeoutIsStopped() async throws {
        let cli = try fakeCLI("exec sleep 30")

        let result = await UsageFetcher(executable: cli, timeout: 0.3).fetch()

        XCTAssertEqual(result, .failure(.timedOut))
    }

    func testCLIThatIgnoresPoliteTerminationIsStillStoppedOnTime() async throws {
        let cli = try fakeCLI("trap '' TERM\nsleep 5")
        let started = Date()

        let result = await UsageFetcher(executable: cli, timeout: 0.3).fetch()

        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testMissingExecutableIsReportedAsNotFound() async {
        let missing = directory.appendingPathComponent("no-such-claude")

        let result = await UsageFetcher(executable: missing).fetch()

        XCTAssertEqual(result, .failure(.cliNotFound))
    }
}
