import CertificateAuthority
import Foundation
import Testing

@testable import LinuxTrust

/// Reqly's key gone from the keyring, as after you reset it: Reqly says so rather than "not set
/// up", setting up again takes the old certificate out of the databases it was added to, and
/// removing it goes by its record.
@Suite(.enabled(if: Fixtures.certutil != nil, "Needs certutil, from libnss3-tools."))
struct KeyGoneTests {
    /// A home folder with a browsers' database, a keyring in memory, and an empty computer's list.
    func withStore(_ body: (LinuxRootStore, FakeKeyring, NSSDatabase) throws -> Void) throws {
        try Fixtures.withFolder { home throws in
            let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let database = NSSDatabase(
                folder: home.appending(path: ".pki/nssdb"), certutil: try #require(Fixtures.certutil),
                environment: environment)
            try database.create()
            let list = home.appending(path: "ca-certificates.crt")
            try Data().write(to: list)
            let keyring = FakeKeyring()
            let store = LinuxRootStore(
                file: home.appending(path: ".local/share/reqly/Certificate.dat"), keyring: keyring,
                helper: home.appending(path: "no-helper").path, pkexec: home.appending(path: "no-pkexec").path,
                environment: environment, uid: 4251, computerBundle: list.path)
            try body(store, keyring, database)
        }
    }

    @Test func saysTheKeyIsGoneAndANewSetupTakesTheOldCertificateOut() throws {
        try withStore { store, keyring, database in
            let old = try Fixtures.root(minute: 50)
            try store.save(old)
            #expect(store.keyPlace == .keyring)
            #expect(store.trust(old, in: [.browsers]).isEmpty)
            #expect(try database.holding(old) == .trusted)

            // The keyring was reset.
            keyring.secret.withLock { $0 = nil }
            #expect(throws: LinuxRootStore.KeyGone()) { try store.load() }

            let new = try Fixtures.root(minute: 51)
            try store.save(new)
            #expect(try database.holding(old) == .absent)
            #expect(try store.load()?.certificateDER == new.certificateDER)
        }
    }

    @Test func removesByTheRecordWhenTheKeyIsGone() throws {
        try withStore { store, keyring, database in
            let old = try Fixtures.root(minute: 52)
            try store.save(old)
            #expect(store.trust(old, in: [.browsers]).isEmpty)
            keyring.secret.withLock { $0 = nil }

            let report = RemovalReport.remove(from: store)
            #expect(report.outcome == .removed && report.isComplete)
            #expect(
                report.lines == [
                    "Its key: already gone from your keyring, so Reqly went by its record of the places.",
                    "Removed Reqly's certificate.",
                ])
            #expect(try database.holding(old) == .absent)
            #expect(try store.load() == nil)
            // Its folder goes too, once nothing of Reqly's is in it.
            #expect(!FileManager.default.fileExists(atPath: store.file.deletingLastPathComponent().path))
        }
    }

    /// A key kept in the file, with the keyring left alone, isn't missing when the keyring has
    /// nothing: Reqly never asked it.
    @Test func aKeyInTheFileIsntGone() throws {
        try withStore { store, keyring, _ in
            keyring.problem.withLock { $0 = .unavailable("No Secret Service.") }
            let root = try Fixtures.root(minute: 53)
            try store.save(root)
            #expect(store.keyPlace == .file)
            #expect(try store.load()?.certificateDER == root.certificateDER)
        }
    }
}
