import CGtk
import Foundation
import GtkBinding

/// A program a part runs to its end, such as ImageMagick's import or the accessibility reader,
/// through GIO, which closes the self-check's descriptors in it. The window goes on meanwhile, so
/// it can answer the program, as the accessibility reader asks it what it shows.
@MainActor
enum Program {
    /// How a program ended, and what it wrote.
    struct Ended {
        /// Its exit status, or `nil` when a signal ended it, as its time limit does.
        var status: Int32?
        var output: String
        var errors: String
        /// Whether it ran out of time, and was ended.
        var ranOut: Bool

        /// Why it didn't end well, in a few words, or `nil` when it ended with status 0.
        var problem: String? {
            if ranOut { return "it ran out of time" }
            guard status != 0 else { return nil }
            let ending = status.map { "status \($0)" } ?? "a signal"
            let said = errors.split(separator: "\n").last.map { ": \($0)" } ?? ""
            return "it ended with \(ending)\(said)"
        }
    }

    /// Runs `arguments`, the program first, found in PATH, with the self-check's environment and
    /// `environment`, and ends it after `seconds`. Its standard output and error are read whole.
    static func run(_ arguments: [String], environment: [String: String] = [:], seconds: Int) async throws -> Ended {
        let flags = G_SUBPROCESS_FLAGS_STDOUT_PIPE.rawValue | G_SUBPROCESS_FLAGS_STDERR_PIPE.rawValue
        let launcher = g_subprocess_launcher_new(GSubprocessFlags(rawValue: flags))!
        defer { g_object_unref(raw(launcher)) }
        for (name, value) in environment {
            g_subprocess_launcher_setenv(launcher, name, value, 1)
        }
        var error: UnsafeMutablePointer<GError>?
        guard let process = withCStrings(arguments, { g_subprocess_launcher_spawnv(launcher, $0, &error) }) else {
            throw SelfCheck.Failure("\(arguments.first ?? "the program") didn't start: \(message(error))")
        }
        defer { g_object_unref(raw(process)) }
        let limit = TimeLimit()
        let source = timeout(UInt32(seconds * 1000)) {
            limit.passed = true
            g_subprocess_force_exit(process)
            return false
        }
        // Once the program has ended and closed both pipes.
        let (output, errors) = await withCheckedContinuation { done in
            let (callback, context) = whenReady { _, result in
                var output: UnsafeMutablePointer<CChar>?
                var errors: UnsafeMutablePointer<CChar>?
                _ = g_subprocess_communicate_utf8_finish(process, result, &output, &errors, nil)
                done.resume(returning: (takeString(output) ?? "", takeString(errors) ?? ""))
            }
            g_subprocess_communicate_utf8_async(process, nil, nil, callback, context)
        }
        if !limit.passed {
            g_source_remove(source)
        }
        let status = g_subprocess_get_if_exited(process) != 0 ? g_subprocess_get_exit_status(process) : nil
        return Ended(status: status, output: output, errors: errors, ranOut: limit.passed)
    }
}

/// Whether a program's time limit has passed, and its source has gone.
@MainActor
final class TimeLimit {
    var passed = false
}
