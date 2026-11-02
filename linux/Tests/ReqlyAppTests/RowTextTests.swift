import Foundation
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct RowTextTests {
    static func summary(
        kind: ExchangeKind = .http, method: String = "GET", scheme: String = "http", host: String = "127.0.0.1",
        port: Int = 8080, target: String = "/forecast?city=Turin", status: Int? = 200,
        state: ExchangeState = .completed, bytesReceived: Int64 = 1_234, source: Source? = Source(name: "curl")
    ) -> ExchangeSummary {
        var exchange = Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 1), kind: kind,
            request: RequestHead(method: method, scheme: scheme, host: host, port: port, target: target),
            started: Date())
        exchange.response = status.map { ResponseHead(status: $0, reason: "") }
        exchange.state = state
        exchange.bytesReceived = bytesReceived
        exchange.source = source
        return exchange.summary
    }

    @Test func showsARequestAsWindowsDoes() {
        let text = RowText(Self.summary())
        #expect(text.app == "curl")
        #expect(text.method == "GET")
        #expect(text.host == "127.0.0.1:8080")
        #expect(text.path == "/forecast?city=Turin")
        #expect(text.status == "200")
        #expect(text.size == "1.2 KB")
        #expect(!text.showsLock)
        #expect(text.statusDescription == "200")
        #expect(RowText(Self.summary(scheme: "https", port: 443)).host == "127.0.0.1")
        #expect(RowText(Self.summary(port: 80)).host == "127.0.0.1")
    }

    @Test func showsAnEncryptedConnectionWithALock() {
        let open = RowText(
            Self.summary(
                kind: .tunnel, method: "CONNECT", scheme: "https", host: "example.com", port: 443, target: "",
                status: nil, state: .open, bytesReceived: 0))
        #expect(open.showsLock)
        #expect(open.path == "Encrypted connection")
        #expect(open.status.isEmpty)
        #expect(open.statusDescription == "Encrypted connection, open")
        #expect(open.size.isEmpty)
        let closed = RowText(Self.summary(kind: .tunnel, scheme: "https", port: 443, target: "", status: nil))
        #expect(closed.showsLock)
        #expect(closed.statusDescription == "Encrypted connection")
    }

    @Test func saysWhenARequestFailedOrWaits() {
        let failed = RowText(Self.summary(status: nil, state: .failed(.cannotConnect("refused")), bytesReceived: 0))
        #expect(failed.status == "Failed")
        #expect(!failed.showsLock)
        #expect(failed.size.isEmpty)
        let waiting = RowText(Self.summary(status: nil, state: .waiting, bytesReceived: 0))
        #expect(waiting.status.isEmpty)
        #expect(waiting.statusDescription == "In progress")
        #expect(RowText(Self.summary(source: nil)).app.isEmpty)
    }
}
