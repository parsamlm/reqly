import Foundation
import GRDB
import ReqlyModel

/// Keeps one session's traffic on disk: a SQLite database, plus a folder for bodies too big to
/// keep in it. Bodies are kept exactly as they came over the wire.
///
/// One writer saves changes in order, and reads run alongside it, so the interface can read while
/// traffic is being saved.
public final class TrafficStore: Sendable {
    /// How much a session keeps.
    public struct Limits: Sendable, Hashable {
        /// The most exchanges a session keeps. Past it, the oldest finished ones go first.
        public var exchanges: Int
        /// The most bytes kept of one body. Bytes past it still count toward the exchange's size.
        public var bodySize: Int
        /// Bodies up to this size stay in the database. Bigger ones get a file of their own.
        public var inlineBodySize: Int
        /// How much of each body's text the search index takes in.
        public var searchableBodySize: Int
        /// The most bytes kept of one WebSocket message.
        public var messageSize: Int

        public init(
            exchanges: Int = 100_000,
            bodySize: Int = 64 << 20,
            inlineBodySize: Int = 256 << 10,
            searchableBodySize: Int = 1 << 20,
            messageSize: Int = 1 << 20
        ) {
            self.messageSize = messageSize
            self.exchanges = exchanges
            self.bodySize = bodySize
            self.inlineBodySize = inlineBodySize
            self.searchableBodySize = searchableBodySize
        }
    }

    /// Searching headers and bodies needs at least this many characters.
    public static let minimumSearchLength = 3

    /// A compressed body bigger than this isn't unpacked for the search index, since only all of
    /// it can be unpacked.
    static let searchableCompressedSize = 8 << 20

    /// The session's folder.
    public let directory: URL
    public let limits: Limits
    let database: DatabasePool
    /// Keeps other copies of Reqly from deleting the session while it's in use.
    private let lock: SessionLock?

    /// Opens the session in `directory`, creating it if needed.
    public convenience init(directory: URL, limits: Limits = Limits()) throws {
        try self.init(directory: directory, limits: limits, lock: nil)
    }

