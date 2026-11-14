import Foundation
import GRDB
import ReqlyModel

#if canImport(WinSDK)
    import WinSDK
#elseif canImport(Glibc)
    import Glibc
#endif

public enum SessionFileError: Error, Equatable {
    /// The file isn't a session Reqly saved.
    case notASession
    /// A newer Reqly saved the file, in a way this one doesn't know yet.
    case savedByNewerReqly
}

/// A saved session is the session's database with every body inside it, so it's one file that
/// Reqly opens on the Mac and on Windows alike. It keeps no search index: opening it builds one.
extension TrafficStore {
    /// Marks a database as a saved Reqly session, in SQLite's application ID: "RQLY".
    static let sessionFileID: Int32 = 0x5251_4C59

    /// Saves the session to `url`, replacing any file there. Traffic can keep arriving meanwhile;
    /// the file holds the session as it was when saving began.
    ///
    /// - Parameter hidingSecrets: Hides the values of authorization headers and cookies.
    public func saveSession(to url: URL, hidingSecrets: Bool) async throws {
        #if os(Linux)
            // A hidden copy beside the file, which takes the file's place with one rename, on the
            // same file system whatever TMPDIR names. Foundation's item replacement folder would
            // be in TMPDIR, or for a file on another file system, a folder it makes beside it.
            let copyURL = try Self.hiddenCopy(of: url)
            defer { Self.removeCopy(copyURL) }
        #else
            let fileManager = FileManager.default
            let scratch = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? fileManager.removeItem(at: scratch) }
            let copyURL = scratch.appending(path: url.lastPathComponent)
        #endif
        // A snapshot of the database, while capturing goes on.
        try await database.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [copyURL.path(percentEncoded: false)])
        }
        let copy = try DatabaseQueue(path: copyURL.path(percentEncoded: false))
        try await copy.write { db in
            try self.moveBodiesIn(db)
            if hidingSecrets {
                try Self.hideSecrets(in: db)
            }
            try db.execute(sql: "INSERT INTO search(search) VALUES('delete-all')")
            try db.execute(sql: "PRAGMA application_id = \(Self.sessionFileID)")
        }
        try await copy.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        try copy.close()
        #if os(Linux)
            try Self.putInPlace(copyURL, at: url)
        #else
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                try Self.replace(url, with: copyURL)
            } else {
                try fileManager.moveItem(at: copyURL, to: url)
            }
        #endif
    }

    /// Opens a saved session as a session of its own in `root`, which can be browsed, searched,
    /// annotated and saved again. The file itself stays as it is.
    public static func openSession(_ file: URL, in root: URL, limits: Limits = Limits()) async throws -> TrafficStore {
        let (folder, lock) = try makeSessionFolder(in: root)
        do {
            let databaseURL = folder.appending(path: "traffic.sqlite")
            try FileManager.default.copyItem(at: file, to: databaseURL)
            try await checkSessionFile(at: databaseURL)
            let store = try TrafficStore(directory: folder, limits: limits, lock: lock)
            try await store.rebuildSearchIndex()
            return store
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Starts a new session in `root` with `exchanges`, bodies and all, such as the ones in a
    /// HAR file, and the WebSocket messages of the ones that switched to WebSocket.
    public static func newSession(
        in root: URL, with exchanges: [Exchange], messages: [ExchangeID: [WebSocketMessage]] = [:],
        limits: Limits = Limits()
    ) async throws -> TrafficStore {
        let store = try newSession(in: root, limits: limits)
        for batch in stride(from: 0, to: exchanges.count, by: 500) {
            let exchanges = Array(exchanges[batch..<min(batch + 500, exchanges.count)])
            let chunks = exchanges.flatMap { exchange in
                [
                    BodyChunk(exchange: exchange.id, part: .request, data: exchange.requestBody),
                    BodyChunk(exchange: exchange.id, part: .response, data: exchange.responseBody),
                ].filter { !$0.data.isEmpty }
            }
            let stored = exchanges.flatMap { exchange in
                (messages[exchange.id] ?? []).enumerated().map {
                    StoredMessage(exchange: exchange.id, number: $0.offset, message: $0.element)
                }
            }
            try await store.write(exchanges, chunks: chunks, messages: stored)
        }
        // Saving leaves annotations alone, so a comment from the file goes in by itself.
        for exchange in exchanges where exchange.annotation != Annotation() {
            try await store.annotate(exchange.id, with: exchange.annotation)
        }
        return store
    }

    /// Checks that the file is a session this Reqly can open, before anything changes it.
    private static func checkSessionFile(at url: URL) async throws {
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path(percentEncoded: false))
        } catch {
            throw SessionFileError.notASession
        }
        defer { try? queue.close() }
        try await queue.read { db in
            guard (try? Int32.fetchOne(db, sql: "PRAGMA application_id")) == sessionFileID else {
                throw SessionFileError.notASession
            }
            if try Schema.migrator.hasBeenSuperseded(db) {
                throw SessionFileError.savedByNewerReqly
            }
        }
    }

    /// Puts the bodies kept in files into the database, as much of each as the snapshot counted.
    private func moveBodiesIn(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT exchangeID, part, size, file FROM body WHERE file IS NOT NULL")
        for row in rows {
            let file: String = row["file"]
            let size: Int = row["size"]
            let data = (try? Data(contentsOf: bodyURL(file)))?.prefix(size) ?? Data()
            try db.execute(
                sql: "UPDATE body SET data = ?, size = ?, file = NULL WHERE exchangeID = ? AND part = ?",
                arguments: [data, data.count, row["exchangeID"], row["part"]]
            )
        }
    }

    private static func hideSecrets(in db: Database) throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let rows = try Row.fetchAll(db, sql: "SELECT id, requestHeaders, responseHeaders FROM exchange")
        for row in rows {
            func hidden(_ column: String) throws -> String? {
                guard let json: String = row[column] else { return nil }
                let headers = try decoder.decode(Headers.self, from: Data(json.utf8))
                return String(decoding: try encoder.encode(headers.hidingSecrets()), as: UTF8.self)
            }
            try db.execute(
                sql: "UPDATE exchange SET requestHeaders = ?, responseHeaders = ? WHERE id = ?",
                arguments: [try hidden("requestHeaders"), try hidden("responseHeaders"), row["id"]]
            )
        }
    }

    /// Puts `replacement` in `url`'s place in one step, so the old file stays until the new one
    /// is complete.
    private static func replace(_ url: URL, with replacement: URL) throws {
        #if os(Windows)
            // Foundation doesn't implement replaceItemAt on Windows yet.
            try FileReplacement.retrying {
                let replaced = replacement.nativePath.withCString(encodedAs: UTF16.self) { from in
                    url.nativePath.withCString(encodedAs: UTF16.self) { to in
                        MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                    }
                }
                guard replaced else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
            }
        #else
            _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        #endif
    }

    #if os(Linux)
        /// Where to make the copy of the session that's saved as `url`: a hidden file beside it.
        /// A folder Reqly can't write to is refused first, with Foundation's words for it.
        private static func hiddenCopy(of url: URL) throws -> URL {
            let folder = url.deletingLastPathComponent()
            guard access(folder.path(percentEncoded: false), W_OK) == 0 else {
                throw fileError(errno, url)
            }
            return folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        }

        /// Removes the copy, and its journal, if saving stopped before it took the file's place.
        private static func removeCopy(_ copy: URL) {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                unlink(copy.path(percentEncoded: false) + suffix)
            }
        }

        /// Renames the copy over `url`, so the old file stays until the new one is complete. The
        /// copy takes the old file's permissions first, so a session saved over a private file
        /// stays private.
        private static func putInPlace(_ copy: URL, at url: URL) throws {
            let path = url.path(percentEncoded: false)
            let copyPath = copy.path(percentEncoded: false)
            var old = stat()
            if stat(path, &old) == 0, chmod(copyPath, old.st_mode & 0o7777) != 0 {
                throw fileError(errno, url)
            }
            guard rename(copyPath, path) == 0 else {
                throw fileError(errno, url)
            }
        }

        /// Foundation's error for saving `url`, which says what went wrong in words.
        private static func fileError(_ number: Int32, _ url: URL) -> CocoaError {
            let code: CocoaError.Code =
                switch number {
                case EACCES, EPERM: .fileWriteNoPermission
                case ENOENT: .fileNoSuchFile
                case ENOSPC, EDQUOT: .fileWriteOutOfSpace
                case EROFS: .fileWriteVolumeReadOnly
                default: .fileWriteUnknown
                }
            return CocoaError(
                code,
                userInfo: [
                    NSFilePathErrorKey: url.path(percentEncoded: false),
                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO),
                ])
        }
    #endif

    /// Indexes every exchange again, for a session that came without its index.
    func rebuildSearchIndex() async throws {
        try await database.write { db in
            try db.execute(sql: "INSERT INTO search(search) VALUES('delete-all')")
            // The new index can always take it, though a damaged one couldn't as the session opened.
            try Self.setSearchMerging(in: db)
            let records = try ExchangeRecord.fetchAll(db, sql: ExchangeRecord.selectWithSource)
            for record in records {
                try self.index(record.exchange, isNew: false, arrived: [:], in: db)
            }
        }
    }
}
