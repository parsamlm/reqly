import Foundation
import GRDB
import ReqlyModel

/// The session database's tables. The same database becomes a session file when you save it,
/// so changes go in new migrations, never by editing an old one.
enum Schema {
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: ExchangeRecord.databaseTableName) { table in
                table.primaryKey("id", .integer)
                table.column("connectionID", .integer).notNull()
                table.column("kind", .text).notNull()
                table.column("method", .text).notNull()
                table.column("scheme", .text).notNull()
                table.column("host", .text).notNull()
                table.column("port", .integer).notNull()
                table.column("target", .text).notNull()
                table.column("requestVersion", .text).notNull()
                table.column("requestHeaders", .text).notNull()
                table.column("status", .integer)
                table.column("reason", .text)
                table.column("responseVersion", .text)
                table.column("responseHeaders", .text)
                table.column("contentType", .text)
                table.column("state", .text).notNull()
                table.column("isFinished", .boolean).notNull()
                table.column("started", .double).notNull()
                table.column("requestEnded", .double)
                table.column("connectStarted", .double)
                table.column("connected", .double)
                table.column("responseStarted", .double)
                table.column("ended", .double)
                table.column("bytesSent", .integer).notNull()
                table.column("bytesReceived", .integer).notNull()
            }
            try db.create(table: "body") { table in
                table.column("exchangeID", .integer).notNull()
                    .references(ExchangeRecord.databaseTableName, onDelete: .cascade)
                table.column("part", .integer).notNull()
                table.column("size", .integer).notNull()
                // The bytes, for a body small enough to keep in the database.
                table.column("data", .blob)
                // Otherwise the name of the body's file in the session's `bodies` folder.
                table.column("file", .text)
                table.primaryKey(["exchangeID", "part"])
            }
            // A trigram index finds any text of three characters or more, anywhere in a value.
            // It keeps no copy of the text, so the bodies aren't stored twice.
            try db.execute(
                sql: """
                    CREATE VIRTUAL TABLE search USING fts5(
                        url, headers, body, content='', contentless_delete=1, tokenize='trigram'
                    )
                    """
            )
        }
        migrator.registerMigration("v2: sources") { db in
            // The apps and tools that sent traffic, each stored once.
            try db.create(table: "source") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
                table.column("bundleID", .text)
                table.column("path", .text)
            }
            try db.execute(
                sql: "CREATE UNIQUE INDEX source_identity ON source(name, IFNULL(bundleID, ''), IFNULL(path, ''))"
            )
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "sourceID", .integer).references("source")
            }
        }
        migrator.registerMigration("v3: connection timing") { db in
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "resolved", .double)
                table.add(column: "secured", .double)
                table.add(column: "requestSent", .double)
                table.add(column: "remoteAddress", .text)
                table.add(column: "tlsVersion", .text)
                table.add(column: "reusedConnection", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v4: annotations") { db in
            // Set only by ``TrafficStore/annotate(_:with:)``. Saving traffic leaves them alone.
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "pinned", .boolean).notNull().defaults(to: false)
                table.add(column: "color", .text)
                table.add(column: "comment", .text)
            }
        }
        migrator.registerMigration("v5: applied rules") { db in
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "appliedRules", .text)
            }
        }
        migrator.registerMigration("v6: devices") { db in
            // The phones, simulators and emulators that sent traffic, each stored once.
            try db.create(table: "device") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull()
                table.column("name", .text).notNull()
                table.column("address", .text)
            }
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "deviceID", .text).references("device")
            }
        }
        migrator.registerMigration("v7: server protocol") { db in
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "serverProtocol", .text)
            }
        }
        migrator.registerMigration("v8: websocket messages") { db in
            // The messages of exchanges that switched to WebSocket, numbered in order.
            try db.create(table: "message") { table in
                table.column("exchangeID", .integer).notNull()
                    .references(ExchangeRecord.databaseTableName, onDelete: .cascade)
                table.column("number", .integer).notNull()
                table.column("direction", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("time", .double).notNull()
                table.column("size", .integer).notNull()
                table.column("closeCode", .integer)
                table.column("data", .blob).notNull()
                table.primaryKey(["exchangeID", "number"])
            }
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "messageCount", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v9: response trailers") { db in
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "responseTrailers", .text)
            }
        }
        migrator.registerMigration("v10: proxies") { db in
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "upstreamProxy", .text)
                table.add(column: "reverseProxy", .text)
                table.add(column: "clientCertificate", .text)
            }
        }
        migrator.registerMigration("v11: script output") { db in
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "scriptOutput", .text)
            }
        }
        migrator.registerMigration("v12: sent by Reqly") { db in
            // Requests saved before Reqly kept this read as an app's.
            try db.alter(table: ExchangeRecord.databaseTableName) { table in
                table.add(column: "sentByReqly", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }()
}

/// One row of the `exchange` table: everything about an exchange except its bodies.
struct ExchangeRecord: Decodable, FetchableRecord, TableRecord {
    static let databaseTableName = "exchange"

    private static let columns = [
        "id", "connectionID", "kind", "method", "scheme", "host", "port", "target", "requestVersion",
        "requestHeaders", "status", "reason", "responseVersion", "responseHeaders", "contentType", "state",
        "isFinished", "started", "requestEnded", "connectStarted", "resolved", "connected", "secured", "requestSent",
        "responseStarted", "ended", "bytesSent", "bytesReceived", "sourceID", "remoteAddress", "tlsVersion",
        "reusedConnection", "appliedRules", "deviceID", "serverProtocol", "messageCount",
        "responseTrailers", "upstreamProxy", "reverseProxy", "clientCertificate", "scriptOutput", "sentByReqly",
    ]

    /// Selects exchanges with their sources and devices, whose columns are named as below.
    static let selectWithSource = """
        SELECT exchange.*, source.name AS sourceName, source.bundleID AS sourceBundleID, source.path AS sourcePath,
            device.kind AS deviceKind, device.name AS deviceName, device.address AS deviceAddress
        FROM exchange LEFT JOIN source ON source.id = exchange.sourceID LEFT JOIN device ON device.id = exchange.deviceID
        """

    /// Adds a device, or brings its row up to date.
    static let upsertDeviceSQL = """
        INSERT INTO device (id, kind, name, address) VALUES (?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, name = excluded.name, address = excluded.address
        """

    /// Inserts a row, or updates the row with the same ID. It leaves the annotation alone, so
    /// saving traffic never undoes a pin or a comment.
    static let upsertSQL = """
        INSERT INTO exchange (\(columns.joined(separator: ", ")))
        VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
        ON CONFLICT (id) DO UPDATE SET \(columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
        """

    var id: Int64
    var connectionID: Int64
    var kind: String
    var method: String
    var scheme: String
    var host: String
    var port: Int
    var target: String
    var requestVersion: String
    var requestHeaders: Headers
    var status: Int?
    var reason: String?
    var responseVersion: String?
    var responseHeaders: Headers?
    var contentType: String?
    var state: ExchangeState
    var isFinished: Bool
    var started: Double
    var requestEnded: Double?
    var connectStarted: Double?
    var resolved: Double?
    var connected: Double?
    var secured: Double?
    var requestSent: Double?
    var responseStarted: Double?
    var ended: Double?
    var bytesSent: Int64
    var bytesReceived: Int64
    var sourceID: Int64?
    var remoteAddress: String?
    var tlsVersion: String?
    var reusedConnection: Bool
    /// JSON, and `nil` when no rule acted.
    var appliedRules: [AppliedRule]?
    var deviceID: String?
    var serverProtocol: String?
    var messageCount: Int
    var responseTrailers: Headers?
    var upstreamProxy: String?
    var reverseProxy: String?
    var clientCertificate: String?
    /// JSON, and `nil` when no script printed anything.
    var scriptOutput: [ScriptOutput]?
    var sentByReqly: Bool
    // Read, but never written by ``upsertSQL``.
    var pinned: Bool
    var color: String?
    var comment: String?
    // Read only from ``selectWithSource``.
    var sourceName: String?
    var sourceBundleID: String?
    var sourcePath: String?
    var deviceKind: String?
    var deviceName: String?
    var deviceAddress: String?

    init(_ exchange: Exchange, sourceID: Int64?) {
        id = exchange.id.storageID
        connectionID = Int64(bitPattern: exchange.connectionID.rawValue)
        kind = exchange.kind == .tunnel ? "tunnel" : "http"
        method = exchange.request.method
        scheme = exchange.request.scheme
        host = exchange.request.host
        port = exchange.request.port
        target = exchange.request.target
        requestVersion = exchange.request.version
        requestHeaders = exchange.request.headers
        status = exchange.response?.status
        reason = exchange.response?.reason
        responseVersion = exchange.response?.version
        responseHeaders = exchange.response?.headers
        contentType = exchange.response?.headers["Content-Type"]
        state = exchange.state
        isFinished = exchange.state.isFinished
        started = exchange.timing.started.timeIntervalSinceReferenceDate
        requestEnded = exchange.timing.requestEnded?.timeIntervalSinceReferenceDate
        connectStarted = exchange.timing.connectStarted?.timeIntervalSinceReferenceDate
        resolved = exchange.timing.resolved?.timeIntervalSinceReferenceDate
        connected = exchange.timing.connected?.timeIntervalSinceReferenceDate
        secured = exchange.timing.secured?.timeIntervalSinceReferenceDate
        requestSent = exchange.timing.requestSent?.timeIntervalSinceReferenceDate
        responseStarted = exchange.timing.responseStarted?.timeIntervalSinceReferenceDate
        ended = exchange.timing.ended?.timeIntervalSinceReferenceDate
        bytesSent = exchange.bytesSent
        bytesReceived = exchange.bytesReceived
        self.sourceID = sourceID
        remoteAddress = exchange.remoteAddress
        tlsVersion = exchange.tlsVersion
        reusedConnection = exchange.reusedConnection
        appliedRules = exchange.appliedRules.isEmpty ? nil : exchange.appliedRules
        deviceID = exchange.device?.id
        serverProtocol = exchange.serverProtocol
        messageCount = exchange.messageCount
        responseTrailers = exchange.responseTrailers
        upstreamProxy = exchange.upstreamProxy
        reverseProxy = exchange.reverseProxy
        clientCertificate = exchange.clientCertificate
        scriptOutput = exchange.scriptOutput.isEmpty ? nil : exchange.scriptOutput
        sentByReqly = exchange.sentByReqly
        pinned = exchange.annotation.isPinned
        color = exchange.annotation.color?.rawValue
        comment = exchange.annotation.comment
    }

    /// The values for ``upsertSQL``. Headers and the state are stored as JSON.
    func arguments(_ encoder: JSONEncoder) throws -> StatementArguments {
        func json(_ value: some Encodable) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        return [
            id, connectionID, kind, method, scheme, host, port, target, requestVersion,
            try json(requestHeaders), status, reason, responseVersion, try responseHeaders.map(json), contentType,
            try json(state), isFinished, started, requestEnded, connectStarted, resolved, connected, secured,
            requestSent, responseStarted, ended, bytesSent, bytesReceived, sourceID, remoteAddress, tlsVersion,
            reusedConnection, try appliedRules.map(json), deviceID, serverProtocol, messageCount,
            try responseTrailers.map(json), upstreamProxy, reverseProxy, clientCertificate,
            try scriptOutput.map(json), sentByReqly,
        ]
    }

    /// The exchange this row describes, with empty bodies.
    var exchange: Exchange {
        let request = RequestHead(
            method: method, scheme: scheme, host: host, port: port, target: target,
            version: requestVersion, headers: requestHeaders
        )
        var exchange = Exchange(
            id: ExchangeID(storageID: id),
            connectionID: ConnectionID(rawValue: UInt64(bitPattern: connectionID)),
            kind: kind == "tunnel" ? .tunnel : .http,
            request: request,
            started: Date(timeIntervalSinceReferenceDate: started)
        )
        if let status, let reason, let responseVersion, let responseHeaders {
            exchange.response = ResponseHead(
                status: status, reason: reason, version: responseVersion, headers: responseHeaders
            )
        }
        exchange.state = state
        exchange.timing.requestEnded = requestEnded.map(Date.init(timeIntervalSinceReferenceDate:))
        exchange.timing.connectStarted = connectStarted.map(Date.init(timeIntervalSinceReferenceDate:))
        exchange.timing.resolved = resolved.map(Date.init(timeIntervalSinceReferenceDate:))
        exchange.timing.connected = connected.map(Date.init(timeIntervalSinceReferenceDate:))
        exchange.timing.secured = secured.map(Date.init(timeIntervalSinceReferenceDate:))
        exchange.timing.requestSent = requestSent.map(Date.init(timeIntervalSinceReferenceDate:))
        exchange.timing.responseStarted = responseStarted.map(Date.init(timeIntervalSinceReferenceDate:))
        exchange.timing.ended = ended.map(Date.init(timeIntervalSinceReferenceDate:))
        exchange.bytesSent = bytesSent
        exchange.bytesReceived = bytesReceived
        exchange.source = sourceName.map { Source(name: $0, bundleID: sourceBundleID, path: sourcePath) }
        if let deviceID, let deviceName, let kind = deviceKind.flatMap(Device.Kind.init(rawValue:)) {
            exchange.device = Device(id: deviceID, kind: kind, name: deviceName, address: deviceAddress)
        }
        exchange.remoteAddress = remoteAddress
        exchange.tlsVersion = tlsVersion
        exchange.reusedConnection = reusedConnection
        exchange.serverProtocol = serverProtocol
        exchange.messageCount = messageCount
        exchange.responseTrailers = responseTrailers
        exchange.upstreamProxy = upstreamProxy
        exchange.reverseProxy = reverseProxy
        exchange.clientCertificate = clientCertificate
        exchange.sentByReqly = sentByReqly
        exchange.scriptOutput = scriptOutput ?? []
        exchange.appliedRules = appliedRules ?? []
        exchange.annotation = Annotation(isPinned: pinned, color: color.flatMap(MarkColor.init), comment: comment)
        return exchange
    }
}

/// What the store keeps of one body: its bytes, or the name of the file that holds them.
struct StoredBody {
    var size: Int
    var data: Data?
    var file: String?

    static func fetch(_ key: BodyKey, in db: Database) throws -> StoredBody? {
        let statement = try db.cachedStatement(
            sql: "SELECT size, data, file FROM body WHERE exchangeID = ? AND part = ?"
        )
        guard let row = try Row.fetchOne(statement, arguments: [key.exchange.storageID, key.part.rawValue]) else {
            return nil
        }
        return StoredBody(size: row[0], data: row[1], file: row[2])
    }

    func save(_ key: BodyKey, in db: Database) throws {
        let statement = try db.cachedStatement(
            sql: """
                INSERT INTO body (exchangeID, part, size, data, file) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (exchangeID, part) DO UPDATE
                SET size = excluded.size, data = excluded.data, file = excluded.file
                """
        )
        try statement.execute(arguments: [key.exchange.storageID, key.part.rawValue, size, data, file])
    }
}

extension ExchangeID {
    /// The ID as SQLite stores it. IDs count up from 1, so they never reach the sign bit.
    var storageID: Int64 { Int64(bitPattern: rawValue) }

    init(storageID: Int64) {
        self.init(rawValue: UInt64(bitPattern: storageID))
    }
}
