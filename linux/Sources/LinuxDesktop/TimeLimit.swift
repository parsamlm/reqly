import Foundation
import Synchronization

/// Runs work that can hang, such as a call over D-Bus to a service that stopped answering, on a
/// thread of its own, and gives up waiting for it after a time limit. Work that has run out of
/// time is left to finish, or not, on its own thread, and its result is dropped.
enum TimeLimit {
    /// The work ran out of time.
    struct Exceeded: LocalizedError {
        var what: String
        var seconds: Double

        var errorDescription: String? {
            "\(what.prefix(1).uppercased())\(what.dropFirst()) took longer than \(Int(seconds)) seconds, so Reqly "
                + "stopped waiting."
        }
    }

    /// `work`'s result, or ``Exceeded`` once `seconds` have passed. `what` names the work for
    /// the error.
    static func run<Result: Sendable>(
        _ what: String, seconds: Double, _ work: @escaping @Sendable () throws -> Result
    ) throws -> Result {
        let outcome = Mutex<Swift.Result<Result, any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let result = Swift.Result { try work() }
            outcome.withLock { $0 = result }
            done.signal()
        }
        thread.name = "Reqly: \(what)"
        thread.start()
        guard done.wait(timeout: .now() + seconds) == .success, let result = outcome.withLock({ $0 }) else {
            throw Exceeded(what: what, seconds: seconds)
        }
        return try result.get()
    }
}
