import Capture
import Foundation
import ProxyEngine
import ReqlyModel
import Testing

@Suite struct ExchangeAssemblerTests {
    let id = ExchangeID(rawValue: 1)
    let connection = ConnectionID(rawValue: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1000)

    func request(_ method: String = "GET", scheme: String = "http") -> RequestHead {
        RequestHead(
            method: method, scheme: scheme, host: "api.weatherly.dev", port: scheme == "https" ? 443 : 80,
            target: "/v2/forecast")
    }

    @Test func buildsACompletedExchange() throws {
        var assembler = ExchangeAssembler()
        assembler.apply(.requestHead(id, connection, request("POST"), at: start))
        assembler.apply(.requestBody(id, Data("{}".utf8)))
        assembler.apply(.requestEnd(id, at: start + 0.01))
        #expect(assembler.exchanges[id]?.state == .waiting)

        assembler.apply(.serverConnecting(id, at: start + 0.01))
        assembler.apply(.serverConnected(id, address: "203.0.113.24:80", at: start + 0.03))
        assembler.apply(.requestSent(id, at: start + 0.031))
        assembler.apply(.responseHead(id, ResponseHead(status: 200, reason: "OK"), at: start + 0.1))
        #expect(assembler.exchanges[id]?.state == .receiving)
        assembler.apply(.responseBody(id, Data("{\"t\":".utf8)))
        assembler.apply(.responseBody(id, Data("14}".utf8)))
        assembler.apply(.responseEnd(id, at: start + 0.2))

        let exchange = try #require(assembler.exchanges[id])
        #expect(exchange.kind == .http)
        #expect(exchange.state == .completed)
        // Bodies go straight to the store; the assembler only counts them.
        #expect(exchange.requestBody.isEmpty)
        #expect(exchange.responseBody.isEmpty)
        #expect(exchange.bytesSent == 2)
        #expect(exchange.bytesReceived == 8)
        #expect(exchange.timing.connected == start + 0.03)
        #expect(exchange.timing.requestSent == start + 0.031)
        #expect(exchange.remoteAddress == "203.0.113.24:80")
        #expect(!exchange.reusedConnection)
        #expect(abs(try #require(exchange.summary.duration) - 0.2) < 0.001)
        #expect(exchange.summary.status == 200)
    }

    @Test func recordsEachStepOfASecureConnection() throws {
        var assembler = ExchangeAssembler()
        assembler.apply(.requestHead(id, connection, request(scheme: "https"), at: start))
        assembler.apply(.serverConnecting(id, at: start))
        assembler.apply(.serverResolved(id, at: start + 0.012))
        assembler.apply(.serverConnected(id, address: "[2001:db8::1]:443", at: start + 0.03))
        assembler.apply(.serverSecured(id, tlsVersion: "1.3", at: start + 0.061))
        let exchange = try #require(assembler.exchanges[id])
        #expect(exchange.timing.resolved == start + 0.012)
        #expect(exchange.timing.secured == start + 0.061)
        #expect(exchange.remoteAddress == "[2001:db8::1]:443")
        #expect(exchange.tlsVersion == "1.3")

        // The next request on the same connection skips all of that.
        let next = ExchangeID(rawValue: 2)
        assembler.apply(.requestHead(next, connection, request(scheme: "https"), at: start + 1))
        assembler.apply(.serverReused(next, address: "[2001:db8::1]:443", tlsVersion: "1.3"))
        let reused = try #require(assembler.exchanges[next])
        #expect(reused.reusedConnection)
        #expect(reused.timing.connectStarted == nil)
        #expect(reused.remoteAddress == "[2001:db8::1]:443")
        #expect(reused.tlsVersion == "1.3")
    }

