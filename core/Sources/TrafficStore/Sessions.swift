import Foundation
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(WinSDK)
    import WinSDK
#endif

extension TrafficStore {
    /// Starts a new session in a folder of its own inside `root`.
    ///
    /// It first deletes the sessions no running copy of Reqly holds anymore, such as one left
    /// behind by a crash. Captured traffic shouldn't outlive the Reqly that captured it.
    public static func newSession(in root: URL, limits: Limits = Limits()) throws -> TrafficStore {
        let fileManager = FileManager.default
        // Only you can read your traffic.
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        removeAbandonedSessions(in: root)
        let (folder, lock) = try makeSessionFolder(in: root)
        return try TrafficStore(directory: folder, limits: limits, lock: lock)
    }

    /// A new, empty session folder in `root`, already locked.
    static func makeSessionFolder(in root: URL) throws -> (URL, SessionLock) {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        return (folder, try SessionLock(folder: folder))
    }

    /// Deletes the sessions in `root` that no running copy of Reqly holds.
    static func removeAbandonedSessions(in root: URL) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where SessionLock.isAbandoned(folder) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// Marks a session folder as in use for as long as the store lives. The system lets go of the
/// lock when the process ends, even in a crash, so a session nobody holds was left behind.
final class SessionLock: Sendable {
    private static let fileName = ".lock"
    #if os(Windows)
        // A HANDLE is a pointer, which Swift doesn't count as Sendable. The lock only closes it.
        nonisolated(unsafe) private let handle: HANDLE
    #else
        private let descriptor: Int32
    #endif
    private let isReleased = Mutex(false)

    init(folder: URL) throws {
        let url = folder.appending(path: Self.fileName)
        #if os(Windows)
            guard let handle = Self.lockFile(url, creating: true) else { throw CocoaError(.fileLocking) }
            self.handle = handle
        #elseif canImport(Darwin) || canImport(Glibc)
            let path = url.path(percentEncoded: false)
            let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw POSIXError(.EWOULDBLOCK)
            }
            self.descriptor = descriptor
        #else
            descriptor = -1
        #endif
    }

    deinit {
        release()
    }

    /// Lets go of the lock, before the session's folder is deleted.
    func release() {
        let wasReleased = isReleased.withLock { isReleased in
            defer { isReleased = true }
            return isReleased
        }
        guard !wasReleased else { return }
        #if os(Windows)
            CloseHandle(handle)
        #elseif canImport(Darwin) || canImport(Glibc)
            close(descriptor)
        #endif
    }

    /// Whether `folder` is a session that no running Reqly holds. A folder without a lock may be
    /// one that another Reqly is still setting up, so it counts as abandoned only after a minute.
    static func isAbandoned(_ folder: URL) -> Bool {
        let url = folder.appending(path: fileName)
        #if os(Windows)
            guard FileManager.default.fileExists(atPath: url.path) else { return isOld(folder) }
            guard let handle = lockFile(url, creating: false) else { return false }
            CloseHandle(handle)
            return true
        #elseif canImport(Darwin) || canImport(Glibc)
            let descriptor = open(url.path(percentEncoded: false), O_RDWR)
            guard descriptor >= 0 else { return isOld(folder) }
            defer { close(descriptor) }
            return flock(descriptor, LOCK_EX | LOCK_NB) == 0
        #else
            // Without a way to tell, keep every session.
            return false
        #endif
    }

    /// Whether a folder without a lock is old enough that no Reqly is still setting it up.
    private static func isOld(_ folder: URL) -> Bool {
        let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        return Date().timeIntervalSince(created) > 60
    }

    #if os(Windows)
        /// Opens the lock file at `url` and locks it for this process alone. `nil` when another
        /// process holds it, or it can't be opened. Windows lets go of the lock when the handle
        /// closes, or the process ends.
        private static func lockFile(_ url: URL, creating: Bool) -> HANDLE? {
            let handle = url.nativePath.withCString(encodedAs: UTF16.self) { name in
                CreateFileW(
                    name, DWORD(truncatingIfNeeded: GENERIC_READ) | DWORD(truncatingIfNeeded: GENERIC_WRITE),
                    DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                    DWORD(creating ? OPEN_ALWAYS : OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
            var overlapped = OVERLAPPED()
            let flags = DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY)
            guard LockFileEx(handle, flags, 0, 1, 0, &overlapped) else {
                CloseHandle(handle)
                return nil
            }
            return handle
        }
    #endif
}

extension URL {
    /// The path the way the system's own file functions take it. On Windows, that's `C:\Users\…`,
    /// where `path(percentEncoded:)` gives `/C:/Users/…`.
    var nativePath: String {
        withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }
}
