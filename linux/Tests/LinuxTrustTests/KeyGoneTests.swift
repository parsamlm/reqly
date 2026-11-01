import CertificateAuthority
import Foundation
import Testing

@testable import LinuxTrust

/// Reqly's key gone from the keyring, as after you reset it: Reqly says so rather than "not set
/// up", the places that still trust the old certificate say so, setting up again takes it out of
/// the databases it was added to, and removing it goes by its record.
@Suite(.enabled(if: Fixtures.certutil != nil, "Needs certutil, from libnss3-tools."))
struct KeyGoneTests {
    /// A home folder with a browsers' database, a keyring in memory, and an empty computer's list.
    func withStore(_ body: (LinuxRootStore, FakeKeyring, NSSDatabase) throws -> Void) throws {
        try withStore { store, keyring, database, _ in try body(store, keyring, database) }
    }

    /// The same, with the computer's list's file, which the helper would change.
    func withStore(_ body: (LinuxRootStore, FakeKeyring, NSSDatabase, URL) throws -> Void) throws {
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
            try body(store, keyring, database, list)
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
                    "Chrome and other browsers built on it: removed.",
                    "Firefox: nothing to remove.",
                    "Command-line tools and most other apps: didn't trust it.",
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
    /// nothing: Reqly never asked it. Once the file has gone, the key is missing, and the
    /// certificate is an old one too.
    @Test func aKeyInTheFileIsntGone() throws {
        try withStore { store, keyring, _ in
            keyring.problem.withLock { $0 = .unavailable("No Secret Service.") }
            let root = try Fixtures.root(minute: 53)
            try store.save(root)
            #expect(store.keyPlace == .file)
            #expect(try store.load()?.certificateDER == root.certificateDER)
            #expect(store.trust(root, in: [.browsers]).isEmpty)
            #expect(store.places(for: nil).first?.status == .trusted)
            #expect(!store.isKeyMissing())

            try FileManager.default.removeItem(at: store.file)
            #expect(try store.load() == nil && !store.isKeyGone())
            #expect(store.isKeyMissing())
            #expect(store.places(for: nil).first?.status == .trustsOldCertificate)
        }
    }

    /// Whether the key is gone asks the keyring only whether it has the item: a keyring that
    /// doesn't answer, or a key kept in the file, isn't gone, and a new setup keeps a new one.
    @Test func saysWhetherTheKeyIsGoneWithoutAskingForIt() throws {
        try withStore { store, keyring, _ in
            #expect(!store.isKeyGone() && !store.isKeyMissing())
            let old = try Fixtures.root(minute: 54)
            try store.save(old)
            #expect(!store.isKeyGone() && !store.isKeyMissing())
            // Locked, and you closed its question: the item is there still.
            keyring.problem.withLock { $0 = .dismissed }
            #expect(!store.isKeyGone() && !store.isKeyMissing())
            keyring.problem.withLock { $0 = nil }
            keyring.secret.withLock { $0 = nil }
            #expect(store.isKeyGone() && store.isKeyMissing())
            for problem in [KeyringProblem.timedOut, .unavailable("No Secret Service.")] {
                keyring.problem.withLock { $0 = problem }
                #expect(!store.isKeyGone() && !store.isKeyMissing(), "\(problem)")
            }
            keyring.problem.withLock { $0 = nil }
            try store.save(try Fixtures.root(minute: 55))
            #expect(!store.isKeyGone() && !store.isKeyMissing())
        }
        try withStore { store, keyring, _ in
            keyring.problem.withLock { $0 = .unavailable("No Secret Service.") }
            try store.save(try Fixtures.root(minute: 56))
            keyring.problem.withLock { $0 = nil }
            #expect(store.keyPlace == .file && !store.isKeyGone() && !store.isKeyMissing())
        }
    }

    /// With the key gone, the places that trust the old certificate say so, rather than "Not
    /// Trusted"; a keyring that's only locked leaves them trusted. A new setup takes the old one
    /// out of the databases.
    @Test func showsWhereTheOldCertificateIsStillTrusted() throws {
        try withStore { store, keyring, database, list in
            let old = try Fixtures.root(minute: 57)
            try store.save(old)
            #expect(store.trust(old, in: [.browsers]).isEmpty)
            // As the helper would have added it to the computer's list.
            try PEM.encode(try old.certificateDER).write(to: list, atomically: true, encoding: .utf8)
            #expect(store.recordedCertificate?.der == (try old.certificateDER))
            #expect(store.recordedCertificate?.name == old.name)

            // The keyring is locked, and you closed its question: the certificate is there still.
            keyring.problem.withLock { $0 = .dismissed }
            #expect(store.places(for: nil).map(\.status) == [.trusted, .notFound, .trusted])

            keyring.problem.withLock { $0 = nil }
            keyring.secret.withLock { $0 = nil }
            let places = store.places(for: nil)
            #expect(places.map(\.status) == [.trustsOldCertificate, .notFound, .trustsOldCertificate])
            #expect(places.map(\.statusName) == ["Old Certificate", "Not Found", "Old Certificate"])
            #expect(places.allSatisfy { $0.status == .notFound || $0.canTrust })

            let new = try Fixtures.root(minute: 58)
            try store.save(new)
            #expect(try database.holding(old) == .absent)
            // The computer's list has only the old one, and no helper to change it.
            let after = store.places(for: new)
            #expect(after.prefix(2).map(\.status) == [.notTrusted, .notFound])
            #expect(after.last?.status == .unavailable(try #require(store.helper.unavailableReason)))
            #expect(!store.isKeyGone())
        }
    }
}
