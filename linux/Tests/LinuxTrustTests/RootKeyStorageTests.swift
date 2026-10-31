import CertificateAuthority
import Foundation
import Synchronization
import Testing

@testable import LinuxTrust

/// A keyring in memory, which answers as it's told to.
final class FakeKeyring: Keyring {
    let secret = Mutex<Data?>(nil)
    let problem = Mutex<KeyringProblem?>(nil)
    let currentState: KeyringState
    let saves = Mutex(0)

    init(state: KeyringState = .ready, problem: KeyringProblem? = nil) {
        currentState = state
        self.problem.withLock { $0 = problem }
    }

    func state() -> KeyringState { currentState }

    func load() throws(KeyringProblem) -> Data? {
        if let problem = problem.withLock({ $0 }) { throw problem }
        return secret.withLock { $0 }
    }

    func save(_ secret: Data) throws(KeyringProblem) {
        if let problem = problem.withLock({ $0 }) { throw problem }
        saves.withLock { $0 += 1 }
        self.secret.withLock { $0 = secret }
    }

    func remove() throws(KeyringProblem) {
        if let problem = problem.withLock({ $0 }) { throw problem }
        secret.withLock { $0 = nil }
    }
}

@Suite struct RootKeyStorageTests {
    @Test func keepsTheKeyInTheKeyringFirst() throws {
        try Fixtures.withFolder { folder throws in
            let keyring = FakeKeyring()
            let storage = RootKeyStorage(file: folder.appending(path: "Certificate.dat"), keyring: keyring)
            #expect(try storage.save(Data("key".utf8)) == RootKeyStorage.Saved(place: .keyring))
            #expect(!FileManager.default.fileExists(atPath: storage.file.path))
            #expect(try storage.load(from: .keyring) == Data("key".utf8))
            #expect(try storage.load(from: nil) == Data("key".utf8))
            try storage.remove(from: .keyring)
            #expect(keyring.secret.withLock { $0 } == nil)
        }
    }

    @Test(arguments: [
        KeyringProblem.unavailable("No Secret Service."), .dismissed, .timedOut, .failed("Locked out."),
    ])
    func fallsBackToTheFile(_ problem: KeyringProblem) throws {
        try Fixtures.withFolder { folder throws in
            let storage = RootKeyStorage(
                file: folder.appending(path: "reqly/Certificate.dat"), keyring: FakeKeyring(problem: problem))
            #expect(try storage.save(Data("key".utf8)) == RootKeyStorage.Saved(place: .file, keyringProblem: problem))
            #expect(Fixtures.mode(storage.file) == 0o600)
            #expect(Fixtures.mode(storage.file.deletingLastPathComponent()) == 0o700)
            #expect(try storage.load(from: .file) == Data("key".utf8))
        }
    }

    @Test func movesAKeyFromTheFileIntoTheKeyring() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Certificate.dat")
            try RootKeyStorage(file: file, keyring: nil).save(Data("key".utf8))
            #expect(FileManager.default.fileExists(atPath: file.path))
            let storage = RootKeyStorage(file: file, keyring: FakeKeyring())
            #expect(try storage.save(Data("key".utf8)).place == .keyring)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    /// A keyring that doesn't answer mustn't look like one with no key, or a new certificate
    /// would take the place of the one it holds.
    @Test func saysSoWhenTheKeyringDoesNotAnswer() throws {
        try Fixtures.withFolder { folder throws in
            let storage = RootKeyStorage(
                file: folder.appending(path: "Certificate.dat"), keyring: FakeKeyring(problem: .timedOut))
            #expect(throws: KeyringProblem.timedOut) { try storage.load(from: .keyring) }
            #expect(throws: KeyringProblem.timedOut) { try storage.load(from: nil) }
            // With no Secret Service at all, there's no key in one.
            let none = RootKeyStorage(
                file: folder.appending(path: "Certificate.dat"), keyring: FakeKeyring(problem: .unavailable("None.")))
            #expect(try none.load(from: nil) == nil)
        }
    }

    @Test func refusesAKeyFileOthersCanRead() throws {
        try Fixtures.withFolder { folder throws in
            let storage = RootKeyStorage(file: folder.appending(path: "Certificate.dat"), keyring: nil)
            try storage.save(Data("key".utf8))
            chmod(storage.file.path, 0o644)
            #expect(throws: TrustFailure.self) { try storage.load(from: .file) }
        }
    }

    @Test func tellsTheAppAboutANewKeyringBeforeTheFirstSave() {
        let storage = RootKeyStorage(file: URL(filePath: "/nowhere"), keyring: FakeKeyring(state: .needsNewKeyring))
        #expect(storage.keyringState() == .needsNewKeyring)
        #expect(RootKeyStorage(file: URL(filePath: "/nowhere"), keyring: nil).keyringState() != .ready)
    }

    /// The root store's key, as RootIdentity serializes it, comes back whole.
    @Test func keepsARootWhole() throws {
        try Fixtures.withFolder { folder throws in
            let root = try Fixtures.root()
            let storage = RootKeyStorage(file: folder.appending(path: "Certificate.dat"), keyring: nil)
            try storage.save(try root.serialized())
            let loaded = try RootIdentity(serialized: try #require(try storage.load(from: .file)))
            #expect(try loaded.certificateDER == root.certificateDER)
            #expect(loaded.key.rawRepresentation == root.key.rawRepresentation)
        }
    }
}
