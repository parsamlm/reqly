import CLinux
import Foundation

/// Starting other programs, such as `systemd-run`, the watcher and terminals: detached, in a
/// session of their own, with none of Reqly's descriptors, so none keeps Reqly's port open.
public enum Programs {
    /// Couldn't start a program.
    public struct Failure: Error, Hashable, CustomStringConvertible {
        public var program: String
        public var code: Int32

        public var description: String {
            "Reqly couldn't start \(program): \(String(cString: strerror(code)))."
        }
    }

    /// The program called `name` in `path`'s folders, such as the `PATH` variable's, or `nil`
    /// when none of them has one you can run.
    public static func find(_ name: String, in path: String?) -> String? {
        for folder in (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") where folder.hasPrefix("/") {
            let candidate = "\(folder)/\(name)"
            var status = stat()
            if stat(candidate, &status) == 0, status.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    /// Starts the program at `path` with `arguments` after its name and `environment`, and
    /// returns its process ID. It doesn't wait: the program is still Reqly's child, so call
    /// ``wait(for:seconds:)`` or ``reapWhenDone(_:)``.
    public static func start(_ path: String, _ arguments: [String], environment: [String: String]) throws -> pid_t {
        let pid = withCStrings([path] + arguments) { argv in
            withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                reqly_spawn_detached(path, argv, envp, -1)
            }
        }
        guard pid > 0 else { throw Failure(program: path, code: -pid) }
        return pid
    }

    /// Waits up to `seconds` for child `pid` to end and returns its exit status, or `nil` if it
    /// was stopped by a signal or ran out of time, in which case it's stopped.
    public static func wait(for pid: pid_t, seconds: Double) -> Int32? {
        let pidfd = reqly_pidfd_open(pid)
        if pidfd >= 0 {
            let ended = reqly_pidfd_wait(pidfd, Int32(seconds * 1000))
            close(pidfd)
            if ended != 1 {
                kill(pid, SIGKILL)
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        // WIFEXITED and WEXITSTATUS, which Swift can't import as macros.
        return status & 0x7F == 0 ? (status >> 8) & 0xFF : nil
    }

    /// Reaps child `pid` once it ends, on a thread of its own, so it doesn't linger as a zombie.
    public static func reapWhenDone(_ pid: pid_t) {
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        thread.name = "Reqly: waiting for process \(pid)"
        thread.start()
    }

    /// `strings` as a NULL-ended array of C strings, for `body`.
    private static func withCStrings<Result>(
        _ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) throws -> Result
    ) rethrows -> Result {
        let copies = strings.map { strdup($0) } + [nil]
        defer { copies.forEach { free($0) } }
        return try body(copies)
    }
}
