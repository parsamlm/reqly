import CLinux
import Foundation
import Synchronization

/// Lets whoever started something long, such as waiting for an administrator's password, stop it.
public final class Cancellation: Sendable {
    private let cancelled = Mutex(false)

    public init() {}

    public func cancel() {
        cancelled.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        cancelled.withLock { $0 }
    }
}

/// Runs a tool, such as certutil or pkexec, and waits for it. The tool inherits none of Reqly's
/// descriptors, so it never holds Reqly's sockets open, and none of its ignored signals.
struct ToolRun: Sendable {
    /// How the tool ended.
    struct Ended: Sendable {
        /// Its exit status, or 128 and the signal's number when a signal ended it.
        var status: Int32
        var output: Data
        var errors: Data

        var errorText: String {
            String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum Failure: Error, Equatable {
        /// There's no such program.
        case notFound
        /// It ran past its time limit, so it was stopped.
        case timedOut
        case cancelled
        /// Linux couldn't start it, with this errno.
        case failed(Int32)
    }

    /// The program's absolute path.
    var path: String
    var arguments: [String]
    var environment: [String: String]
    /// What the tool reads on standard input: a few kilobytes at most, such as a certificate.
    var input = Data()
    /// How long it may run, in seconds, or `nil` for as long as it takes.
    var timeLimit: TimeInterval?
    var cancellation: Cancellation?
    /// Whether it starts a session of its own, without Reqly's terminal, if Reqly has one.
    var newSession = false

    /// Starts the tool and waits for it to end. Call it off the main thread.
    func run() throws(Failure) -> Ended {
        // The input goes in before the tool starts, so it never meets a closed pipe. A pipe holds
        // 64 KB.
        guard input.count <= 60_000 else { throw .failed(EFBIG) }
        let inputPipe = try Self.pipe()
        let written = input.withUnsafeBytes { write(inputPipe.write, $0.baseAddress, $0.count) }
        close(inputPipe.write)
        guard written == input.count else {
            close(inputPipe.read)
            throw .failed(errno)
        }
        let outputPipe: (read: Int32, write: Int32)
        let errorPipe: (read: Int32, write: Int32)
        do {
            outputPipe = try Self.pipe()
            errorPipe = try Self.pipe()
        } catch {
            close(inputPipe.read)
            throw error
        }
        let pid = Self.spawn(
            path, [path] + arguments, environment, (inputPipe.read, outputPipe.write, errorPipe.write), newSession)
        close(inputPipe.read)
        close(outputPipe.write)
        close(errorPipe.write)
        guard pid > 0 else {
            close(outputPipe.read)
            close(errorPipe.read)
            throw pid == -ENOENT ? .notFound : .failed(-pid)
        }
        var deadline = timeLimit.map { Date(timeIntervalSinceNow: $0) }
        var cancellation = cancellation
        var reading = [outputPipe.read, errorPipe.read]
        var collected = [Data(), Data()]
        var stop: Failure?
        // Read both until the tool closes them, a tenth of a second at a time, so a time limit or
        // a cancellation is noticed.
        while reading.contains(where: { $0 >= 0 }) && stop == nil {
            var polled = reading.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&polled, nfds_t(polled.count), 100)
            if ready < 0 && errno != EINTR { break }
            for index in polled.indices where polled[index].fd >= 0 && polled[index].revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                let count = read(polled[index].fd, &buffer, buffer.count)
                if count > 0 {
                    collected[index].append(contentsOf: buffer[..<count])
                } else if count == 0 || errno != EINTR {
                    close(polled[index].fd)
                    reading[index] = -1
                }
            }
            stop = Self.reasonToStop(deadline, cancellation)
            // Once pkexec has your password, it runs the helper as root, which Reqly can't stop,
            // so it waits for the helper and says how it went.
            if stop != nil, kill(pid, 0) != 0, errno == EPERM {
                stop = nil
                deadline = nil
                cancellation = nil
            }
        }
        for fd in reading where fd >= 0 {
            close(fd)
        }
        let status = Self.wait(for: pid, deadline: deadline, cancellation: cancellation, stopping: stop != nil)
        guard let status else { throw stop ?? Self.reasonToStop(deadline, cancellation) ?? .timedOut }
        return Ended(status: status, output: collected[0], errors: collected[1])
    }

    /// The first `name` in the `PATH` of `environment`, or `nil` when there's none.
    static func find(_ name: String, in environment: [String: String]) -> String? {
        let folders = (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":")
        for folder in folders where folder.hasPrefix("/") {
            let path = "\(folder)/\(name)"
            if access(path, X_OK) == 0 {
                return path
            }
        }
        return nil
    }

    /// `environment` without the proxy variables, so a tool Reqly starts never reaches out
    /// through Reqly itself.
    static func withoutProxy(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            let lower = name.lowercased()
            return !(lower.hasSuffix("_proxy") || lower == "node_use_env_proxy")
        }
    }

    // MARK: -

    private static func pipe() throws(Failure) -> (read: Int32, write: Int32) {
        var ends: [Int32] = [-1, -1]
        let result = reqly_trust_pipe(&ends)
        guard result == 0 else { throw .failed(-result) }
        return (ends[0], ends[1])
    }

    private static func spawn(
        _ path: String, _ arguments: [String], _ environment: [String: String],
        _ descriptors: (input: Int32, output: Int32, errors: Int32), _ newSession: Bool
    ) -> pid_t {
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        return reqly_trust_spawn(
            path, argv, envp, descriptors.input, descriptors.output, descriptors.errors, newSession ? 1 : 0)
    }

    private static func reasonToStop(_ deadline: Date?, _ cancellation: Cancellation?) -> Failure? {
        if cancellation?.isCancelled == true { return .cancelled }
        if let deadline, deadline.timeIntervalSinceNow <= 0 { return .timedOut }
        return nil
    }

    /// Waits for the tool to end and reaps it, and returns its status. When it has to stop, or
    /// runs past the time limit, it's asked to end, then made to, and the status is `nil`; unless
    /// it can't be stopped, since it runs as root, and then it waits for its status.
    private static func wait(for pid: pid_t, deadline: Date?, cancellation: Cancellation?, stopping: Bool) -> Int32? {
        let pidfd = reqly_pidfd_open(pid)
        defer { if pidfd >= 0 { close(pidfd) } }
        // Without a pidfd, which only a kernel before 5.3 lacks, waitpid waits.
        var ended = !stopping && pidfd < 0
        while !stopping && !ended && pidfd >= 0 {
            if reqly_pidfd_wait(pidfd, 100) != 0 {
                ended = true
            } else if reasonToStop(deadline, cancellation) != nil {
                break
            }
        }
        if !ended {
            if kill(pid, SIGTERM) != 0 && errno == EPERM {
                // It runs as root now, as pkexec's helper does, so waitpid waits for it to end.
                ended = true
            } else if pidfd < 0 || reqly_pidfd_wait(pidfd, 2000) == 0 {
                kill(pid, SIGKILL)
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        guard ended else { return nil }
        // The bits WIFEXITED, WEXITSTATUS and WTERMSIG read, which Swift can't call as macros.
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
