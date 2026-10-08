import CertificateAuthority
import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import ReqlyModel
import Testing
import X509

@testable import ProxyEngine

/// Client certificates: Reqly reads them from the files people have, and presents them to
/// the servers that ask apps to identify themselves.
@Suite(.timeLimit(.minutes(1))) struct ClientCertificateTests {
    let localhost = [HostPattern(rawValue: "127.0.0.1")!]

    @Test func readsPKCS12Files() throws {
        // An older file, with RC2 and 3DES as LibreSSL writes it, and one with AES, as newer
        // tools and Keychain Access write.
        for file in [Fixtures.legacyPKCS12, Fixtures.modernPKCS12] {
            let identity = try ClientIdentity(pkcs12: file, password: "secret", hosts: localhost)
            #expect(identity.name == "Reqly Test Client")
            #expect(identity.issuer == "Reqly Test Client")
            #expect(identity.expires == Date(timeIntervalSince1970: 2_106_402_950))
            #expect(throws: ClientIdentity.Problem.wrongPassword) {
                try ClientIdentity(pkcs12: file, password: "wrong", hosts: localhost)
            }
        }
        #expect(throws: ClientIdentity.Problem.unreadable) {
            try ClientIdentity(pkcs12: Array("not a certificate".utf8), password: "", hosts: localhost)
        }
    }

    @Test func readsPEMFiles() throws {
        let plain = try ClientIdentity(pem: Fixtures.certificate + Fixtures.key, password: nil, hosts: localhost)
        #expect(plain.name == "Reqly Test Client")
        let locked = try ClientIdentity(
            pem: Fixtures.certificate + Fixtures.encryptedKey, password: "secret", hosts: localhost)
        #expect(locked.expires == plain.expires)
        #expect(throws: ClientIdentity.Problem.wrongPassword) {
            try ClientIdentity(pem: Fixtures.certificate + Fixtures.encryptedKey, password: "wrong", hosts: localhost)
        }
        #expect(throws: ClientIdentity.Problem.noPrivateKey) {
            try ClientIdentity(pem: Fixtures.certificate, password: nil, hosts: localhost)
        }
        #expect(throws: ClientIdentity.Problem.noCertificate) {
            try ClientIdentity(pem: Fixtures.key, password: nil, hosts: localhost)
        }
        let otherKey = P256.Signing.PrivateKey().pemRepresentation
        #expect(throws: ClientIdentity.Problem.keyDoesNotMatch) {
            try ClientIdentity(pem: Fixtures.certificate + otherKey, password: nil, hosts: localhost)
        }
    }

    @Test func keepsTheCertificateAndKeyTogether() throws {
        let identity = try ClientIdentity(pkcs12: Fixtures.modernPKCS12, password: "secret", hosts: localhost)
        let restored = try ClientIdentity(serialized: try identity.serialized, hosts: localhost)
        #expect(restored.name == identity.name)
        #expect(restored.expires == identity.expires)
        #expect(throws: ClientIdentity.Problem.unreadable) {
            try ClientIdentity(serialized: Data("nothing".utf8), hosts: localhost)
        }
    }

    @Test(arguments: [false, true]) func presentsItToServersThatAskForOne(http2: Bool) async throws {
        let clientRoot = try RootIdentity.create()
        try await withDecryptingHarness(http2Origin: http2, clientCertificatesFrom: clientRoot) { harness in
            // Without one, the server turns Reqly away, and the app hears why.
            let refused = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(refused.status == 502)
            let failures = try await harness.log.wait { $0.contains { $0.failure != nil } }.compactMap(\.failure)
            #expect(failures == [.clientCertificateRequired])

            let identity = try ClientIdentity(
                pem: try clientCertificatePEM(from: clientRoot, name: "Weatherly App"), password: nil,
                hosts: localhost)
            #expect(identity.name == "Weatherly App")
            harness.proxy.setClientIdentities([identity])
            // The second request goes over the connection the first one opened, which presented
            // the certificate: the same HTTP/1.1 connection, or a new stream on the HTTP/2 one.
            let accepted = try await harness.withSecureConnection(inside: .http1) { app in
                let first = try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
                return [first, try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])]
            }
            #expect(accepted.map(\.status) == [200, 200])
            #expect(accepted.map(\.body) == ["hello", "hello"])
            let events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 2 }
            #expect(events.contains { $0.name == "serverReused" })
            for id in Set(events.filter(\.isResponseEnd).compactMap(\.exchange)) {
                #expect(events.filter { $0.exchange == id }.compactMap(\.clientCertificate) == ["Weatherly App"])
            }
        }
    }

    @Test func suggestsOneWhenATLS12ServerEndsTheHandshake() async throws {
        // On TLS 1.2 a server without the certificate it needs sends a general alert, which
        // doesn't say why, so the failure only suggests the certificate.
        let clientRoot = try RootIdentity.create()
        try await withDecryptingHarness(clientCertificatesFrom: clientRoot, originMaximumTLSVersion: .tlsv12) {
            harness in
            let refused = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(refused.status == 502)
            #expect(refused.body.contains("may require a client certificate"))
            let failures = try await harness.log.wait { $0.contains { $0.failure != nil } }.compactMap(\.failure)
            guard case .secureConnectionFailed(let reason) = failures.first else {
                Issue.record("Expected a failed handshake, got \(failures)")
                return
            }
            #expect(reason.contains("Add one in Settings, under Client Certificates."))
        }
    }

    @Test(arguments: [TLSVersion.tlsv12, .tlsv13])
    func saysWhenTheServerRejectsTheCertificate(version: TLSVersion) async throws {
        let clientRoot = try RootIdentity.create()
        try await withDecryptingHarness(clientCertificatesFrom: clientRoot, originMaximumTLSVersion: version) {
            harness in
            // A certificate from a root the server doesn't trust.
            let stranger = try ClientIdentity(
                pem: try clientCertificatePEM(from: try RootIdentity.create(), name: "Stranger"), password: nil,
                hosts: localhost)
            harness.proxy.setClientIdentities([stranger])
            let refused = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(refused.status == 502)
            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(events.compactMap(\.failure) == [.clientCertificateRejected])
            // The server asked for a certificate and got this one, which it turned down.
            #expect(events.compactMap(\.clientCertificate) == ["Stranger"])
        }
    }

    @Test func namesItOnlyOnceTheServerHasAskedForIt() async throws {
        let clientRoot = try RootIdentity.create()
        // Reqly doesn't trust the server's certificate, so the handshake stops before the server
        // asks for one, both for an app's request and for one Reqly sends.
        try await withDecryptingHarness(trustTheWebsite: false, clientCertificatesFrom: clientRoot) { harness in
            let identity = try ClientIdentity(
                pem: try clientCertificatePEM(from: clientRoot, name: "Weatherly App"), password: nil,
                hosts: localhost)
            harness.proxy.setClientIdentities([identity])
            let refused = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(refused.status == 502)
            let url = try #require(URL(string: "https://\(harness.origin.authority)/hello"))
            _ = harness.proxy.send(OutgoingRequest(method: "GET", url: url))
            let events = try await harness.log.wait { $0.compactMap(\.failure).count == 2 }
            for failure in events.compactMap(\.failure) {
                guard case .serverCertificateInvalid = failure else {
                    Issue.record("Expected a certificate Reqly doesn't trust, got \(failure)")
                    continue
                }
            }
            #expect(events.compactMap(\.clientCertificate).isEmpty)
        }
    }

    @Test func doesNotNameItWhenTheServerDoesNotAsk() async throws {
        try await withDecryptingHarness { harness in
            let identity = try ClientIdentity(
                pem: try clientCertificatePEM(from: try RootIdentity.create(), name: "Weatherly App"), password: nil,
                hosts: localhost)
            harness.proxy.setClientIdentities([identity])
            let response = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(response.status == 200)
            let url = try #require(URL(string: "https://\(harness.origin.authority)/hello"))
            _ = harness.proxy.send(OutgoingRequest(method: "GET", url: url))
            let events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 2 }
            #expect(events.compactMap(\.failure).isEmpty)
            #expect(events.compactMap(\.clientCertificate).isEmpty)
            // Only the second one was Reqly's own.
            #expect(events.filter(\.isSentByReqly).count == 1)
        }
    }

    @Test(arguments: ["127.0.0.1", "localhost"])
    func namesItOnEachConnectionThatPresentedIt(host: String) async throws {
        let clientRoot = try RootIdentity.create()
        try await withDecryptingHarness(clientCertificatesFrom: clientRoot, originCertificateHost: host) { harness in
            let identity = try ClientIdentity(
                pem: try clientCertificatePEM(from: clientRoot, name: "Weatherly App"), password: nil,
                hosts: [HostPattern(rawValue: host)!])
            harness.proxy.setClientIdentities([identity])
            let url = try #require(URL(string: "https://\(host):\(harness.origin.port)/hello"))
            // Requests sent together each open a connection, and each connection hears only about
            // its own handshake. The second round reuses what the first set up. localhost has an
            // IPv6 address too, where the website doesn't listen, so each connection to it tries
            // that address first, and that try fails.
            var sent: [ExchangeID] = []
            for _ in 0..<2 {
                let round = (0..<3).map { _ in harness.proxy.send(OutgoingRequest(method: "GET", url: url)).exchange }
                sent += round
                _ = try await harness.log.wait { events in
                    round.allSatisfy { id in events.contains { $0.isResponseEnd && $0.exchange == id } }
                }
            }
            let events = harness.log.events
            #expect(events.compactMap(\.failure).isEmpty)
            for id in sent {
                #expect(events.filter { $0.exchange == id }.compactMap(\.clientCertificate) == ["Weatherly App"])
            }
        }
    }

    @Test func blamesAMissingCertificateOnlyWhenReqlyHasNone() {
        struct Alert: Error, CustomStringConvertible {
            let description: String
        }
        func failure(_ alert: String, _ certificate: ClientCertificateUse) -> ExchangeFailure {
            let error = Alert(description: "error:10000410:SSL routines:OPENSSL_internal:SSLV3_ALERT_\(alert)")
            return ClientConnectionHandler.serverFailure(for: error, certificate: certificate)
        }
        // TLS 1.2 servers send this general alert when a certificate they need is missing.
        #expect(failure("HANDSHAKE_FAILURE", .noCertificate).message.contains("Reqly has none for this host"))
        // With a certificate the server never asked for, the alert is about something else.
        #expect(!failure("HANDSHAKE_FAILURE", .ready("Weatherly App")).message.contains("client certificate"))

        #expect(failure("BAD_CERTIFICATE", .noCertificate) == .clientCertificateRequired)
        #expect(failure("BAD_CERTIFICATE", .presented("Weatherly App")) == .clientCertificateRejected)
        #expect(failure("BAD_CERTIFICATE", .ready("Weatherly App")) != .clientCertificateRejected)
    }

    @Test func presentsItOnlyToItsHosts() async throws {
        let clientRoot = try RootIdentity.create()
        try await withDecryptingHarness(clientCertificatesFrom: clientRoot) { harness in
            let elsewhere = try ClientIdentity(
                pem: try clientCertificatePEM(from: clientRoot, name: "Elsewhere"), password: nil,
                hosts: [HostPattern(rawValue: "*.bank.dev")!])
            harness.proxy.setClientIdentities([elsewhere])
            let refused = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(refused.status == 502)
        }
    }
}

