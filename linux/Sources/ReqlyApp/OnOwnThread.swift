import Foundation

/// Runs `work`, which may block while it waits, such as for D-Bus, the disk, the keyring or a
/// password dialog, on a thread of its own, so it holds up neither the window nor the threads
/// Swift's tasks share.
func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { done in
        Thread.detachNewThread { done.resume(returning: work()) }
    }
}
