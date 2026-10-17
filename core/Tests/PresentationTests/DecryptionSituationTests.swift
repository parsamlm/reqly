import Foundation
import Presentation
import ReqlyModel
import Testing

@Suite struct DecryptionSituationTests {
    func exchange(_ kind: ExchangeKind, scheme: String = "https", state: ExchangeState = .completed) -> Exchange {
        let tunnel = kind == .tunnel
        var exchange = Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 1), kind: kind,
            request: RequestHead(
                method: tunnel ? "CONNECT" : "GET", scheme: scheme, host: "api.weatherly.dev", port: 443,
                target: tunnel ? "api.weatherly.dev:443" : "/v2/forecast"),
            started: Date(timeIntervalSinceReferenceDate: 0))
        exchange.state = state
        return exchange
    }

    @Test func tellsATunnelFromARequestReqlyDecrypted() {
        #expect(DecryptionSituation(exchange(.tunnel, state: .open)) == .encryptedTunnel)
        #expect(DecryptionSituation(exchange(.http)) == .decrypted)
        #expect(DecryptionSituation(exchange(.http, scheme: "http")) == .plain)
    }

    @Test func blamesTheCertificateOnlyForAFailedHandshake() {
        #expect(DecryptionSituation(exchange(.tunnel, state: .failed(.certificateRejected))) == .certificateRejected)
        let handshake = ExchangeFailure.secureConnectionFailed("The handshake failed.")
        #expect(DecryptionSituation(exchange(.tunnel, state: .failed(handshake))) == .certificateRejected)
        let unreachable = ExchangeFailure.cannotConnect("The name didn't resolve.")
        #expect(DecryptionSituation(exchange(.tunnel, state: .failed(unreachable))) == .plain)
    }
}
