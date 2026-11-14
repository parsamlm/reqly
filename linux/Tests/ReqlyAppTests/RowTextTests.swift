import Foundation
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct RowTextTests {
    static let english = Locale(identifier: "en_US")
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-03 at 11:05:59 in UTC.
    static let started = Date(timeIntervalSince1970: 1_793_703_959)

    static func summary(
        kind: ExchangeKind = .http, method: String = "GET", scheme: String = "http", host: String = "127.0.0.1",
        port: Int = 8080, target: String = "/forecast?city=Turin", status: Int? = 200,
        state: ExchangeState = .completed, bytesReceived: Int64 = 1_234, source: Source? = Source(name: "curl")
    ) -> ExchangeSummary {
        var exchange = Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 1), kind: kind,
            request: RequestHead(method: method, scheme: scheme, host: host, port: port, target: target),
            started: started)
        exchange.response = status.map { ResponseHead(status: $0, reason: "") }
        exchange.state = state
        exchange.bytesReceived = bytesReceived
        exchange.source = source
        return exchange.summary
    }

    static func text(_ summary: ExchangeSummary) -> RowText {
        RowText(summary, locale: english, timeLocale: english, timeZone: utc)
    }

    @Test func showsARequestAsTheMacDoes() {
        var summary = Self.summary()
        summary.duration = 0.161
        let text = Self.text(summary)
        #expect(text.look == .status(.success))
        #expect(text.status == "200")
        #expect(text.statusDescription == "200 OK")
        #expect(text.statusHelp == nil)
        #expect(text.method == "GET")
        #expect(text.host == "127.0.0.1:8080")
        #expect(text.path == "/forecast?city=Turin")
        #expect(text.request == ("127.0.0.1:8080", "/forecast?city=Turin"))
        #expect(text.app == "curl")
        // ICU puts a narrow space before AM.
        #expect(text.time == "11:05:59\u{202F}AM")
        #expect(text.duration == "161 ms")
        #expect(text.size == "1.2 KB")
        #expect(
            text.label == "200 OK, GET, 127.0.0.1:8080/forecast?city=Turin, curl, 11:05:59\u{202F}AM, 161 ms, 1.2 KB")
        #expect(Self.text(Self.summary(scheme: "https", port: 443)).host == "127.0.0.1")
        #expect(Self.text(Self.summary(port: 80)).host == "127.0.0.1")
    }

    @Test func colorsEachClassOfStatus() {
        let expected: [(Int, StatusClass, String)] = [
            (101, .informational, "101 Switching Protocols"), (302, .redirection, "302 Found"),
            (404, .clientError, "404 Not Found"), (503, .serverError, "503 Service Unavailable"),
            (299, .success, "299"),
        ]
        for (status, statusClass, words) in expected {
            let text = Self.text(Self.summary(status: status))
            #expect(text.look == .status(statusClass))
            #expect(text.status == String(status))
            #expect(text.statusDescription == words)
        }
        // A gRPC call that failed behind HTTP 200 takes the call's class, and says why.
        var call = Self.summary()
        call.grpcStatus = 5
        let grpc = Self.text(call)
        #expect(grpc.look == .status(.clientError))
        #expect(grpc.statusDescription == "200 OK, gRPC status 5 not found")
        #expect(grpc.statusHelp == grpc.statusDescription)
    }

    @Test func saysAnEncryptedConnectionOnce() {
        let open = Self.text(
            Self.summary(
                kind: .tunnel, method: "CONNECT", scheme: "https", host: "example.com", port: 443,
                target: "example.com:443", status: nil, state: .open, bytesReceived: 0))
        #expect(open.look == .encrypted)
        #expect(open.isEncrypted)
        #expect(open.path == "Encrypted connection")
        #expect(open.request == ("example.com", "  Encrypted connection"))
        #expect(open.status.isEmpty)
        #expect(open.statusDescription == "Encrypted connection, open")
        #expect(open.size.isEmpty)
        #expect(open.label == "Encrypted connection, open, CONNECT, example.com, curl, 11:05:59\u{202F}AM")
        let closed = Self.text(Self.summary(kind: .tunnel, scheme: "https", port: 443, target: "", status: nil))
        #expect(closed.statusDescription == "Encrypted connection")
    }

    @Test func saysWhenARequestFailedPausedOrWaits() {
        let failed = Self.text(Self.summary(status: nil, state: .failed(.cannotConnect("refused")), bytesReceived: 0))
        #expect(failed.look == .failed)
        #expect(failed.status == "Failed")
        #expect(failed.statusDescription == "Couldn't connect to the server: refused")
        #expect(failed.size.isEmpty)
        let closed = Self.text(Self.summary(status: nil, state: .failed(.serverClosed), bytesReceived: 0))
        #expect(closed.statusDescription == "The server closed the connection before the response finished.")
        #expect(
            closed.label
                == "The server closed the connection before the response finished, GET, "
                + "127.0.0.1:8080/forecast?city=Turin, curl, 11:05:59\u{202F}AM")
        let paused = Self.text(Self.summary(status: nil, state: .paused(.response), bytesReceived: 0))
        #expect(paused.look == .paused)
        #expect(paused.status == "Paused")
        #expect(paused.statusDescription == "Paused at a breakpoint, before the response goes on")
        let waiting = Self.text(Self.summary(status: nil, state: .waiting, bytesReceived: 0))
        #expect(waiting.look == .waiting)
        #expect(waiting.status.isEmpty)
        #expect(waiting.statusDescription == "In progress")
        #expect(waiting.duration.isEmpty)
        #expect(waiting.label == "In progress, GET, 127.0.0.1:8080/forecast?city=Turin, curl, 11:05:59\u{202F}AM")
        // Bytes that arrive show before the response is done.
        #expect(Self.text(Self.summary(state: .receiving, bytesReceived: 713)).size == "713 B")
        #expect(Self.text(Self.summary(source: nil)).app.isEmpty)
    }

    @Test func namesTheDeviceWhenTheAppIsntKnown() {
        var summary = Self.summary(source: nil)
        summary.device = Device(id: "a1", kind: .simulator, name: "iPhone 17 Pro")
        let device = Self.text(summary)
        #expect(device.app == "iPhone 17 Pro")
        #expect(device.appHelp == "iPhone 17 Pro · Simulator")
        summary.source = Source(name: "Weather")
        #expect(Self.text(summary).app == "Weather")
        #expect(Self.text(summary).appHelp == "Weather on iPhone 17 Pro · Simulator")
    }

    @Test func saysWhatsPinnedMarkedAndCommented() {
        var summary = Self.summary()
        summary.annotation = Annotation(isPinned: true, color: .red, comment: "Turin's forecast")
        let text = Self.text(summary)
        #expect(text.isPinned && text.color == .red && text.comment == "Turin's forecast")
        #expect(
            text.label
                == "200 OK, GET, 127.0.0.1:8080/forecast?city=Turin, curl, 11:05:59\u{202F}AM, 1.2 KB, pinned, marked red, "
                + "comment: Turin's forecast")
        #expect(MarkColor.allCases.map(\.title) == ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
    }

    @Test func saysWhereARowIs() {
        #expect(RowText.position(2, of: 10_000, locale: Self.english) == "Request 3 of 10,000")
        #expect(RowText.position(0, of: 1, locale: Self.english) == "Request 1 of 1")
    }

    @Test func writesDurationsAndTimesAsTheMacDoes() {
        #expect(Format.duration(nil).isEmpty)
        #expect(Format.duration(0.3404, locale: Self.english) == "340 ms")
        #expect(Format.duration(1.2391, locale: Self.english) == "1.24 s")
        #expect(Format.duration(252, locale: Self.english) == "4 min 12 s")
        #expect(Format.duration(7_500, locale: Self.english) == "2 h 5 min")
        #expect(Format.duration(0.0004, showingTenths: true, locale: Self.english) == "0.4 ms")
        #expect(Format.duration(0.0004, locale: Self.english) == "0 ms")
        #expect(Format.time(Self.started, locale: Locale(identifier: "en_GB"), timeZone: Self.utc) == "11:05:59")
    }
}