    init(directory: URL, limits: Limits, lock: SessionLock?) throws {
        try FileManager.default.createDirectory(
            at: directory.appending(path: "bodies", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        self.directory = directory
        self.limits = limits
        self.lock = lock
        database = try DatabasePool(path: directory.appending(path: "traffic.sqlite").path(percentEncoded: false))
        try Schema.migrator.migrate(database)
    }

    // MARK: - Writing

    /// Saves new and changed exchanges, and adds `chunks` to their bodies, in one transaction.
    /// The exchanges' own bodies are ignored: body bytes arrive only as chunks.
    ///
    /// - Returns: The exchanges removed to stay within ``limits``, oldest first.
    @discardableResult
    public func write(
        _ exchanges: [Exchange], chunks: [BodyChunk] = [], messages: [StoredMessage] = []
    ) async throws -> [ExchangeID] {
        let messageSize = limits.messageSize
        let (removed, files) = try await database.write { db in
            let encoder = JSONEncoder()
            let exists = try db.cachedStatement(sql: "SELECT 1 FROM exchange WHERE id = ?")
            let upsert = try db.cachedStatement(sql: ExchangeRecord.upsertSQL)
            let upsertDevice = try db.cachedStatement(sql: ExchangeRecord.upsertDeviceSQL)
            // Exchanges the store already had. The others are new, so they have no bodies or
            // search entries to look up yet.
            var stored: Set<ExchangeID> = []
            var sources: [Source: Int64] = [:]
            var devices: Set<Device> = []
            for exchange in exchanges {
                if try Row.fetchOne(exists, arguments: [exchange.id.storageID]) != nil {
                    stored.insert(exchange.id)
                }
                if let device = exchange.device, devices.insert(device).inserted {
                    try upsertDevice.execute(arguments: [device.id, device.kind.rawValue, device.name, device.address])
                }
                let sourceID = try exchange.source.map { try self.sourceID(for: $0, in: db, known: &sources) }
                try upsert.execute(arguments: ExchangeRecord(exchange, sourceID: sourceID).arguments(encoder))
            }
            let written = Set(exchanges.map(\.id))
            let merged = BodyChunk.merged(chunks)
            for (key, data) in merged {
                let isNew = written.contains(key.exchange) && !stored.contains(key.exchange)
                try self.append(data, to: key, isNew: isNew, in: db)
            }
            if !messages.isEmpty {
                let insert = try db.cachedStatement(
                    sql: """
                        INSERT OR REPLACE INTO message (exchangeID, number, direction, kind, time, size, closeCode, data)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """)
                // An exchange the size limit already took has no row for its messages to go with.
                let known = try db.cachedStatement(sql: "SELECT 1 FROM exchange WHERE id = ?")
                var present: [ExchangeID: Bool] = [:]
                for stored in messages {
                    if present[stored.exchange] == nil {
                        present[stored.exchange] =
                            try Row.fetchOne(known, arguments: [stored.exchange.storageID]) != nil
                    }
                    guard present[stored.exchange] == true else { continue }
                    let message = stored.message
                    try insert.execute(arguments: [
                        stored.exchange.storageID, stored.number, message.direction.rawValue, message.kind.rawValue,
                        message.time.timeIntervalSinceReferenceDate, message.size, message.closeCode,
                        message.data.prefix(messageSize),
                    ])
                }
            }
            let arrived = Dictionary(uniqueKeysWithValues: merged.map { ($0.key, $0.data) })
            for exchange in exchanges {
                try self.index(exchange, isNew: !stored.contains(exchange.id), arrived: arrived, in: db)
            }
            return try self.trim(in: db)
        }
        removeFiles(files)
        return removed
    }

    /// Clears the session, except the pinned exchanges.
    public func removeUnpinned() async throws {
        let files = try await database.write { db in
            let files = try String.fetchAll(
                db,
                sql: """
                    SELECT body.file FROM body JOIN exchange ON exchange.id = body.exchangeID
                    WHERE body.file IS NOT NULL AND NOT exchange.pinned
                    """
            )
            if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM exchange WHERE pinned)") == true {
                try db.execute(sql: "DELETE FROM search WHERE rowid IN (SELECT id FROM exchange WHERE NOT pinned)")
                try db.execute(sql: "DELETE FROM exchange WHERE NOT pinned")
            } else {
                try ExchangeRecord.deleteAll(db)
                try db.execute(sql: "INSERT INTO search(search) VALUES('delete-all')")
            }
            return files
        }
        removeFiles(files)
    }

    /// Pins, marks or comments on an exchange, or takes that off. An exchange the store doesn't
    /// have is left alone.
    public func annotate(_ id: ExchangeID, with annotation: Annotation) async throws {
        try await database.write { db in
            try db.cachedStatement(sql: "UPDATE exchange SET pinned = ?, color = ?, comment = ? WHERE id = ?")
                .execute(arguments: [
                    annotation.isPinned, annotation.color?.rawValue, annotation.comment, id.storageID,
                ])
        }
    }

