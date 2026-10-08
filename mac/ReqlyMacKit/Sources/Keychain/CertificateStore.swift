import CertificateAuthority
import Crypto
import Foundation
import Security
import X509

/// Keeps Reqly's root certificate and key in the user's login keychain, and asks macOS to trust
/// the certificate for this user only, and only for TLS.
///
/// Trusting and removing ask for the user's password, and block until they answer, so call
/// them off the main thread.
public struct CertificateStore: RootStore {
    /// The keychain item that holds the certificate and its private key.
    let service: String
    let account = "root"

    public static let standard = CertificateStore(service: "Reqly Certificate Authority")

    public init(service: String) {
        self.service = service
    }

    public func load() throws -> RootIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
        return try Self.root(from: data)
    }

    /// Saves the root, and adds its certificate to the keychain, where macOS looks for it when it
    /// checks the certificates Reqly issues. Keychain Access shows it under its name.
    public func save(_ root: RootIdentity) throws {
        let data = try Self.data(for: root)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Reqly Certificate Authority",
            kSecAttrDescription as String: "The key Reqly uses to decrypt HTTPS traffic",
            kSecValueData as String: data,
        ]
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Self.error(status) }

        status = SecItemAdd(
            [kSecValueRef as String: try Self.secCertificate(root), kSecAttrLabel as String: root.name] as CFDictionary,
            nil
        )
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw Self.error(status) }
    }

    /// Whether macOS trusts the root for TLS for this user.
    public func isTrusted(_ root: RootIdentity) -> Bool {
        guard let certificate = try? Self.secCertificate(root) else { return false }
        var settings: CFArray?
        guard SecTrustSettingsCopyTrustSettings(certificate, .user, &settings) == errSecSuccess else { return false }
        let entries = settings as? [[String: Any]] ?? []
        // No entries means "trusted for everything". A missing result means "trust as root".
        return entries.isEmpty
            || entries.contains {
                ($0[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value
                    ?? SecTrustSettingsResult.trustRoot.rawValue
                    == SecTrustSettingsResult.trustRoot.rawValue
            }
    }

    /// Asks macOS to trust the root for TLS, for this user only. macOS asks for the user's password.
    public func trust(_ root: RootIdentity) throws {
        let settings: [[String: Any]] = [
            [
                kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
                kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue),
            ]
        ]
        let status = SecTrustSettingsSetTrustSettings(try Self.secCertificate(root), .user, settings as CFArray)
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    /// Removes the trust setting, the certificate and the key. macOS asks for the user's password
    /// if the certificate is trusted.
    public func remove(_ root: RootIdentity) throws {
        let certificate = try Self.secCertificate(root)
        let status = SecTrustSettingsRemoveTrustSettings(certificate, .user)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
        // Deleting needs the keychain's own copy: a certificate made from the same bytes doesn't
        // match it. Earlier roots that an older Reqly left behind go too.
        let der = Data(try root.certificateDER)
        for item in Self.reqlyCertificates() {
            if SecCertificateCopyData(item) as Data != der {
                _ = SecTrustSettingsRemoveTrustSettings(item, .user)
            }
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: item] as CFDictionary)
        }
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary
        )
    }

    /// Reqly's root certificates in the keychains: self-signed, and named "Reqly CA" and the
    /// time they were made.
    static func reqlyCertificates() -> [SecCertificate] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchSubjectContains as String: "Reqly CA",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [SecCertificate]
        else { return [] }
        return items.filter { item in
            let isSelfSigned =
                SecCertificateCopyNormalizedIssuerSequence(item) as Data?
                == SecCertificateCopyNormalizedSubjectSequence(item) as Data?
            return isSelfSigned && (SecCertificateCopySubjectSummary(item) as String?)?.hasPrefix("Reqly CA") == true
        }
    }

    /// The root as the keychain item keeps it: a property list of its certificate, in DER, and its
    /// private key.
    public static func data(for root: RootIdentity) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["certificate": Data(try root.certificateDER), "key": root.key.rawRepresentation],
            format: .binary,
            options: 0
        )
    }

    /// The root from what ``data(for:)`` made.
    public static func root(from data: Data) throws -> RootIdentity {
        guard let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data],
            let certificate = list["certificate"], let key = list["key"]
        else { throw CertificateStoreError.unreadable }
        return RootIdentity(
            certificate: try Certificate(derEncoded: [UInt8](certificate)),
            key: try P256.Signing.PrivateKey(rawRepresentation: key)
        )
    }

    static func secCertificate(_ root: RootIdentity) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, Data(try root.certificateDER) as CFData) else {
            throw CertificateStoreError.unreadable
        }
        return certificate
    }

    static func error(_ status: OSStatus) -> CertificateStoreError {
        if status == errAuthorizationCanceled || status == errSecUserCanceled { return .cancelled }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        return .failed(message)
    }
}
