import CSQLite
import Foundation

/// Chromium's own list of the certificates you imported in it, which Chromium 156 and Google Chrome
/// keep in each profile, apart from the NSS databases: the `ServerCertificate` file, an SQLite
/// database, which Settings › Privacy and security › Security › Manage certificates › Local
/// certificates › Installed by you shows. The Chromium snap on Ubuntu 26.04 can't read the trust
/// Reqly adds to its NSS database, so you import Reqly's certificate there yourself, and only you
/// can delete it there.
///
/// Reqly only reads it, to say when Chromium still trusts its certificate, and only from a copy in
/// memory: Chromium keeps the file open and locked while it runs, and could be changing it, so
/// Reqly reads its bytes, taking no lock, and opens only that copy with SQLite, never the file.
/// Reqly never writes the file, or anything beside it.
public struct ChromiumStore: Sendable, Equatable {
    public enum Browser: Sendable, Equatable {
        /// The Chromium snap, in `~/snap/chromium/common/chromium`.
        case chromiumSnap
        /// Chromium from a package, such as Debian's, in `~/.config/chromium`.
        case chromium
        /// Google Chrome, in `~/.config/google-chrome`, or its beta's or unstable's folder.
        case chrome
    }

    /// What the list says of a certificate, by the list you imported it under.
    public enum Trust: Sendable, Equatable {
        /// Trusted Certificates: Chromium trusts it to identify websites.
        case trusted
        /// Distrusted Certificates.
        case distrusted
        /// Intermediate Certificates, which trust nothing by themselves.
        case unspecified
    }

    public var browser: Browser
    /// The profile's `ServerCertificate`.
    public var file: URL
    /// How many times Reqly reads the file before it gives up, while Chromium is changing it, and
    /// how long it waits in between, in seconds, which only tests change.
    var attempts = 5
    var pause: TimeInterval = 0.1

    public init(browser: Browser, file: URL) {
        self.browser = browser
        self.file = file
    }

    /// The browser's name, as its window says it.
    public var name: String { browser == .chrome ? "Google Chrome" : "Chromium" }

    /// What the list says of the certificate `der`, or nil when it isn't on it. Reqly finds its
    /// certificate by its bytes alone, never by its name, so it never takes another certificate
    /// called "Reqly CA" for its own. It throws when the list can't be read, such as while Chromium
    /// keeps changing it.
    func trust(of der: [UInt8]) throws(TrustFailure) -> Trust? {
        for attempt in 1...max(attempts, 1) {
            if attempt > 1 {
                Thread.sleep(forTimeInterval: pause)
            }
            // A copy taken while Chromium was writing can be torn, which SQLite then can't read.
            guard let copy = steadyCopy(), let rows = try? Self.rows(in: copy) else { continue }
            return rows.first { $0.der == der }.map { Self.trust(in: $0.settings) }
        }
        throw TrustFailure(message: "Reqly couldn't read \(name)'s own list of certificates, \(file.path).")
    }

    // MARK: -

    /// The file's bytes, read while Chromium wasn't changing it, or nil. Chromium writes it with a
    /// rollback journal beside it, `ServerCertificate-journal`, which is empty or missing between
    /// changes; so the journal must be empty before and after, and neither file may change while
    /// it's read.
    private func steadyCopy() -> Data? {
        let others = ["-journal", "-wal"].map { URL(filePath: file.path + $0) }
        let before = ([file] + others).map(Self.stamp)
        guard before[0] != nil, before.dropFirst().allSatisfy({ ($0?.size ?? 0) == 0 }),
            let data = try? Data(contentsOf: file)
        else { return nil }
        return ([file] + others).map(Self.stamp) == before ? data : nil
    }

    /// What changes when a file does: its size, when it was last changed, and which file it is.
    private struct Stamp: Equatable {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var modified: [Int]
        var changed: [Int]
    }

