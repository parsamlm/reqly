import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
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
    private let descriptor: Int32

    init(folder: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
            let path = folder.appending(path: Self.fileName).path(percentEncoded: false)
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
        #if canImport(Darwin) || canImport(Glibc)
            close(descriptor)
        #endif
    }

    /// Whether `folder` is a session that no running Reqly holds. A folder without a lock may be
    /// one that another Reqly is still setting up, so it counts as abandoned only after a minute.
    static func isAbandoned(_ folder: URL) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
            let path = folder.appending(path: fileName).path(percentEncoded: false)
            let descriptor = open(path, O_RDWR)
            guard descriptor >= 0 else {
                let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return Date().timeIntervalSince(created) > 60
            }
            defer { close(descriptor) }
            return flock(descriptor, LOCK_EX | LOCK_NB) == 0
        #else
            // Without a way to tell, keep every session.
            return false
        #endif
    }
}
