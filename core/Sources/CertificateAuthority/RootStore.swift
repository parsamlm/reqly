import Foundation

/// Where Reqly keeps its root, and asks the system to trust it: the login keychain on the Mac,
/// which the Keychain module reaches.
///
/// Trusting and removing may ask for the user's password and wait for them, so call them off
/// the main thread.
public protocol RootStore: Sendable {
    /// The root saved earlier, or `nil` if there isn't one yet.
    func load() throws -> RootIdentity?
    func save(_ root: RootIdentity) throws
    /// Whether the system trusts the root for TLS.
    func isTrusted(_ root: RootIdentity) -> Bool
    func trust(_ root: RootIdentity) throws
    /// Removes the root, its key, and the system's trust in it.
    func remove(_ root: RootIdentity) throws
}

public enum CertificateStoreError: Error, Equatable {
    /// The user closed the password dialog.
    case cancelled
    case failed(String)
    case unreadable
}
