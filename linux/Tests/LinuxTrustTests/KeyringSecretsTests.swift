import Foundation
import Testing

@testable import LinuxTrust

/// The upstream proxy's password and client certificates' keys, in a keyring in memory or in
/// their file.
@Suite struct KeyringSecretsTests {
    static let password = ["Reqly Upstream Proxy/password": Data("hunter2".utf8)]
    static let key = ["Reqly Client Certificate/1": Data([0, 1, 2, 255])]

    @Test func keepsThemInTheKeyringFirst() throws {
        try Fixtures.withFolder { folder throws in
            let keyring = FakeKeyring()
            let secrets = KeyringSecrets(
                file: folder.appending(path: "reqly/Secrets.json"), isProtected: true, keyring: keyring)
            #expect(try secrets.load() == [:])
            try secrets.save(Self.password)
            #expect(!FileManager.default.fileExists(atPath: secrets.file.path))
            #expect(try secrets.load() == Self.password)
            // The same JSON as Windows' file.
            let kept = try #require(keyring.secret.withLock { $0 })
            #expect(String(decoding: kept, as: UTF8.self) == #"{"Reqly Upstream Proxy/password":"aHVudGVyMg=="}"#)
            // Nothing to keep leaves nothing behind.
            try secrets.save([:])
            #expect(keyring.secret.withLock { $0 } == nil)
            #expect(try secrets.load() == [:])
        }
    }

    @Test(arguments: [KeyringProblem.unavailable("No Secret Service."), .dismissed, .timedOut, .failed("Locked out.")])
    func fallsBackToAFileOnlyYouCanRead(_ problem: KeyringProblem) throws {
        try Fixtures.withFolder { folder throws in
            let secrets = KeyringSecrets(
                file: folder.appending(path: "reqly/Secrets.json"), isProtected: true,
                keyring: FakeKeyring(problem: problem))
            try secrets.save(Self.password)
            #expect(Fixtures.mode(secrets.file) == 0o600)
            #expect(Fixtures.mode(secrets.file.deletingLastPathComponent()) == 0o700)
            #expect(try secrets.load() == Self.password)
        }
    }

    /// Once the secrets are in the file, a keyring that would ask a question isn't asked each
    /// time; an open one takes them, and the file goes.
    @Test func movesThemIntoTheKeyringOnceItIsOpen() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Secrets.json")
            try KeyringSecrets(file: file, isProtected: true, keyring: nil).save(Self.password)
            let locked = FakeKeyring(state: .locked)
            try KeyringSecrets(file: file, isProtected: true, keyring: locked).save(Self.key)
            #expect(locked.saves.withLock { $0 } == 0)
            #expect(try KeyringSecrets(file: file, isProtected: true, keyring: nil).load() == Self.key)

            let open = FakeKeyring(state: .ready)
            let secrets = KeyringSecrets(file: file, isProtected: true, keyring: open)
            #expect(try secrets.load() == Self.key)
            try secrets.save(Self.password)
            #expect(open.saves.withLock { $0 } == 1)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try secrets.load() == Self.password)
        }
    }

    /// When the keyring doesn't give them up, loading says so rather than that there are none,
    /// and saves change nothing until a load works: the caller never had the ones kept, so it
    /// can't say which to keep, or which it removed.
    @Test func changesNothingAfterALoadThatFailed() throws {
        try Fixtures.withFolder { folder throws in
            let keyring = FakeKeyring()
            let file = folder.appending(path: "Secrets.json")
            try KeyringSecrets(file: file, isProtected: true, keyring: keyring).save(Self.key)

            let secrets = KeyringSecrets(file: file, isProtected: true, keyring: keyring)
            keyring.problem.withLock { $0 = .dismissed }
            #expect(throws: KeyringSecrets.Problem.self) { try secrets.load() }
            keyring.problem.withLock { $0 = nil }
            // You removed a client certificate the session showed as missing, or cleared the
            // password: neither takes the place of what's kept.
            #expect(throws: KeyringSecrets.Problem.self) { try secrets.save(Self.password) }
            #expect(throws: KeyringSecrets.Problem.self) { try secrets.save([:]) }
            #expect(keyring.secret.withLock { $0 } == (try KeyringSecrets.encode(Self.key)))
            #expect(!FileManager.default.fileExists(atPath: file.path))

            // Once a load works, the caller has them all, and its saves count, removals too.
            #expect(try secrets.load() == Self.key)
            try secrets.save(Self.password)
            #expect(try secrets.load() == Self.password)
        }
    }

    /// Nothing left to keep while the keyring is locked, or doesn't answer: the old item can't go
    /// without a question, so an empty file hides it until a save with the keyring open.
    @Test func hidesWhatItCouldNotRemove() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Secrets.json")
            let open = FakeKeyring()
            try KeyringSecrets(file: file, isProtected: true, keyring: open).save(Self.password)

            let locked = LockedKeyring(open)
            let secrets = KeyringSecrets(file: file, isProtected: true, keyring: locked)
            #expect(try secrets.load() == Self.password)
            try secrets.save([:])
            #expect(open.secret.withLock { $0 } != nil)
            #expect(Fixtures.mode(file) == 0o600)
            #expect(try KeyringSecrets(file: file, isProtected: true, keyring: locked).load() == [:])

            // A keyring that's open but won't remove it, as when you close its question.
            open.problem.withLock { $0 = .dismissed }
            try KeyringSecrets(file: file, isProtected: true, keyring: open).save([:])
            #expect(FileManager.default.fileExists(atPath: file.path))
            open.problem.withLock { $0 = nil }

            let reopened = KeyringSecrets(file: file, isProtected: true, keyring: open)
            #expect(try reopened.load() == [:])
            try reopened.save([:])
            #expect(open.secret.withLock { $0 } == nil)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func refusesAFileOthersCanRead() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Secrets.json")
            let secrets = KeyringSecrets(file: file, isProtected: true, keyring: nil)
            try secrets.save(Self.password)
            chmod(file.path, 0o644)
            #expect {
                try secrets.load()
            } throws: { error in
                (error as? KeyringSecrets.Problem)?.message.contains("the passwords and keys it keeps") == true
            }
        }
    }

    /// A test run's file is plain, and never asks the keyring.
    @Test func keepsATestRunsInAPlainFile() throws {
        try Fixtures.withFolder { folder throws in
            let keyring = FakeKeyring()
            let secrets = KeyringSecrets(
                file: folder.appending(path: "Secrets.json"), isProtected: false, keyring: keyring)
            try secrets.save(Self.password)
            #expect(try secrets.load() == Self.password)
            #expect(keyring.saves.withLock { $0 } == 0)
            #expect(
                try String(contentsOf: secrets.file, encoding: .utf8)
                    == #"{"Reqly Upstream Proxy/password":"aHVudGVyMg=="}"#)
        }
    }
}

/// A keyring that's locked: it reads and says so, but never asks to remove or save, as
/// KeyringSecrets never asks it to.
final class LockedKeyring: Keyring {
    let keyring: FakeKeyring

    init(_ keyring: FakeKeyring) {
        self.keyring = keyring
    }

    func state() -> KeyringState { .locked }
    func load() throws(KeyringProblem) -> Data? { try keyring.load() }

    func save(_ secret: Data) throws(KeyringProblem) {
        Issue.record("A locked keyring was asked to save.")
        throw .dismissed
    }

    func remove() throws(KeyringProblem) {
        Issue.record("A locked keyring was asked to remove.")
        throw .dismissed
    }
}
