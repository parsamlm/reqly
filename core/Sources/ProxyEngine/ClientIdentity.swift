import Foundation
import NIOSSL
import ReqlyModel
import X509

/// A certificate and its private key, which Reqly presents to servers that ask apps to identify
/// themselves, for the hosts it's meant for.
public struct ClientIdentity: Sendable {
    /// The hosts to present it to, such as `api.bank.dev` or `*.bank.dev`.
    public var hosts: [HostPattern]
    let chain: [NIOSSLCertificate]
    let key: NIOSSLPrivateKey

    /// Who the certificate names: its subject's common name, or the whole subject.
    public let name: String
    /// Who issued it.
    public let issuer: String
    public let expires: Date?

    public enum Problem: Error, Equatable {
        /// The file is locked, and the password didn't open it.
        case wrongPassword
        case noCertificate
        case noPrivateKey
        /// The private key doesn't belong to the certificate.
        case keyDoesNotMatch
        /// The file isn't a certificate Reqly can read.
        case unreadable

        public var message: String {
            switch self {
            case .wrongPassword: "The password doesn't open this file."
            case .noCertificate: "The file has no certificate in it."
            case .noPrivateKey:
                "The file has no private key. Choose a .p12 file, or a PEM file with both the certificate and its key."
            case .keyDoesNotMatch: "The private key in the file doesn't belong to its certificate."
            case .unreadable: "Reqly can't read this file as a certificate. Choose a .p12, .pfx or PEM file."
            }
        }
    }

    /// From a PKCS #12 file, such as a `.p12` or `.pfx` that Keychain Access exports, unlocked
    /// with its password.
    public init(pkcs12: [UInt8], password: String, hosts: [HostPattern]) throws(Problem) {
        let bundle: NIOSSLPKCS12Bundle
        do {
            bundle = try NIOSSLPKCS12Bundle(buffer: pkcs12, passphrase: Array(password.utf8))
        } catch {
            // BoringSSL can't tell a wrong password from a damaged file; a file that isn't
            // PKCS #12 at all fails before it gets to the password.
            throw pkcs12.first == 0x30 ? .wrongPassword : .unreadable
        }
        try self.init(chain: bundle.certificateChain, key: bundle.privateKey, hosts: hosts)
    }

    /// From PEM text with the certificate, the certificates that issued it if any, and its
    /// private key, which may be locked with `password`.
    public init(pem: String, password: String?, hosts: [HostPattern]) throws(Problem) {
        let bytes = Array(pem.utf8)
        guard let chain = try? NIOSSLCertificate.fromPEMBytes(bytes), !chain.isEmpty else {
            throw pem.contains("-----BEGIN") ? .noCertificate : .unreadable
        }
        guard pem.contains("PRIVATE KEY-----") else { throw .noPrivateKey }
        let key: NIOSSLPrivateKey
        do {
            if let password {
                key = try NIOSSLPrivateKey(bytes: bytes, format: .pem) { setPassword in
                    setPassword(password.utf8)
                }
            } else {
                key = try NIOSSLPrivateKey(bytes: bytes, format: .pem)
            }
        } catch {
            throw pem.contains("ENCRYPTED") ? .wrongPassword : .noPrivateKey
        }
        try self.init(chain: chain, key: key, hosts: hosts)
    }

    /// From what ``serialized`` returned.
    public init(serialized: Data, hosts: [HostPattern]) throws(Problem) {
        guard
            let list = try? PropertyListSerialization.propertyList(from: serialized, format: nil) as? [String: Any],
            let certificates = list["chain"] as? [Data], let keyData = list["key"] as? Data,
            let chain = try? certificates.map({ try NIOSSLCertificate(bytes: [UInt8]($0), format: .der) }),
            let key = try? NIOSSLPrivateKey(bytes: [UInt8](keyData), format: .der)
        else { throw .unreadable }
        try self.init(chain: chain, key: key, hosts: hosts)
    }

    private init(chain: [NIOSSLCertificate], key: NIOSSLPrivateKey, hosts: [HostPattern]) throws(Problem) {
        guard let leaf = chain.first else { throw .noCertificate }
        // TLS checks that the key belongs to the certificate when it sets them up together.
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateChain = chain.map { .certificate($0) }
        configuration.privateKey = .privateKey(key)
        guard (try? NIOSSLContext(configuration: configuration)) != nil else { throw .keyDoesNotMatch }
        self.chain = chain
        self.key = key
        self.hosts = hosts
        let details = (try? leaf.toDERBytes()).flatMap { try? Certificate(derEncoded: $0) }
        name = details.map { Self.describe($0.subject) } ?? "Certificate"
        issuer = details.map { Self.describe($0.issuer) } ?? ""
        expires = details?.notValidAfter
    }

    /// The certificate chain and the private key, in a property list, for keeping in the Keychain.
    public var serialized: Data {
        get throws {
            let list: [String: Any] = [
                "chain": try chain.map { Data(try $0.toDERBytes()) },
                "key": Data(try key.derBytes),
            ]
            return try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        }
    }

    /// A name's common name, such as "Weatherly Staging", or the whole name without one.
    private static func describe(_ name: DistinguishedName) -> String {
        for relative in name {
            for attribute in relative where attribute.type == .RDNAttributeType.commonName {
                return String(describing: attribute.value)
            }
        }
        let whole = String(describing: name)
        return whole.isEmpty ? "Unnamed" : whole
    }
}
