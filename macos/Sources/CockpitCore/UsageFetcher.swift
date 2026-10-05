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

    static let installDirectories = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"),
        URL(fileURLWithPath: "/opt/homebrew/bin"),
        URL(fileURLWithPath: "/usr/local/bin"),
    ]

    private let command: String
    private let timeout: TimeInterval

    /// - Parameter command: The CLI to run: a command name such as `claude`, or a path to an executable.
    ///   It is resolved on each fetch, so a CLI installed while the app runs is picked up.
    public init(command: String = "claude", timeout: TimeInterval = 20) {
        self.command = command
        self.timeout = timeout
    }

    public func fetch() async -> Result<String, FetchError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let cli = Self.resolve(command, searchDirectories: Self.installDirectories) else {
                    continuation.resume(returning: .failure(.cliNotFound))
                    return
                }
                continuation.resume(returning: Self.run(cli, arguments: Self.usageArguments, timeout: timeout))
            }
        }
    }

    /// Finds the executable for `command`. A command containing `/` is taken as a path. A bare name is looked up
    /// in `searchDirectories` and then by a login shell, because apps launched from Finder do not inherit the
    /// shell `PATH`.
    static func resolve(_ command: String, searchDirectories: [URL]) -> URL? {
        func executable(at path: String) -> URL? {
            FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }

        if command.contains("/") {
            return executable(at: (command as NSString).expandingTildeInPath)
        }
        for directory in searchDirectories {
            if let installed = executable(at: directory.appendingPathComponent(command).path) {
                return installed
            }
        }

        let shell = URL(fileURLWithPath: "/bin/zsh")
        // The name travels as an argument, never as shell source.
        let lookup = run(shell, arguments: ["-lc", #"command -v -- "$1""#, "zsh", command], timeout: 5)
        guard case .success(let output) = lookup else { return nil }
        return executable(at: output.trimmingCharacters(in: .whitespacesAndNewlines))
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
