import Crypto
import Foundation
import X509

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

extension RootIdentity {
    /// The root as bytes, for a store to keep: a binary property list of its certificate, in DER,
    /// and its private key. The Mac's keychain and Windows' store keep it in this same form.
    public func serialized() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["certificate": Data(try certificateDER), "key": key.rawRepresentation],
            format: .binary,
            options: 0
        )
    }

    /// The root from what ``serialized()`` made.
    public init(serialized data: Data) throws {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data],
            let certificate = list["certificate"], let key = list["key"]
        else { throw CertificateStoreError.unreadable }
        self.init(
            certificate: try Certificate(derEncoded: [UInt8](certificate)),
            key: try P256.Signing.PrivateKey(rawRepresentation: key)
        )
    }
}
