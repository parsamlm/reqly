import Foundation
import ReqlyModel
import Testing

@testable import ProxyEngine

/// Real websites' certificates, through Reqly's decryption, checked the way the system checks
/// them: a good one passes, and BadSSL's broken ones don't. It reaches the internet, so it runs
/// only when `REQLY_LIVE_TLS` is set: `REQLY_LIVE_TLS=1 swift test --filter LiveCertificateTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REQLY_LIVE_TLS"] != nil), .timeLimit(.minutes(1)))
struct LiveCertificateTests {
    enum Outcome: Sendable {
        case trusted, untrusted, forAnotherHost
    }

    @Test(arguments: [
        ("www.google.com", Outcome.trusted),
        ("expired.badssl.com", .untrusted),
        ("untrusted-root.badssl.com", .untrusted),
        ("self-signed.badssl.com", .untrusted),
        ("wrong.host.badssl.com", .forAnotherHost),
    ])
    func checksAWebsitesCertificate(_ host: String, _ outcome: Outcome) async throws {
        try await withDecryptingHarness(decrypt: host) { harness in
            let response = try await harness.withSecureConnection(inside: .http1, to: "\(host):443") { app in
                try await app.send(.GET, "/", headers: ["Host": host])
            }
            if outcome == .trusted {
                #expect(response.status != 502, "\(response.body.prefix(300))")
                return
            }
            #expect(response.status == 502)
            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            guard case .serverCertificateInvalid(let reason) = events.compactMap(\.failure).first else {
                Issue.record("Expected an invalid certificate, got \(events.compactMap(\.failure))")
                return
            }
            // macOS checks the name along with the rest, so there a certificate for another host is
            // one the Mac doesn't trust.
            let reasons = outcome == .untrusted ? ["doesn't trust"] : ["isn't for this host", "doesn't trust"]
            #expect(reasons.contains { reason.contains($0) }, "\(reason)")
        }
    }
}
