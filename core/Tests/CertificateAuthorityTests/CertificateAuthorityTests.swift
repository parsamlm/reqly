import Foundation
import SwiftASN1
import Testing
import X509

@testable import CertificateAuthority

#if canImport(Security)
    import Security
#endif

/// These tests keep every certificate in memory. None of them touch the keychain or trust settings.
@Suite struct CertificateAuthorityTests {
    let root: RootIdentity
    let authority: CertificateAuthority

    init() throws {
        root = try RootIdentity.create(
            now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!)
        authority = try CertificateAuthority(root: root)
    }

    @Test func rootIsASelfSignedAuthorityWithTheCreationTimeInItsName() throws {
        #expect(root.name == "Reqly CA 2026-09-21 14:13")
        #expect(root.certificate.issuer == root.certificate.subject)
        #expect(try root.certificate.extensions.basicConstraints == .isCertificateAuthority(maxPathLength: 0))
        #expect(root.certificate.publicKey.isValidSignature(root.certificate.signature, for: root.certificate))
        let lifetime = root.certificate.notValidAfter.timeIntervalSince(root.certificate.notValidBefore)
        #expect(lifetime < 2 * 366 * 86_400)
    }

    @Test func issuesHostCertificatesThatMacOSAccepts() throws {
        let identity = try authority.identity(for: "api.weatherly.dev")
        #expect(identity.certificateChain.count == 2)
        #if canImport(Security)
            #expect(try evaluate(identity, host: "api.weatherly.dev"))
            // The certificate is for this host only.
            #expect(try !evaluate(identity, host: "images.weatherly.dev"))
        #endif
    }

    @Test func hostCertificatesFollowApplesRules() throws {
        let identity = try authority.identity(for: "api.weatherly.dev")
        let certificate = try Certificate(derEncoded: identity.certificateChain[0])
        #expect(
            try certificate.extensions.subjectAlternativeNames
                == SubjectAlternativeNames([.dnsName("api.weatherly.dev")]))
        #expect(try certificate.extensions.extendedKeyUsage == ExtendedKeyUsage([.serverAuth]))
        #expect(try certificate.extensions.basicConstraints == .notCertificateAuthority)
        // Apple rejects TLS certificates valid for more than 825 days; Reqly issues one-year certificates.
        #expect(certificate.notValidAfter.timeIntervalSince(certificate.notValidBefore) <= 367 * 86_400)
        #expect(root.certificate.publicKey.isValidSignature(certificate.signature, for: certificate))
    }

    @Test func coversIPAddresses() throws {
        let identity = try authority.identity(for: "127.0.0.1")
        let certificate = try Certificate(derEncoded: identity.certificateChain[0])
        let address = ASN1OctetString(contentBytes: [127, 0, 0, 1])
        #expect(try certificate.extensions.subjectAlternativeNames == SubjectAlternativeNames([.ipAddress(address)]))
        #if canImport(Security)
            #expect(try evaluate(identity, host: "127.0.0.1"))
        #endif
    }

    @Test func issuesEachHostOnce() throws {
        let first = try authority.identity(for: "API.weatherly.dev")
        let second = try authority.identity(for: "api.weatherly.dev")
        #expect(first.certificateChain == second.certificateChain)
    }

    func identityHost(_ identity: ServerIdentity) -> String? {
        guard let certificate = try? Certificate(derEncoded: identity.certificateChain[0]),
            let names = try? certificate.extensions.subjectAlternativeNames
        else { return nil }
        for name in names {
            if case .dnsName(let host) = name { return host }
            if case .ipAddress = name { return "127.0.0.1" }
        }
        return nil
    }

    #if canImport(Security)
        /// Checks a host certificate the way macOS checks a server, with Reqly's root as the only
        /// trusted root, for this check alone.
        func evaluate(_ identity: ServerIdentity, host: String) throws -> Bool {
            let certificates = identity.certificateChain.map { SecCertificateCreateWithData(nil, Data($0) as CFData)! }
            var trust: SecTrust?
            #expect(
                SecTrustCreateWithCertificates(
                    certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
                    == errSecSuccess)
            let anchor = SecCertificateCreateWithData(nil, Data(try root.certificateDER) as CFData)!
            SecTrustSetAnchorCertificates(trust!, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust!, true)
            var error: CFError?
            let trusted = SecTrustEvaluateWithError(trust!, &error)
            if !trusted, host == identityHost(identity) {
                Issue.record("macOS rejected the certificate: \(error.map { String(describing: $0) } ?? "no reason")")
            }
            return trusted
        }
    #endif
}
