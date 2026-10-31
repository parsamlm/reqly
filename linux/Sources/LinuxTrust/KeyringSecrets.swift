import Foundation
import ReqlyModel
import Synchronization

/// Secrets, such as the upstream proxy's password and client certificates' private keys, kept
/// together, by name: in your keyring, as one item, "Reqly Secrets", when it can, and otherwise in
/// a file only you can read (0600, in a folder only you can open), as Reqly's certificate is. The
/// Mac keeps them in your Keychain, and Windows in a file it encrypts for you. A test run's are in
/// a plain file instead.
///
/// Both places hold the same JSON as Windows' file: each secret in base64, by name. Keyring calls
/// run on threads of their own with a time limit, and may wait for you to unlock your keyring, so
/// call these off the main thread.
public final class KeyringSecrets: Sendable {
    /// The file, used when the keyring isn't, or for a test run.
    public let file: URL
    /// Whether only you can read the secrets, in your keyring or a private file. A test run's
    /// file is plain.
    public let isProtected: Bool
    /// The keyring, or `nil` to use only the file.
    public let keyring: (any Keyring)?

    /// Whether the latest load failed, so the caller never had what's kept and a save would
    /// lose it.
    private let lastLoadFailed = Mutex(false)

    public init(
        file: URL, isProtected: Bool, keyring: (any Keyring)? = SecretServiceKeyring(item: .secrets)
    ) {
        self.file = file
        self.isProtected = isProtected
        self.keyring = keyring
    }

    /// Why the secrets couldn't be kept, or read back.
    public struct Problem: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Each secret by its name, such as `Reqly Upstream Proxy/password`, or none if there are none
    /// yet. A file means the keyring couldn't take them when they were last saved, so it's read
    /// first. It throws when the keyring doesn't answer, or you close its question, rather than
    /// say there are none.
    public func load() throws -> [String: Data] {
        guard isProtected else {
            guard let stored = try? Data(contentsOf: file) else { return [:] }
            return try Self.decode(stored)
        }
        do {
            let kept = try loadProtected()
            lastLoadFailed.withLock { $0 = false }
            return kept
        } catch {
            lastLoadFailed.withLock { $0 = true }
            throw error
        }
    }

    /// Keeps `secrets` in place of the ones kept before: in your keyring when it's open, or when
    /// the file isn't in use already, and otherwise in the file. A file left from before goes once
    /// the keyring has them. After a load that failed, it changes nothing until a load works,
    /// since the caller never had the ones kept and can't say which to keep.
    public func save(_ secrets: [String: Data]) throws {
        guard isProtected else {
            try FileReplacement.write(Self.encode(secrets), to: file)
            return
        }
        guard !lastLoadFailed.withLock({ $0 }) else {
            throw Problem(
                message: """
                    Reqly couldn't read the passwords and keys it keeps, so it didn't change them. \
                    Unlock your keyring, then open Settings › Connections again.
                    """)
        }
        let data = try Self.encode(secrets)
        guard let keyring else {
            if secrets.isEmpty {
                try Self.removeFile(file)
            } else {
                try writeFile(data)
            }
            return
        }
        let keyringState = keyring.state()
        if secrets.isEmpty {
            // Nothing to keep needs no new item, and no question. An item that can't go now stays
            // hidden behind an empty file, which is read first, until a save with the keyring open.
            if keyringState == .ready, (try? keyring.remove()) != nil {
                try Self.removeFile(file)
            } else {
                try writeFile(data)
            }
            return
        }
        // Once the secrets are in the file, they stay there until the keyring is open, so a
        // keyring you didn't make or unlock doesn't ask each time.
        let hasFile = FileManager.default.fileExists(atPath: file.path)
        if keyringState == .ready || (!hasFile && Self.canAsk(keyringState)) {
            do {
                try keyring.save(data)
                try Self.removeFile(file)
                return
            } catch {
                // The file, below.
            }
        }
        try writeFile(data)
    }

    // MARK: -

    private func loadProtected() throws -> [String: Data] {
        let stored: Data?
        do {
            stored = try PrivateFile.readOwn(file, holding: .secrets)
        } catch {
            throw Problem(message: error.message)
        }
        if let stored { return try Self.decode(stored) }
        guard let keyring else { return [:] }
        let found: Data?
        do {
            found = try keyring.load()
        } catch {
            // No keyring to ask means no secrets in one.
            if case .unavailable = keyring.state() { return [:] }
            switch error {
            case .dismissed:
                throw Problem(message: "Your keyring stayed locked, so Reqly couldn't read them.")
            case .timedOut:
                throw Problem(message: "Your keyring didn't answer.")
            case .unavailable(let reason), .failed(let reason):
                throw Problem(message: "Your keyring couldn't give them to Reqly. \(reason)")
            }
        }
        return try found.map(Self.decode) ?? [:]
    }

    private func writeFile(_ data: Data) throws {
        do {
            try PrivateFile.write(data, to: file, mode: 0o600)
        } catch {
            throw Problem(message: error.message)
        }
    }

    /// Whether the keyring can take a save, perhaps after a question.
    private static func canAsk(_ state: KeyringState) -> Bool {
        if case .unavailable = state { false } else { true }
    }

    private static func removeFile(_ file: URL) throws {
        do {
            try PrivateFile.remove(file)
        } catch {
            throw Problem(message: error.message)
        }
    }

    static func decode(_ data: Data) throws -> [String: Data] {
        do {
            return try JSONDecoder().decode([String: String].self, from: data).compactMapValues {
                Data(base64Encoded: $0)
            }
        } catch {
            throw Problem(message: "They aren't kept in a way Reqly can read.")
        }
    }

    static func encode(_ secrets: [String: Data]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(secrets.mapValues { $0.base64EncodedString() })
    }
}