/// A client certificate from `root`, with its private key, as one PEM text.
func clientCertificatePEM(from root: RootIdentity, name: String) throws -> String {
    let key = P256.Signing.PrivateKey()
    let now = Date()
    let certificate = try Certificate(
        version: .v3,
        serialNumber: Certificate.SerialNumber(),
        publicKey: Certificate.PublicKey(key.publicKey),
        notValidBefore: now - 3600,
        notValidAfter: now + 86_400,
        issuer: root.certificate.subject,
        subject: try DistinguishedName { CommonName(name) },
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try Certificate.Extensions {
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.clientAuth])
        },
        issuerPrivateKey: Certificate.PrivateKey(root.key)
    )
    return try certificate.serializeAsPEM().pemString + "\n" + key.pemRepresentation + "\n"
}

/// A self-signed client certificate, "Reqly Test Client", made with LibreSSL, whose files are
/// locked with the password "secret".
private enum Fixtures {
    static let legacyPKCS12 = [UInt8](
        Data(
            base64Encoded: """
                MIIDSgIBAzCCAxAGCSqGSIb3DQEHAaCCAwEEggL9MIIC+TCCAe8GCSqGSIb3DQEHBqCCAeAwggHcAgEAMIIB1QYJKoZIhvcNAQcB\
                MBwGCiqGSIb3DQEMAQYwDgQI0pPQVF6i+GMCAggAgIIBqIeV3AS95qOL1w5tPg6Vr3U8nc7gs0OdPzYZ/PV5Jj1eO86FwPxvyYkt\
                SrqJlb4pfX081yPCoXPJUjPBw8U2sHXiiVu+QXNAIq38KOcgEpkVUA5dhok6w00C4Xx1f385tx70Lq+UABhfQ/EmZvvPqmogCd76\
                ebaLts+Sek+TLugFEm80/jxS9hJbdadnt0Gl4eex0KNyUZzYvd0dOQObqHIKXi591fcdzHVr6Fa1JgBhcwiXw+Kc3jlNYUS5dty4\
                oxqG29SzOx4IPNWS4VKqs10Aeb7/kyJnXZEwWv7pExSuja+SF/oO0G7y0rYEKTkj59qveAVuI0xhNvFY6vaJ6TGRWdqELmmQrers\
                Hxb5vKEQXRhyBZibCf2DqcKUQEuH7NPjn5v0zXAbLiPA12INwDeUW1VIYocoQ1T3X2W0RN1clAwAY86QrfEsJYJTptrnTtFxtptA\
                yGyrWg/iIfJCjykrrFTb+JRberc1gklzcwKxCL4tvCCSt3tuQdrc0dLr0QuJNpNxA4F3JJpjvnNTcX3g/WGXN/ZH6HWE2EkvVNWn\
                y8C1ZD2tMuYwggECBgkqhkiG9w0BBwGggfQEgfEwge4wgesGCyqGSIb3DQEMCgECoIG0MIGxMBwGCiqGSIb3DQEMAQMwDgQIMaRa\
                ClsnclsCAggABIGQe+kkTu8q5Xt+JI5ikUAjeVnsLtifq1zVQJA6vcNEcvVfrYR8xl0rVwaal1L/HLNdS8od8CGFv4pefYMhTwUG\
                PNQhMVSluSxWPhiZ4fMlty0O5ctPTVGzSJDpmZvYsyXV47ci4Bn+y6QjbpS+gyLnqESatSqs6crhgu3QGenPQ1Gv09bgG69XJFWJ\
                H4hlZ4AOMSUwIwYJKoZIhvcNAQkVMRYEFG3oO3/r7fa2OLKZc7yEbWEZoC0aMDEwITAJBgUrDgMCGgUABBRWAyoBnhqvAK18Pzej\
                Ds4kEKqNOAQIWpk6rz4gR9YCAggA
                """)!)
    static let modernPKCS12 = [UInt8](
        Data(
            base64Encoded: """
                MIIDwAIBAzCCA3YGCSqGSIb3DQEHAaCCA2cEggNjMIIDXzCCAiQGCSqGSIb3DQEHBqCCAhUwggIRAgEAMIICCgYJKoZIhvcNAQcB\
                MEkGCSqGSIb3DQEFDTA8MBsGCSqGSIb3DQEFDDAOBAjVxm+gsgUnaAICCAAwHQYJYIZIAWUDBAEqBBBC+zWxZDildHPNSoZdMWeJ\
                gIIBsEqdZR5XXAr6qeWl1U4r2SaSRiFiRAHeE6UK4yxNVYen//6bbvNSa0hVoeSEaKEboLmK97qhKAxhcjjz1aK8hZUEVIZwDVBm\
                /2Hhu0y84CqFibwpRQBT1KEvH0LoMMKL/06rId8HJnykrriwnFsP3rIaB0aQN7PPyT5Oz9z6h2FMaBoKnu0px8zxynaIidETbiRd\
                0/fksbE/SHr3NzdVaRqdm6ukuOyGv0yPKv0aoNMO215EC2SYQv/eP4Y8Z+iaf70HRF9gwfDfBMnvWGUKN1k3sMqaQPtm4GWL9kJN\
                pqyfyX5gPWo+N3x7tui3lU6bo6etZdAsmbT7ElhkEBVMaKS1RN0VcoczNqGI24oJncFNia38RXNAPIlhNqjElmhZOpSdy+CTWobb\
                JpTA3GyYWpBlalnlNCjlpfnRXp7UbsQzf6d+ZLdqZTXjsbuRw3b8wBmYIHueAJU64YADu53eCHVOXpuUDDMmlEUzRcnmz8slJ25B\
                YadQMx1dPbS1lCjHIHN0WCgP2GpozBnNHdqe5sB8e3FNftHYEGHtnSe5d9SUBT/WR83KfB0zJ4+FjpPE6DCCATMGCSqGSIb3DQEH\
                AaCCASQEggEgMIIBHDCCARgGCyqGSIb3DQEMCgECoIHhMIHeMEkGCSqGSIb3DQEFDTA8MBsGCSqGSIb3DQEFDDAOBAit293ThKZL\
                wwICCAAwHQYJYIZIAWUDBAEqBBAUzTs4PA6ZEf108UwuyM3pBIGQZuKsVR5nnnH+ETqkJ63fbAaMrDp0/e8TSBZCqReQyy+lwfFV\
                M3Ho+Z2CkCk6HTYryFRDYPbqfFdO+tuL9IUNBoIggQfkKGJkGJwprF4VvTdVWgCdP9FGZYRFGTi7bhvmL51u3w0l2ggyAbY3nq4V\
                X9z13TYhJUiU8M72Gh69NeVcLoPdGeW+KklrFxCTT9oCMSUwIwYJKoZIhvcNAQkVMRYEFG3oO3/r7fa2OLKZc7yEbWEZoC0aMEEw\
                MTANBglghkgBZQMEAgEFAAQgiLiFGz3okn5J4O2AHYJzz337RNX5deoP1f7zNtjuz/EECGZW+/5r65m1AgIIAA==
                """)!)
    static let certificate = """
        -----BEGIN CERTIFICATE-----
        MIIBRjCB7gIJAIYTvbQ1hBdlMAoGCCqGSM49BAMCMCwxGjAYBgNVBAMMEVJlcWx5
        IFRlc3QgQ2xpZW50MQ4wDAYDVQQKDAVSZXFseTAeFw0yNjEwMDMxNTU1NTBaFw0z
        NjA5MzAxNTU1NTBaMCwxGjAYBgNVBAMMEVJlcWx5IFRlc3QgQ2xpZW50MQ4wDAYD
        VQQKDAVSZXFseTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOXR0U4hcG0kJpmf
        5WRsSRu290nJ7vbdV2sD0iEbXUh2uqQe7AjlotiLlxsp+Ps6mYRv2ewgI8Ay7dmM
        eZryULEwCgYIKoZIzj0EAwIDRwAwRAIgNXAxdPGC/zm34w9Rr6FoYqQegMjcrX2u
        DME4oe8yp9wCIC1WHr02Rhwtpi2ixH+BOlzE5ae0IWkUQtRQCI7/fzvK
        -----END CERTIFICATE-----

        """
    static let key = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgT6wrIZbgL6OShGn1
        1y8SJ7exaMykd8qySvBgzh7VWKOhRANCAATl0dFOIXBtJCaZn+VkbEkbtvdJye72
        3VdrA9IhG11IdrqkHuwI5aLYi5cbKfj7OpmEb9nsICPAMu3ZjHma8lCx
        -----END PRIVATE KEY-----

        """
    static let encryptedKey = """
        -----BEGIN ENCRYPTED PRIVATE KEY-----
        MIHeMEkGCSqGSIb3DQEFDTA8MBsGCSqGSIb3DQEFDDAOBAiTA+1b31TNuwICCAAw
        HQYJYIZIAWUDBAEqBBDzPFyBOCKdXfbVSfJ4FjN+BIGQRPoSts+8AAUgXr39jFO+
        eDu60M5FLUJOGKzxX3KpM1+1xCZHJ5v2SFjXOaXNSMVpVPGuDlc7iUKt0VQSQaxJ
        isUWZ6UaedPqD5ZYmiMPykJK8dYBBh2e/a44qbO1VAblVg744PpHWDw+RYhXyazT
        wRSYRoDgjIYljfpp19/E6VFdBHwt9T/10x8wn87p0yZz
        -----END ENCRYPTED PRIVATE KEY-----

        """
}
