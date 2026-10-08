import Crypto
import Foundation
import SwiftASN1
import Synchronization
import X509

/// Reqly's root certificate and its private key.
public struct RootIdentity: Sendable {
    public let certificate: Certificate
    public let key: P256.Signing.PrivateKey

    public init(certificate: Certificate, key: P256.Signing.PrivateKey) {
        self.certificate = certificate
        self.key = key
    }

    /// A new root: an ECDSA P-256 key and a self-signed CA certificate named "Reqly CA" and
    /// the minute it was made, valid for two years. The time tells a device's copy apart from
    /// a newer one, since a phone keeps the certificate it was given.
    public static func create(now: Date = Date(), timeZone: TimeZone = .current) throws -> RootIdentity {
        let key = P256.Signing.PrivateKey()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let made = formatter.string(from: now)
        let name = try DistinguishedName {
            CommonName("Reqly CA \(made)")
            OrganizationName("Reqly")
        }
        let publicKey = Certificate.PublicKey(key.publicKey)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(2 * 365 * 86_400),
            issuer: name,
            subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: publicKey)
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        return RootIdentity(certificate: certificate, key: key)
    }

    public var certificateDER: [UInt8] {
        get throws {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            return serializer.serializedBytes
        }
    }

    /// When the root was made. Its validity starts a day earlier, for clocks that are behind.
    public var created: Date {
        certificate.notValidBefore.addingTimeInterval(86_400)
    }

    /// Such as "Reqly CA 2026-10-04 00:10", or "Reqly CA 2026-09-30" for one an earlier Reqly made.
    public var name: String {
        for relativeName in certificate.subject {
            for attribute in relativeName where attribute.type == .RDNAttributeType.commonName {
                return attribute.value.description
            }
        }
        return "Reqly CA"
    }
}

/// A host certificate and the key that goes with it, ready for a TLS server.
public struct ServerIdentity: Sendable {
    /// The host certificate first, then Reqly's root, in DER.
    public let certificateChain: [[UInt8]]
    public let privateKeyPEM: String
}

/// Issues the certificates Reqly presents to apps for the hosts it decrypts. Each host gets its
/// certificate once per launch; all of them share one key, made fresh at each launch.
public final class CertificateAuthority: Sendable {
    public let root: RootIdentity
    private let rootDER: [UInt8]
    private let hostKey = P256.Signing.PrivateKey()
    private let issued = Mutex<[String: ServerIdentity]>([:])

    public init(root: RootIdentity) throws {
        self.root = root
        self.rootDER = try root.certificateDER
    }

    public func identity(for host: String) throws -> ServerIdentity {
        let host = host.lowercased()
        if let identity = issued.withLock({ $0[host] }) {
            return identity
        }
        let identity = try issue(for: host)
        issued.withLock { issued in
            if issued.count > 5_000 { issued.removeAll() }
            issued[host] = identity
        }
        return identity
    }

    /// A certificate that meets Apple's requirements for TLS servers: the host in the subject
    /// alternative name, server authentication as its only purpose, and a validity of one year.
    private func issue(for host: String) throws -> ServerIdentity {
        let now = Date()
        let rootKeyIdentifier = SubjectKeyIdentifier(hash: root.certificate.publicKey).keyIdentifier
        let name: GeneralName =
            if let address = Self.ipAddressBytes(host) {
                .ipAddress(ASN1OctetString(contentBytes: ArraySlice(address)))
            } else {
                .dnsName(host)
            }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(hostKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: min(now.addingTimeInterval(365 * 86_400), root.certificate.notValidAfter),
            issuer: root.certificate.subject,
            // Common names are limited to 64 characters; clients read the host from the alternative name.
            subject: try DistinguishedName { CommonName(String(host.prefix(64))) },
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([name])
                AuthorityKeyIdentifier(keyIdentifier: rootKeyIdentifier)
            },
            issuerPrivateKey: Certificate.PrivateKey(root.key)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return ServerIdentity(
            certificateChain: [serializer.serializedBytes, rootDER], privateKeyPEM: hostKey.pemRepresentation)
    }

    /// The four or sixteen bytes of an IP address, or `nil` for a host name.
    static func ipAddressBytes(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }
}