    private static func stamp(_ url: URL) -> Stamp? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return Stamp(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size),
            modified: [Int(status.st_mtim.tv_sec), Int(status.st_mtim.tv_nsec)],
            changed: [Int(status.st_ctim.tv_sec), Int(status.st_ctim.tv_nsec)])
    }

    /// Each certificate on the list, in DER, with its trust settings, from a copy of the database
    /// that SQLite opens in memory, read-only.
    static func rows(in copy: Data) throws(TrustFailure) -> [(der: [UInt8], settings: [UInt8])] {
        let failure = TrustFailure(message: "SQLite couldn't read the copy.")
        var connection: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            let connection
        else {
            sqlite3_close(connection)
            throw failure
        }
        defer { sqlite3_close(connection) }
        guard !copy.isEmpty, let buffer = sqlite3_malloc64(UInt64(copy.count))?.assumingMemoryBound(to: UInt8.self)
        else { throw failure }
        copy.copyBytes(to: buffer, count: copy.count)
        // SQLite frees the buffer with the connection, or at once when it can't take it.
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
        guard sqlite3_deserialize(connection, "main", buffer, Int64(copy.count), Int64(copy.count), flags) == SQLITE_OK
        else { throw failure }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(connection, "SELECT der_cert, trust_settings FROM certificates", -1, &statement, nil)
                == SQLITE_OK, let statement
        else { throw failure }
        defer { sqlite3_finalize(statement) }
        var rows: [(der: [UInt8], settings: [UInt8])] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append((blob(statement, 0), blob(statement, 1)))
            case SQLITE_DONE: return rows
            default: throw failure
            }
        }
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> [UInt8] {
        guard let bytes = sqlite3_column_blob(statement, column) else { return [] }
        return Array(UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))))
    }

    /// The trust a row's settings hold: Chromium's CertificateMetadata, a protocol buffer whose
    /// field 1 is a CertificateTrust, whose field 1 is 3 for trusted, 2 for distrusted, and 1 or 0
    /// for neither. Its constraints, field 2, limit the names it's trusted for, which Reqly's
    /// certificate never has.
    static func trust(in settings: [UInt8]) -> Trust {
        guard case .bytes(let trust)? = field(1, in: settings[...]), case .number(let kind)? = field(1, in: trust)
        else { return .unspecified }
        switch kind {
        case 3: return .trusted
        case 2: return .distrusted
        default: return .unspecified
        }
    }

    private enum Field {
        case number(UInt64)
        case bytes(ArraySlice<UInt8>)
    }

    /// Field `number` of the protocol buffer `message`, its last value when it comes more than
    /// once, as the format reads it, or nil when it isn't there, or the message isn't one.
    private static func field(_ number: UInt64, in message: ArraySlice<UInt8>) -> Field? {
        var index = message.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < message.endIndex, shift < 64 {
                let byte = message[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        func bytes(_ count: UInt64) -> ArraySlice<UInt8>? {
            guard count <= UInt64(message.endIndex - index) else { return nil }
            defer { index += Int(count) }
            return message[index..<index + Int(count)]
        }
        var found: Field?
        while index < message.endIndex {
            guard let key = varint() else { return nil }
            let value: Field
            switch key & 7 {
            case 0:
                guard let number = varint() else { return nil }
                value = .number(number)
            case 1, 5:
                guard let fixed = bytes(key & 7 == 1 ? 8 : 4) else { return nil }
                value = .bytes(fixed)
            case 2:
                guard let count = varint(), let delimited = bytes(count) else { return nil }
                value = .bytes(delimited)
            default:
                return nil
            }
            if key >> 3 == number {
                found = value
            }
        }
        return found
    }
}

/// Where Chromium's own lists still trust one of Reqly's certificates, which only you can change,
/// and the lists Reqly couldn't read, with what Reqly tells you about them.
public struct ChromiumCopies: Sendable, Equatable {
    /// The lists that trust it, as after you imported it under Trusted Certificates.
    public var trusting: [ChromiumStore]
    /// The lists Reqly couldn't read, which may trust it too.
    public var unread: [ChromiumStore]

    public init(trusting: [ChromiumStore] = [], unread: [ChromiumStore] = []) {
        self.trusting = trusting
        self.unread = unread
    }

    /// The way to the list in Chromium's and Google Chrome's settings.
    public static let path =
        "Settings › Privacy and security › Security › Manage certificates › Local certificates › Installed by you"

    /// What Remove Certificate…'s question adds while a list trusts the certificate, or nil.
    public var reminder: String? {
        let names = Self.names(trusting)
        guard !names.isEmpty else { return nil }
        return "\(Self.list(names)) \(names.count == 1 ? "keeps" : "keep") the copy you imported in "
            + "\(names.count == 1 ? "its" : "their") own settings: delete it there afterwards."
    }

    /// What the window says once Reqly has removed the certificate called `certificate`, or its
    /// old one, from every place it can reach, about the lists that still trust it, or that it
    /// couldn't read; nil when there are none.
    public func note(certificate: String?, old: Bool = false) -> String? {
        var sentences: [String] = []
        let trustingNames = Self.names(trusting)
        if !trustingNames.isEmpty {
            let one = trustingNames.count == 1
            let it = old ? "Reqly's old certificate" : "Reqly's certificate"
            let named = certificate.map { "\(it), \"\($0)\"," } ?? "\(it),"
            sentences.append(
                "\(Self.list(trustingNames)) still \(one ? "trusts" : "trust") \(named) since you imported it in "
                    + "\(one ? "its" : "their") own settings, which Reqly can't change. "
                    + "Delete it there: in \(one ? "\(trustingNames[0])'s" : "each one's") \(Self.path), "
                    + "under Trusted Certificates.")
        }
        let unreadNames = Self.names(unread).filter { !trustingNames.contains($0) }
        if !unreadNames.isEmpty {
            let one = unreadNames.count == 1
            sentences.append(
                "Reqly couldn't read \(Self.list(unreadNames.map { "\($0)'s" })) own "
                    + "\(one ? "list" : "lists") of certificates. If you imported Reqly's certificate there, delete it "
                    + "there too: in \(one ? "\(unreadNames[0])'s" : "each one's") \(Self.path), under Trusted "
                    + "Certificates.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// What `reqly --remove-certificate` says of each browser whose list still trusts the
    /// certificate called `certificate`, or that it couldn't read, once it removed the rest.
    public func lines(certificate: String?) -> [String] {
        let trustingNames = Self.names(trusting)
        let named = certificate.map { "\"\($0)\"" } ?? "it"
        var lines = trustingNames.map { name in
            let profiles = trusting.filter { $0.name == name }.count
            return "\(name): still trusts it\(profiles > 1 ? " in \(profiles) profiles" : ""), since you imported it "
                + "in its own settings, which Reqly can't change. Delete \(named) there: \(Self.path), under Trusted "
                + "Certificates."
        }
        lines += Self.names(unread).filter { !trustingNames.contains($0) }.map { name in
            "\(name): Reqly couldn't read \(name)'s own list of certificates. If you imported Reqly's certificate "
                + "there, delete it there too: \(Self.path), under Trusted Certificates."
        }
        return lines
    }

    /// The browsers' names, each once, in order.
    private static func names(_ stores: [ChromiumStore]) -> [String] {
        var names: [String] = []
        for store in stores where !names.contains(store.name) {
            names.append(store.name)
        }
        return names
    }

    private static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