    /// An exchange's WebSocket messages, in order, from `number` on.
    public func messages(of id: ExchangeID, from number: Int = 0, limit: Int = 10_000) async throws
        -> [WebSocketMessage]
    {
        try await database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT direction, kind, time, size, closeCode, data FROM message
                    WHERE exchangeID = ? AND number >= ? ORDER BY number LIMIT ?
                    """,
                arguments: [id.storageID, number, limit]
            ).compactMap { row in
                guard let direction = WebSocketMessage.Direction(rawValue: row["direction"]),
                    let kind = WebSocketMessage.Kind(rawValue: row["kind"])
                else { return nil }
                return WebSocketMessage(
                    direction: direction, kind: kind, time: Date(timeIntervalSinceReferenceDate: row["time"]),
                    data: row["data"], size: row["size"], closeCode: row["closeCode"])
            }
        }
    }

    /// Names a device, for every exchange it sent.
    public func renameDevice(_ id: String, to name: String) async throws {
        try await database.write { db in
            try db.cachedStatement(sql: "UPDATE device SET name = ? WHERE id = ?").execute(arguments: [name, id])
        }
    }

    /// Deletes the session's folder, for when the session ends without being saved.
    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The ID of `source`'s row, which is added if the store doesn't have it yet.
    private func sourceID(for source: Source, in db: Database, known: inout [Source: Int64]) throws -> Int64 {
        if let id = known[source] {
            return id
        }
        let arguments: StatementArguments = [source.name, source.bundleID, source.path]
        try db.cachedStatement(sql: "INSERT OR IGNORE INTO source (name, bundleID, path) VALUES (?, ?, ?)")
            .execute(arguments: arguments)
        let select = try db.cachedStatement(
            sql: """
                SELECT id FROM source
                WHERE name = ? AND IFNULL(bundleID, '') = IFNULL(?, '') AND IFNULL(path, '') = IFNULL(?, '')
                """
        )
        guard let id = try Int64.fetchOne(select, arguments: arguments) else {
            throw DatabaseError(resultCode: .SQLITE_NOTFOUND, message: "The source \(source.name) wasn't saved.")
        }
        known[source] = id
        return id
    }

    /// Adds `data` to a body. A body that's new in this write has nothing stored yet.
    private func append(_ data: Data, to key: BodyKey, isNew: Bool, in db: Database) throws {
        var body = StoredBody(size: 0, data: nil, file: nil)
        if !isNew {
            if let stored = try StoredBody.fetch(key, in: db) {
                body = stored
            } else {
                // Its exchange may be gone, for example after the session was cleared.
                let exists = try db.cachedStatement(sql: "SELECT 1 FROM exchange WHERE id = ?")
                guard try Row.fetchOne(exists, arguments: [key.exchange.storageID]) != nil else { return }
            }
        }
        let added = data.prefix(max(limits.bodySize - body.size, 0))
        guard !added.isEmpty else { return }
        if let file = body.file {
            try write(added, to: file, at: body.size)
        } else if body.size + added.count <= limits.inlineBodySize {
            body.data = (body.data ?? Data()) + added
        } else {
            // Too big for the database now: the whole body moves to a file.
            try write((body.data ?? Data()) + added, to: key.fileName, at: 0)
            body.data = nil
            body.file = key.fileName
        }
        body.size += added.count
        try body.save(key, in: db)
    }

    /// Writes `data` into a body file at `offset`, and cuts off anything after it. A write that
    /// was rolled back may have left bytes there.
    private func write(_ data: Data, to file: String, at offset: Int) throws {
        let url = bodyURL(file)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            FileManager.default.createFile(
                atPath: url.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(offset + data.count))
    }

    /// Puts the exchange in the search index, replacing what was there. Bodies go in once the
    /// exchange finishes, so each body is unpacked only once it's whole.
    ///
    /// - Parameter arrived: Body bytes that arrived in this write. A new exchange has no others.
    func index(_ exchange: Exchange, isNew: Bool, arrived: [BodyKey: Data], in db: Database) throws {
        var bodies: [String] = []
        if exchange.state.isFinished {
            for part in BodyPart.allCases {
                if let text = try searchableText(of: exchange, part: part, isNew: isNew, arrived: arrived, in: db) {
                    bodies.append(text)
                }
            }
        }
        let insert = isNew ? "INSERT" : "INSERT OR REPLACE"
        let statement = try db.cachedStatement(
            sql: "\(insert) INTO search(rowid, url, headers, body) VALUES (?, ?, ?, ?)")
        try statement.execute(arguments: [
            exchange.id.storageID, SearchText.url(of: exchange), SearchText.headers(of: exchange),
            bodies.joined(separator: "\n"),
        ])
    }

    private func searchableText(
        of exchange: Exchange, part: BodyPart, isNew: Bool, arrived: [BodyKey: Data], in db: Database
    ) throws -> String? {
        guard let headers = part == .request ? exchange.request.headers : exchange.response?.headers else {
            return nil
        }
        let key = BodyKey(exchange: exchange.id, part: part)
        let isPacked = headers["Content-Encoding"].map { $0.lowercased() != "identity" } ?? false
        // Plain text needs only its start, but a packed body can only be unpacked whole.
        let needed = isPacked ? Self.searchableCompressedSize + 1 : limits.searchableBodySize + 3
        let data: Data?
        if isNew {
            data = arrived[key].map { $0.prefix(limits.bodySize).prefix(needed) }
        } else {
            data = try StoredBody.fetch(key, in: db).map { load($0, upTo: needed) }
        }
        guard let data, !data.isEmpty, !isPacked || data.count <= Self.searchableCompressedSize else { return nil }
        return SearchText.body(data, headers: headers, limit: limits.searchableBodySize)
    }

    /// Drops the oldest finished exchanges past the limit, and returns them with their body files.
    private func trim(in db: Database) throws -> ([ExchangeID], [String]) {
        let excess = try ExchangeRecord.fetchCount(db) - limits.exchanges
        guard excess > 0 else { return ([], []) }
        // Pinned exchanges are kept, even past the limit.
        let ids = try Int64.fetchAll(
            db, sql: "SELECT id FROM exchange WHERE isFinished AND NOT pinned ORDER BY id LIMIT ?", arguments: [excess]
        )
        guard !ids.isEmpty else { return ([], []) }
        let files = try SQLRequest<String>(
            literal: "SELECT file FROM body WHERE file IS NOT NULL AND exchangeID IN \(ids)"
        ).fetchAll(db)
        try ExchangeRecord.deleteAll(db, keys: ids)
        try db.execute(literal: "DELETE FROM search WHERE rowid IN \(ids)")
        return (ids.map(ExchangeID.init(storageID:)), files)
    }

    /// Deletes body files once the transaction that dropped them has committed.
    private func removeFiles(_ files: [String]) {
        for file in files {
            try? FileManager.default.removeItem(at: bodyURL(file))
        }
    }

    // MARK: - Reading

    /// The exchange with its bodies, or `nil` when the session doesn't have it.
    public func exchange(_ id: ExchangeID) async throws -> Exchange? {
        try await database.read { db in
            let sql = ExchangeRecord.selectWithSource + " WHERE exchange.id = ?"
            guard let record = try ExchangeRecord.fetchOne(db, sql: sql, arguments: [id.storageID]) else {
                return nil
            }
            var exchange = record.exchange
            if let body = try StoredBody.fetch(BodyKey(exchange: id, part: .request), in: db) {
                exchange.requestBody = self.load(body)
            }
            if let body = try StoredBody.fetch(BodyKey(exchange: id, part: .response), in: db) {
                exchange.responseBody = self.load(body)
            }
            return exchange
        }
    }

    /// One exchange's summary, without reading its bodies.
    public func summary(_ id: ExchangeID) async throws -> ExchangeSummary? {
        try await database.read { db in
            try ExchangeRecord.fetchOne(
                db, sql: ExchangeRecord.selectWithSource + " WHERE exchange.id = ?", arguments: [id.storageID]
            )?.exchange.summary
        }
    }

    /// Every exchange's summary, oldest first.
    public func summaries() async throws -> [ExchangeSummary] {
        try await database.read { db in
            try ExchangeRecord.fetchAll(db, sql: ExchangeRecord.selectWithSource + " ORDER BY exchange.id")
                .map(\.exchange.summary)
        }
    }

    /// The exchanges whose URL, headers or body text contain `text`, ignoring case. Text shorter
    /// than ``minimumSearchLength`` finds nothing.
    public func search(_ text: String) async throws -> Set<ExchangeID> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.count >= Self.minimumSearchLength else { return [] }
        // A quoted phrase matches the text as it is. Quotes inside it are doubled.
        let phrase = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return try await database.read { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT rowid FROM search WHERE search MATCH ?", arguments: [phrase])
            return Set(ids.map(ExchangeID.init(storageID:)))
        }
    }

    /// A body's bytes, up to `limit` of them. A body file that has gone missing reads as empty.
    private func load(_ body: StoredBody, upTo limit: Int = .max) -> Data {
        if let data = body.data {
            return data.prefix(limit)
        }
        guard let file = body.file, let handle = try? FileHandle(forReadingFrom: bodyURL(file)) else {
            return Data()
        }
        defer { try? handle.close() }
        // The file may already hold bytes from a write that hasn't committed yet.
        return (try? handle.read(upToCount: min(body.size, limit))) ?? Data()
    }

    func bodyURL(_ file: String) -> URL {
        directory.appending(path: "bodies", directoryHint: .isDirectory).appending(path: file)
    }
}
