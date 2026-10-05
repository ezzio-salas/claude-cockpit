import Foundation

/// A program running on a pseudo-terminal, and everything it has drawn so far.
///
/// For a CLI that shows something only on its interactive screen: keys are typed to it and its
/// drawing is read back, as a terminal emulator would.
final class TerminalSession {
    /// The program closed its terminal.
    struct Ended: Error {}

    private let terminal: Int32
    private let process: pid_t
    private var drawn = Data()

    /// - Parameters:
    ///   - columns: Wide enough that the program draws each row of a table on one line.
    init(executable: URL, arguments: [String], directory: URL, columns: UInt16, rows: UInt16) throws {
        var terminal: Int32 = -1
        var programEnd: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&terminal, &programEnd, nil, nil, &size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(programEnd) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_adddup2(&actions, programEnd, descriptor)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A session of its own, so the program and whatever it starts can be killed as one group;
        // and no descriptor of this app's but the terminal.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let argumentPointers = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argumentPointers + environmentPointers).forEach { free($0) } }

        var process: pid_t = 0
        let status = posix_spawn(
            &process, executable.path, &actions, &attributes, argumentPointers, environmentPointers
        )
        guard status == 0 else {
            close(terminal)
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        self.terminal = terminal
        self.process = process
    }

    func type(_ keys: String) throws {
        let bytes = Array(keys.utf8)
        guard write(terminal, bytes, bytes.count) == bytes.count else { throw Ended() }
    }

    /// Waits up to `seconds` for output. Returns whether any arrived.
    func read(for seconds: TimeInterval) throws -> Bool {
        var descriptor = pollfd(fd: terminal, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(seconds * 1000)) > 0 else { return false }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(terminal, &buffer, buffer.count)
        guard count > 0 else { throw Ended() }
        drawn.append(contentsOf: buffer[..<count])
        return true
    }

    /// A position `text(since:)` can later start from.
    var mark: Int { drawn.count }

    func text(since mark: Int = 0) -> String {
        String(decoding: drawn[mark...], as: UTF8.self)
    }

    /// Kills the program and gives up the terminal.
    func end() {
        // The process leads its own group, so this takes a wrapper script and its runtime together.
        kill(-process, SIGKILL)
        var status: Int32 = 0
        waitpid(process, &status, 0)
        close(terminal)
    }
}
