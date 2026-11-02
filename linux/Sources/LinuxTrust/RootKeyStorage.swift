import Foundation

/// Where Reqly's certificate and its key are kept.
public enum KeyPlace: String, Codable, Sendable {
    /// Your keyring, through the Secret Service, as the Mac keeps them in your Keychain.
    case keyring
    /// A file only you can read, `Certificate.dat`, when there's no keyring to use.
    case file
}

/// Keeps Reqly's certificate and its key, as `RootIdentity.serialized()` makes them: in your
/// keyring when it can, and otherwise in a file only you can read (0600, in a folder only you can
/// open). Keyring calls run on threads of their own with a time limit; call these off the main
/// thread.
public struct RootKeyStorage: Sendable {
    /// The file, used when the keyring isn't.
    public let file: URL
    /// The keyring, or `nil` to use only the file.
    public let keyring: (any Keyring)?

    public init(file: URL, keyring: (any Keyring)? = SecretServiceKeyring()) {
        self.file = file
        self.keyring = keyring
    }

    /// Where a save went, and why not in the keyring when it went to the file.
    public struct Saved: Sendable, Equatable {
        public var place: KeyPlace
        public var keyringProblem: KeyringProblem?
    }

    /// What saving in the keyring involves, for the app to explain before the first save, such as
    /// a question about a new keyring's password.
    public func keyringState() -> KeyringState {
        keyring?.state() ?? .unavailable("Reqly isn't using a keyring.")
    }

    /// Saves in the keyring, and in the file when there's no keyring, or you close its question,
    /// or it doesn't answer. A file left from before goes once the keyring has the key.
    @discardableResult
    public func save(_ serialized: Data) throws -> Saved {
        var problem: KeyringProblem?
        if let keyring {
            do {
                try keyring.save(serialized)
                try? PrivateFile.remove(file)
                return Saved(place: .keyring)
            } catch {
                problem = error
            }
        }
        try PrivateFile.write(serialized, to: file, mode: 0o600)
        return Saved(place: .file, keyringProblem: problem)
    }

    /// What was saved in `place`, or wherever it's found when the place isn't known: the file,
    /// then the keyring. It throws rather than say there's none when the keyring doesn't answer,
    /// or you close the question that would unlock it, so a new certificate never takes the
    /// place of one it couldn't read.
    public func load(from place: KeyPlace?) throws -> Data? {
        switch place {
        case .file:
            return try PrivateFile.readOwn(file)
        case .keyring:
            guard let keyring else { return nil }
            return try keyring.load()
        case nil:
            if let data = try PrivateFile.readOwn(file) { return data }
            do {
                return try keyring?.load()
            } catch .timedOut {
                throw KeyringProblem.timedOut
            } catch .dismissed {
                throw KeyringProblem.dismissed
            } catch {
                // No keyring to ask means no certificate in one.
                return nil
            }
        }
    }

    /// Removes the key from the file and the keyring. It throws when the keyring doesn't remove
    /// it and `place` says it's there. Otherwise it only tidies an open keyring, so it never asks
    /// for a password to remove what may not be there.
    public func remove(from place: KeyPlace?) throws {
        try PrivateFile.remove(file)
        guard let keyring else { return }
        if place == .keyring {
            try keyring.remove()
        } else if keyring.state() == .ready {
            try? keyring.remove()
        }
    }
}