    @Test func recordsTunnels() throws {
        var assembler = ExchangeAssembler()
        let connect = RequestHead(
            method: "CONNECT", scheme: "https", host: "api.weatherly.dev", port: 443, target: "api.weatherly.dev:443"
        )
        assembler.apply(.requestHead(id, connection, connect, at: start))
        assembler.apply(.requestEnd(id, at: start))
        assembler.apply(.tunnelOpened(id, at: start + 0.05))
        #expect(assembler.exchanges[id]?.state == .open)

        assembler.apply(.tunnelClosed(id, bytesSent: 517, bytesReceived: 4096, at: start + 2))
        let exchange = try #require(assembler.exchanges[id])
        #expect(exchange.kind == .tunnel)
        #expect(exchange.state == .completed)
        #expect(exchange.bytesSent == 517)
        #expect(exchange.bytesReceived == 4096)
        #expect(exchange.timing.duration == 2)
    }

    @Test func keepsTheReasonForAFailure() {
        var assembler = ExchangeAssembler()
        assembler.apply(.requestHead(id, connection, request(), at: start))
        assembler.apply(.failed(id, .serverClosed, at: start + 1))
        #expect(assembler.exchanges[id]?.state == .failed(.serverClosed))
        // A tunnel that closes later doesn't hide the failure.
        assembler.apply(.tunnelClosed(id, bytesSent: 0, bytesReceived: 0, at: start + 2))
        #expect(assembler.exchanges[id]?.state == .failed(.serverClosed))
    }

    @Test func keepsFinishedExchangesForAMoment() {
        var assembler = ExchangeAssembler()
        let open = ExchangeID(rawValue: 2)
        let keptForLater = ExchangeID(rawValue: 3)
        for exchange in [id, open, keptForLater] {
            assembler.apply(.requestHead(exchange, connection, request(), at: start))
        }
        assembler.apply(.responseEnd(id, at: start + 1))
        assembler.apply(.responseEnd(keptForLater, at: start + 1))

        assembler.removeFinished(before: start + 1)
        #expect(assembler.exchanges.count == 3)
        assembler.removeFinished(before: start + 2, keeping: [keptForLater])
        #expect(Set(assembler.exchanges.keys) == [open, keptForLater])
    }

