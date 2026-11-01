import CSQLite
import CertificateAuthority
import Foundation
import Testing

@testable import LinuxTrust

/// Chromium's own list of the certificates you imported, `ServerCertificate`, made as Chromium 156
/// makes it: Reqly reads it from a copy while Chromium holds it open, and never changes it.
@Suite struct ChromiumStoreTests {
    /// The trust settings Chromium keeps for a certificate imported under Trusted Certificates,
    /// Intermediate Certificates and Distrusted Certificates: CertificateMetadata { trust {
    /// trust_type } }.
    static let trusted: [UInt8] = [0x0a, 0x02, 0x08, 0x03]
    static let unspecified: [UInt8] = [0x0a, 0x02, 0x08, 0x01]
    static let distrusted: [UInt8] = [0x0a, 0x02, 0x08, 0x02]

    /// Makes a list at `file` as Chromium does, with its tables and settings, holding `rows`, each
    /// a certificate and its trust settings, and keeps it open, locked, with its rollback journal
    /// beside it, as Chromium does while it runs, until `body` returns.
    static func withList(at file: URL, rows: [([UInt8], [UInt8])], _ body: () throws -> Void = {}) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        try #require(sqlite3_open_v2(file.path, &connection, flags, nil) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        func run(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(connection, sql, nil, nil, &message)
            defer { sqlite3_free(message) }
            try #require(result == SQLITE_OK, "\(sql): \(message.map { String(cString: $0) } ?? "")")
        }
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        try run("PRAGMA locking_mode=EXCLUSIVE")
        try run("PRAGMA journal_mode=TRUNCATE")
        try run("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
        try run("INSERT INTO meta VALUES('version', '1'), ('last_compatible_version', '1')")
        try run(
            "CREATE TABLE IF NOT EXISTS certificates(sha256hash_hex TEXT PRIMARY KEY, der_cert BLOB NOT NULL, "
                + "trust_settings BLOB NOT NULL)")
        // Chromium's key is the certificate's SHA-256, which Reqly doesn't read: it compares the bytes.
        for (index, row) in rows.enumerated() {
            try run("INSERT OR REPLACE INTO certificates VALUES('row \(index)', x'\(hex(row.0))', x'\(hex(row.1))')")
        }
        try body()
    }

    /// What `ls -l --time-style=full-iso` would show of each file in `folder`: its name, size and
    /// modification time.
    static func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().map { name in
            var status = stat()
            stat(folder.appending(path: name).path, &status)
            return "\(name) \(status.st_size) \(status.st_mtim.tv_sec).\(status.st_mtim.tv_nsec)"
        }
    }

    @Test func readsWhatTheListSaysWhileChromiumHoldsIt() throws {
        let reqly = try Fixtures.root(minute: 10).certificateDER
        let intermediate = try Fixtures.root(minute: 11).certificateDER
        let distrusted = try Fixtures.root(minute: 12).certificateDER
        // Another certificate with the name of one Reqly asks about, which isn't on the list.
        let absent = try Fixtures.root(minute: 13).certificateDER
        let decoy = try Fixtures.root(minute: 13).certificateDER
        // Trusted, with a name constraint, after a field this Reqly doesn't know.
        let constrained: [UInt8] = [0x78, 0x01] + Self.trusted + [0x12, 0x0d, 0x0a, 0x0b] + Array("example.com".utf8)
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Default/ServerCertificate")
            let rows = [(decoy, Self.trusted), (intermediate, Self.unspecified), (distrusted, Self.distrusted)]
            try Self.withList(at: file, rows: rows + [(reqly, constrained)]) {
                let before = try Data(contentsOf: file)
                let listed = try Self.listing(file.deletingLastPathComponent())
                #expect(listed.contains { $0.hasPrefix("ServerCertificate-journal 0 ") })

                let store = ChromiumStore(browser: .chromiumSnap, file: file)
                #expect(try store.trust(of: reqly) == .trusted)
                #expect(try store.trust(of: intermediate) == .unspecified)
                #expect(try store.trust(of: distrusted) == .distrusted)
                #expect(try store.trust(of: absent) == nil)

                // As it was, and nothing new beside it.
                #expect(try Data(contentsOf: file) == before)
                #expect(try Self.listing(file.deletingLastPathComponent()) == listed)
            }
        }
    }

    /// While Chromium is changing the list, its rollback journal isn't empty, and Reqly tries again
    /// a few times, then says it couldn't read it.
    @Test func givesUpWhileChromiumIsChangingIt() throws {
        let reqly = try Fixtures.root(minute: 14).certificateDER
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "ServerCertificate")
            try Self.withList(at: file, rows: [(reqly, Self.trusted)])
            try Data(repeating: 0xd9, count: 512).write(to: URL(filePath: file.path + "-journal"))
            var store = ChromiumStore(browser: .chrome, file: file)
            store.attempts = 3
            store.pause = 0.01
            let failure = TrustFailure(
                message: "Reqly couldn't read Google Chrome's own list of certificates, \(file.path).")
            #expect(throws: failure) { try store.trust(of: reqly) }

            // Nor something that isn't a list at all.
            try Data().write(to: URL(filePath: file.path + "-journal"))
            #expect(try store.trust(of: reqly) == .trusted)
            try Data("not SQLite".utf8).write(to: file)
            #expect(throws: TrustFailure.self) { try store.trust(of: reqly) }
        }
    }

    @Test func findsTheListInEachProfile() throws {
        try Fixtures.withFolder { home throws in
            let files = [
                "snap/chromium/common/chromium/Default", "snap/chromium/common/chromium/Profile 1",
                "config/chromium/Default", "config/google-chrome/Default", "config/google-chrome-beta/Profile 2",
                // Not where XDG_CONFIG_HOME says.
                ".config/chromium/Default",
            ]
            for folder in files {
                try FileManager.default.createDirectory(
                    at: home.appending(path: folder), withIntermediateDirectories: true)
                try Data().write(to: home.appending(path: folder).appending(path: "ServerCertificate"))
            }
            // A profile that hasn't run has no list.
            try FileManager.default.createDirectory(
                at: home.appending(path: "config/google-chrome/Guest Profile"), withIntermediateDirectories: true)
            let locations = TrustLocations(
                environment: ["HOME": home.path, "XDG_CONFIG_HOME": home.appending(path: "config").path])
            let found = locations.chromiumStores().map { store in
                "\(store.name): \(store.file.path.dropFirst(home.path.count + 1))"
            }
            #expect(
                found == [
                    "Chromium: snap/chromium/common/chromium/Default/ServerCertificate",
                    "Chromium: snap/chromium/common/chromium/Profile 1/ServerCertificate",
                    "Chromium: config/chromium/Default/ServerCertificate",
                    "Google Chrome: config/google-chrome/Default/ServerCertificate",
                    "Google Chrome: config/google-chrome-beta/Profile 2/ServerCertificate",
                ])
            #expect(locations.chromiumStores().first?.browser == .chromiumSnap)
        }
    }

    /// Chromium's list counts as a place that trusts the certificate, so Reqly decrypts when you
    /// imported it only there, and says so for removal.
    @Test func countsChromiumsListAsTrustingIt() throws {
        let root = try Fixtures.root(minute: 15)
        let der = try root.certificateDER
        try Fixtures.withFolder { home throws in
            let list = home.appending(path: "ca-certificates.crt")
            try Data().write(to: list)
            let store = LinuxRootStore(
                file: home.appending(path: ".local/share/reqly/Certificate.dat"), keyring: nil,
                helper: home.appending(path: "no-helper").path, pkexec: home.appending(path: "no-pkexec").path,
                environment: ["HOME": home.path, "PATH": home.appending(path: "no-bin").path], uid: 4252,
                computerBundle: list.path)
            #expect(!store.isTrusted(root))
            #expect(store.chromiumCopies(of: der) == ChromiumCopies())

            let file = home.appending(path: "snap/chromium/common/chromium/Default/ServerCertificate")
            try Self.withList(at: file, rows: [(der, Self.unspecified)])
            #expect(!store.isTrusted(root))
            try FileManager.default.removeItem(at: file)
            try Self.withList(at: file, rows: [(der, Self.trusted)])
            #expect(store.isTrusted(root))
            #expect(
                store.chromiumCopies(of: der)
                    == ChromiumCopies(trusting: [ChromiumStore(browser: .chromiumSnap, file: file)]))
        }
    }

    /// What Reqly says of the lists that still trust its certificate once the rest has gone, and
    /// of those it couldn't read.
    @Test func saysToDeleteItInChromium() {
        let snap = ChromiumStore(
            browser: .chromiumSnap,
            file: URL(filePath: "/home/ana/snap/chromium/common/chromium/Default/ServerCertificate"))
        let chrome = ChromiumStore(
            browser: .chrome, file: URL(filePath: "/home/ana/.config/google-chrome/Default/ServerCertificate"))
        let other = ChromiumStore(
            browser: .chrome, file: URL(filePath: "/home/ana/.config/google-chrome/Profile 1/ServerCertificate"))
        let path =
            "Settings › Privacy and security › Security › Manage certificates › Local certificates › Installed by you"
        #expect(ChromiumCopies().note(certificate: "Reqly CA 2026-11-01 16:37") == nil)
        #expect(ChromiumCopies().lines(certificate: nil).isEmpty)
        #expect(ChromiumCopies().reminder == nil)

        let one = ChromiumCopies(trusting: [snap])
        #expect(
            one.note(certificate: "Reqly CA 2026-11-01 16:37")
                == "Chromium still trusts Reqly's certificate, \"Reqly CA 2026-11-01 16:37\", since you imported it in "
                + "its own settings, which Reqly can't change. Delete it there: in Chromium's \(path), under Trusted "
                + "Certificates.")
        #expect(
            one.lines(certificate: "Reqly CA 2026-11-01 16:37") == [
                "Chromium: still trusts it, since you imported it in its own settings, which Reqly can't change. "
                    + "Delete \"Reqly CA 2026-11-01 16:37\" there: \(path), under Trusted Certificates."
            ])
        #expect(one.reminder == "Chromium keeps the copy you imported in its own settings: delete it there afterwards.")
        #expect(
            one.note(certificate: nil, old: true)?.hasPrefix(
                "Chromium still trusts Reqly's old certificate, since you imported it") == true)

        let two = ChromiumCopies(trusting: [snap, chrome, other])
        #expect(
            two.note(certificate: "Reqly CA 2026-11-01 16:37")
                == "Chromium and Google Chrome still trust Reqly's certificate, \"Reqly CA 2026-11-01 16:37\", since you "
                + "imported it in their own settings, which Reqly can't change. Delete it there: in each one's \(path), "
                + "under Trusted Certificates.")
        #expect(
            two.lines(certificate: nil).last?.hasPrefix("Google Chrome: still trusts it in 2 profiles, since") == true)
        #expect(two.reminder?.hasPrefix("Chromium and Google Chrome keep the copy you imported in their own") == true)

        let unread = ChromiumCopies(unread: [snap])
        #expect(
            unread.note(certificate: "Reqly CA 2026-11-01 16:37")
                == "Reqly couldn't read Chromium's own list of certificates. If you imported Reqly's certificate there, "
                + "delete it there too: in Chromium's \(path), under Trusted Certificates.")
        #expect(
            unread.lines(certificate: nil) == [
                "Chromium: couldn't read its own list of certificates. If you imported Reqly's certificate there, "
                    + "delete it in its \(path), under Trusted Certificates."
            ])
        #expect(unread.reminder == nil)
        // A browser said to trust it isn't said to be unread too.
        #expect(ChromiumCopies(trusting: [chrome], unread: [other]).lines(certificate: nil).count == 1)
    }
}
