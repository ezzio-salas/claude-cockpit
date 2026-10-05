import CryptoKit
import Foundation

/// Reads `CursorUsage` from the Cursor CLI.
///
/// The CLI prints plan usage nowhere but on the `/usage` screen of its interactive mode, so the
/// fetcher runs it on a pseudo-terminal, types `/usage` as a person would, and reads what is drawn.
public struct CursorUsageFetcher: Sendable {
    public enum FetchError: Error, Equatable {
        case cliNotFound
        case timedOut
        case launchFailed(String)
        /// The CLI ran but never showed the usage table; the text is what it drew instead.
        case unrecognized(String)
    }

    public static let defaultChats = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/chats")
    public static let defaultWorkspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.claude-cockpit/cursor-workspace")

    private enum Timing {
        /// How long the screen has to stay still to count as fully drawn.
        static let settle: TimeInterval = 0.5
        /// The CLI is given this long to start before `/usage` is typed anyway.
        static let startupLimit: TimeInterval = 8
        static let echoLimit: TimeInterval = 3
    }

    private let command: String
    private let timeout: TimeInterval
    private let chats: URL
    private let workspace: URL

    /// - Parameters:
    ///   - command: The CLI to run: a command name such as `cursor-agent`, or a path to an executable.
    ///     It is resolved on each fetch, so a CLI installed while the app runs is picked up.
    ///   - chats: Where the CLI files its session records, which `fetch` tidies after itself.
    ///   - workspace: The directory the CLI is started in. See `prepareWorkspace`.
    public init(
        command: String = "cursor-agent",
        timeout: TimeInterval = 20,
        chats: URL = defaultChats,
        workspace: URL = defaultWorkspace
    ) {
        self.command = command
        self.timeout = timeout
        self.chats = chats
        self.workspace = workspace
    }

    public func fetch() async -> Result<CursorUsage, FetchError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: fetchBlocking())
            }
        }
    }

    private func fetchBlocking() -> Result<CursorUsage, FetchError> {
        guard let cli = UsageFetcher.resolve(command, searchDirectories: UsageFetcher.installDirectories) else {
            return .failure(.cliNotFound)
        }
        let deadline = Self.now + timeout

        let workspace: URL
        let session: TerminalSession
        do {
            workspace = try Self.prepareWorkspace(self.workspace)
            // `--trust` answers the question the CLI asks about a directory it has not seen.
            session = try TerminalSession(
                executable: cli, arguments: ["--trust"], directory: workspace, columns: 120, rows: 40
            )
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        defer {
            session.end()
            Self.discardEmptySessions(of: workspace, in: chats)
        }

        do {
            return try Self.readUsage(from: session, deadline: deadline)
        } catch {
            return .failure(.unrecognized(CursorUsageParser.plainText(session.text())))
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func readUsage(
        from session: TerminalSession, deadline: TimeInterval
    ) throws -> Result<CursorUsage, FetchError> {
        try waitUntilDrawn(session, deadline: min(deadline, now + Timing.startupLimit))

        // Enter is pressed only once the CLI shows it took the command, so a screen that is asking
        // something else -- to sign in, say -- is never answered blind.
        let typed = session.mark
        try session.type("/usage")
        let echoDeadline = min(deadline, now + Timing.echoLimit)
        while !CursorUsageParser.plainText(session.text(since: typed)).contains("/usage") {
            guard now < echoDeadline else {
                return .failure(.unrecognized(CursorUsageParser.plainText(session.text())))
            }
            _ = try session.read(for: Timing.settle)
        }

        let entered = session.mark
        try session.type("\r")
        var usage: CursorUsage?
        while now < deadline {
            if try session.read(for: Timing.settle) {
                usage = CursorUsageParser.parse(session.text(since: entered))
            } else if let usage {
                return .success(usage)
            }
        }
        return usage.map { .success($0) } ?? .failure(.timedOut)
    }

    /// Returns once the CLI has drawn something and then gone still.
    private static func waitUntilDrawn(_ session: TerminalSession, deadline: TimeInterval) throws {
        var hasDrawn = false
        while now < deadline {
            if try session.read(for: Timing.settle) {
                hasDrawn = true
            } else if hasDrawn {
                return
            }
        }
    }

    /// Makes sure `directory` is an empty directory of this user's own, and returns the path the
    /// CLI itself will see, with every symlink resolved.
    ///
    /// Empty, so the CLI has no project to index; private, because the CLI is told to trust it, and
    /// a workspace can carry hooks and rules the CLI would act on. A shared location would let
    /// another account put those there first.
    private static func prepareWorkspace(_ directory: URL) throws -> URL {
        struct Unsafe: LocalizedError {
            let errorDescription: String?
        }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var status = stat()
        guard lstat(directory.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid() else {
            throw Unsafe(errorDescription: "\(directory.path) is not a directory of this user's own")
        }
        if status.st_mode & 0o077 != 0 {
            chmod(directory.path, 0o700)
        }
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw Unsafe(errorDescription: "\(directory.path) is not empty")
        }

        guard let resolved = realpath(directory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Removes the session records the CLI filed under `chats` for starting in `workspace`.
    ///
    /// Every start leaves one, and a widget that polls would leave hundreds a day. A record is removed
    /// only if it names this workspace and holds no conversation, and only the two files such a record
    /// has are deleted, so anything unexpected is left alone.
    static func discardEmptySessions(of workspace: URL, in chats: URL) {
        let digest = Insecure.MD5.hash(data: Data(workspace.path.utf8))
        let sessions = chats.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
        let records = (try? FileManager.default.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: nil
        )) ?? []

        for record in records {
            let meta = record.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  fields["cwd"] as? String == workspace.path,
                  fields["hasConversation"] as? Bool == false
            else { continue }

            try? FileManager.default.removeItem(at: meta)
            try? FileManager.default.removeItem(at: record.appendingPathComponent("prompt_history.json"))
            // Fails, as intended, on a record that holds anything else.
            rmdir(record.path)
        }
    }
}