    @Test func creditsAConnectionsExchangesToWhatOpenedIt() {
        var assembler = ExchangeAssembler()
        let safari = Source(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app")
        let client = ClientAddress(ip: "127.0.0.1", port: 50_000)
        assembler.apply(.connectionOpened(connection, client: client, at: start))
        assembler.apply(.requestHead(id, connection, request(), at: start))
        #expect(assembler.exchanges[id]?.source == nil)

        #expect(assembler.setOrigin(Origin(source: safari), for: connection) == [id])
        #expect(assembler.exchanges[id]?.source == safari)
        // The connection's next exchanges get it right away.
        let next = ExchangeID(rawValue: 2)
        assembler.apply(.requestHead(next, connection, request(), at: start))
        #expect(assembler.exchanges[next]?.source == safari)

        // Once the connection closes, a late answer isn't kept for it.
        let other = ConnectionID(rawValue: 2)
        assembler.apply(.connectionOpened(other, client: client, at: start))
        assembler.apply(.connectionClosed(other, at: start))
        #expect(assembler.setOrigin(Origin(source: safari), for: other).isEmpty)
        assembler.apply(.requestHead(ExchangeID(rawValue: 3), other, request(), at: start))
        #expect(assembler.exchanges[ExchangeID(rawValue: 3)]?.source == nil)
    }

    @Test func keepsPinnedExchangesWhenCleared() {
        var assembler = ExchangeAssembler()
        let next = ExchangeID(rawValue: 2)
        assembler.apply(.requestHead(id, connection, request(), at: start))
        assembler.apply(.requestHead(next, connection, request(), at: start))
        assembler.annotate(next, with: Annotation(isPinned: true))

        assembler.removeUnpinned()
        #expect(Array(assembler.exchanges.keys) == [next])
        // A pinned exchange in progress keeps getting its events.
        #expect(assembler.apply(.responseEnd(next, at: start + 1)) == next)
        #expect(assembler.exchanges[next]?.annotation.isPinned == true)
    }

    @Test func recordsRulesAndPauses() throws {
        var assembler = ExchangeAssembler()
        let breakpoint = AppliedRule(name: "Forecast", kind: .breakpoint, detail: "Paused the request.")
        assembler.apply(.requestHead(id, connection, request(), at: start))
        assembler.apply(.requestEnd(id, at: start))
        assembler.apply(.ruleApplied(id, breakpoint))
        assembler.apply(.paused(id, .request(request(), body: Data()), breakpoint: "Forecast"))
        #expect(assembler.exchanges[id]?.state == .paused(.request))
        #expect(assembler.exchanges[id]?.state.isFinished == false)
        assembler.apply(.resumed(id, .request))
        #expect(assembler.exchanges[id]?.state == .waiting)

        assembler.apply(.responseHead(id, ResponseHead(status: 200, reason: "OK"), at: start + 0.1))
        assembler.apply(
            .paused(id, .response(ResponseHead(status: 200, reason: "OK"), body: Data()), breakpoint: "Forecast"))
        #expect(assembler.exchanges[id]?.state == .paused(.response))
        assembler.apply(.resumed(id, .response))
        #expect(assembler.exchanges[id]?.state == .receiving)
        assembler.apply(.responseEnd(id, at: start + 0.2))

        let exchange = try #require(assembler.exchanges[id])
        #expect(exchange.state == .completed)
        #expect(exchange.appliedRules == [breakpoint])
    }

    @Test func namesAPhonesAppsFromTheirUserAgents() throws {
        var assembler = ExchangeAssembler()
        let phone = Device(id: "mac:a4:83:e7:12:34:56", kind: .network, name: "iPhone", address: "192.168.1.23")
        let client = ClientAddress(ip: "192.168.1.23", port: 50_000)
        assembler.apply(.connectionOpened(connection, client: client, at: start))
        var weather = request()
        weather.headers = ["User-Agent": "Weather/1 CFNetwork/1498.700.2 Darwin/23.6.0"]
        assembler.apply(.requestHead(id, connection, weather, at: start))
        // The device is known a moment later, and then so is the app.
        #expect(assembler.setOrigin(Origin(device: phone), for: connection) == [id])
        #expect(assembler.exchanges[id]?.source == Source(name: "Weather"))

        // Later requests on the connection get theirs right away. An encrypted tunnel names no app.
        let tunnel = ExchangeID(rawValue: 2)
        let connect = RequestHead(
            method: "CONNECT", scheme: "https", host: "gateway.icloud.com", port: 443, target: "gateway.icloud.com:443")
        assembler.apply(.requestHead(tunnel, connection, connect, at: start))
        #expect(assembler.exchanges[tunnel]?.device == phone)
        #expect(assembler.exchanges[tunnel]?.source == nil)

        // On this Mac, the app at the other end counts, whatever the User-Agent says.
        let mac = ConnectionID(rawValue: 2)
        let safari = Source(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app")
        assembler.apply(.connectionOpened(mac, client: ClientAddress(ip: "127.0.0.1", port: 50_001), at: start))
        _ = assembler.setOrigin(Origin(source: safari), for: mac)
        assembler.apply(.requestHead(ExchangeID(rawValue: 3), mac, weather, at: start))
        #expect(assembler.exchanges[ExchangeID(rawValue: 3)]?.source == safari)
    }

    @Test func marksTheRequestsReqlySentItself() throws {
        var assembler = ExchangeAssembler()
        assembler.apply(.requestHead(id, connection, request(scheme: "https"), at: start))
        #expect(assembler.exchanges[id]?.sentByReqly == false)
        #expect(assembler.apply(.sentByReqly(id)) == id)
        let exchange = try #require(assembler.exchanges[id])
        #expect(exchange.sentByReqly)
        #expect(!exchange.isDecrypted)
    }

    @Test func ignoresEventsForExchangesItDoesNotKnow() {
        var assembler = ExchangeAssembler()
        #expect(assembler.apply(.responseEnd(id, at: start)) == nil)
        #expect(assembler.exchanges.isEmpty)
    }
}
