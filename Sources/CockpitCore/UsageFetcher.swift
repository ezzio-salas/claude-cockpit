import Foundation

/// Reads the raw `/usage` report from the Claude Code CLI.
public struct UsageFetcher: Sendable {
    public enum FetchError: Error, Equatable {
        case cliNotFound
        case timedOut
        case launchFailed(String)
        case failed(exitCode: Int32, output: String)
    }

    /// Skips user hooks, plugins and MCP servers and saves no session, so a poll is quick and leaves nothing behind.
    private static let usageArguments = [
        "-p", "/usage", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config",
    ]

    private let executable: URL?
    private let timeout: TimeInterval

    /// - Parameter executable: The CLI to run. When nil, it is located on each fetch.
    public init(executable: URL? = nil, timeout: TimeInterval = 20) {
        self.executable = executable
        self.timeout = timeout
    }

    public func fetch() async -> Result<String, FetchError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let cli = executable ?? Self.locateCLI(),
                      FileManager.default.isExecutableFile(atPath: cli.path)
                else {
                    continuation.resume(returning: .failure(.cliNotFound))
                    return
                }
                continuation.resume(returning: Self.run(cli, arguments: Self.usageArguments, timeout: timeout))
            }
        }
    }

    /// Apps launched from Finder do not inherit the shell `PATH`, so the usual install locations are checked first.
    static func locateCLI() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        if let installed = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return installed
        }

        let shell = URL(fileURLWithPath: "/bin/zsh")
        guard case .success(let output) = run(shell, arguments: ["-lc", "command -v claude"], timeout: 5) else {
            return nil
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> Result<String, FetchError> {
        // Output goes to a file rather than a pipe, so waiting depends only on the process itself and
        // never on a descendant that still holds a pipe open.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cockpit-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        do {
            try Data().write(to: outputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }

            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            // SIGKILL rather than SIGTERM: a CLI stuck in a system call never gets to act on a polite request.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return .failure(.timedOut)
        }

        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            return .failure(.failed(exitCode: process.terminationStatus, output: output))
        }
        return .success(output)
    }
}
