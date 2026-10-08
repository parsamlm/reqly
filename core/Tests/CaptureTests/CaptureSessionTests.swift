import Foundation
import ProxyEngine
import ReqlyModel
import Synchronization
import Testing
import TrafficStore

@testable import Capture

/// A store in a temporary folder, for one test.
func temporaryStore(_ limits: TrafficStore.Limits = TrafficStore.Limits()) throws -> TrafficStore {
    try TrafficStore(
        directory: URL.temporaryDirectory.appending(
            path: "ReqlyTests-\(UUID().uuidString)", directoryHint: .isDirectory),
        limits: limits
    )
}

/// What the stand-in for the Mac's proxy fails with, as the helper would.
enum FakeProxyError: Error, Equatable {
    case needsApproval
    case failed(String)
}

/// Records what the session asks of the Mac's proxy, without changing anything.
final class FakeSystemProxy: SystemProxySwitch {
    private let log = Mutex<[String]>([])
    private let failures = Mutex<(enable: FakeProxyError?, disable: FakeProxyError?)>((nil, nil))

    var calls: [String] { log.withLock { $0 } }

    func failEnable(with error: FakeProxyError?) {
        failures.withLock { $0.enable = error }
    }

    func failDisable(with error: FakeProxyError?) {
        failures.withLock { $0.disable = error }
    }

    func enable(port: Int) async throws {
        log.withLock { $0.append("enable \(port)") }
        if let error = failures.withLock({ $0.enable }) { throw error }
    }

    func disable() async throws {
        log.withLock { $0.append("disable") }
        if let error = failures.withLock({ $0.disable }) { throw error }
    }
}

@Suite(.timeLimit(.minutes(1))) struct CaptureSessionTests {
    @Test func pointsTheMacAtTheProxyWhileCapturing() async throws {
        let systemProxy = FakeSystemProxy()
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store, systemProxy: systemProxy)

        let port = try await session.start(port: 0)
        #expect(await session.isCapturing)
        #expect(systemProxy.calls == ["enable \(port)"])

        try await session.stop()
        #expect(await !session.isCapturing)
        #expect(systemProxy.calls == ["enable \(port)", "disable"])
    }

    @Test func doesNotCaptureUntilTheHelperIsAllowed() async throws {
        let systemProxy = FakeSystemProxy()
        systemProxy.failEnable(with: .needsApproval)
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store, systemProxy: systemProxy)

        await #expect(throws: FakeProxyError.needsApproval) {
            try await session.start(port: 0)
        }
        #expect(await !session.isCapturing)
    }

    @Test func keepsTheProxyRunningWhenTheSettingsCannotGoBack() async throws {
        let systemProxy = FakeSystemProxy()
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store, systemProxy: systemProxy)
        try await session.start(port: 0)

        systemProxy.failDisable(with: .failed("The helper didn't answer."))
        await #expect(throws: FakeProxyError.failed("The helper didn't answer.")) {
            try await session.stop()
        }
        // Apps still point at Reqly, so Reqly keeps relaying their traffic.
        #expect(await session.isCapturing)

        systemProxy.failDisable(with: nil)
        try await session.stop()
        #expect(await !session.isCapturing)
    }
}

/// Recording goes through `record(_:)` directly, so these tests need no network.
@Suite(.timeLimit(.minutes(1))) struct RecordingTests {
    let start = Date()
    let first = ExchangeID(rawValue: 1)

    func events(_ id: UInt64, body: String = "") -> [ProxyEvent] {
        let exchange = ExchangeID(rawValue: id)
        let head = RequestHead(
            method: "GET", scheme: "http", host: "api.weatherly.dev", port: 80, target: "/v2/forecast")
        let response = ResponseHead(status: 200, reason: "OK", headers: ["Content-Type": "text/plain"])
        var events: [ProxyEvent] = [
            .requestHead(exchange, ConnectionID(rawValue: 1), head, at: start),
            .requestEnd(exchange, at: start),
            .responseHead(exchange, response, at: start),
        ]
        if !body.isEmpty {
            events.append(.responseBody(exchange, Data(body.utf8)))
        }
        events.append(.responseEnd(exchange, at: start))
        return events
    }

    /// Records the events in one go, so no save comes between them, however long a busy
    /// machine takes to run the test.
    func record(_ events: [ProxyEvent], in session: isolated CaptureSession) {
        for event in events {
            session.record(event)
        }
    }

    /// The summaries in the next update the session publishes.
    func nextUpdate(_ changes: inout AsyncStream<SessionChange>.Iterator) async -> [ExchangeSummary]? {
        while let change = await changes.next() {
            if case .updated(let summaries, _) = change { return summaries }
        }
        return nil
    }

    @Test func savesTrafficBeforeTellingTheInterface() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        await record(events(1, body: "partly cloudy"), in: session)

        #expect(await nextUpdate(&changes)?.map(\.id) == [first])
        let exchange = await session.exchange(first)
        #expect(exchange?.state == .completed)
        #expect(exchange?.responseBody == Data("partly cloudy".utf8))
        #expect(await session.search("CLOUDY") == [first])
    }

    @Test func clearingAlsoDropsTrafficNotSavedYet() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        await record(events(1), in: session)
        await session.clear()
        await record(events(2), in: session)

        #expect(await nextUpdate(&changes)?.map(\.id) == [ExchangeID(rawValue: 2)])
        #expect(try await store.summaries().map(\.id) == [ExchangeID(rawValue: 2)])
    }

    @Test func keepsPinnedTrafficWhenCleared() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        await record(events(1) + events(2), in: session)
        _ = await nextUpdate(&changes)
        await session.annotate(first, with: Annotation(isPinned: true))
        await session.clear()

        #expect(try await store.summaries().map(\.id) == [first])
        // After the clear, the interface hears about what was kept.
        var cleared = false
        while let change = await changes.next() {
            if case .cleared = change {
                cleared = true
            } else if cleared, case .updated(let summaries, _) = change {
                #expect(summaries.map(\.id) == [first])
                #expect(summaries.first?.annotation.isPinned == true)
                break
            }
        }
    }

    @Test func savesKeepAnAnnotationMadeWhileInProgress() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        let all = events(1)
        await record(Array(all.dropLast()), in: session)
        _ = await nextUpdate(&changes)
        let annotation = Annotation(color: .blue, comment: "Slow on Wi-Fi")
        await session.annotate(first, with: annotation)
        await record([all.last!], in: session)

        var latest: ExchangeSummary?
        while latest?.state != .completed, let summaries = await nextUpdate(&changes) {
            latest = summaries.last
        }
        #expect(latest?.annotation == annotation)
        #expect(try await store.summary(first)?.annotation == annotation)
    }

    @Test func recordsRequestsItSendsWithoutCapturing() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        let reqly = Source(name: "Reqly", bundleID: "net.reqly.Reqly", path: "/Applications/Reqly.app")
        // Nothing listens there, so it fails fast, and needs no server.
        let request = OutgoingRequest(method: "GET", url: URL(string: "http://127.0.0.1:9/")!)
        let id = await session.send(request, from: reqly)

        var latest: ExchangeSummary?
        while latest?.state.isFinished != true, let summaries = await nextUpdate(&changes) {
            latest = summaries.last { $0.id == id } ?? latest
        }
        #expect(latest?.source == reqly)
        #expect(latest?.method == "GET")
        guard case .failed(.cannotConnect) = latest?.state else {
            Issue.record("Expected a failure to connect, got \(String(describing: latest?.state))")
            return
        }
        #expect(try await store.summary(id)?.source == reqly)
        // The engine marks it as one Reqly sent itself.
        #expect(try await store.exchange(id)?.sentByReqly == true)
    }

    @Test func showsTheTrafficAStoreAlreadyHolds() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let capturing = CaptureSession(store: store)
        await record(events(1) + events(2), in: capturing)
        while try await store.summaries().count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }

        // Another session on the same store, as when a saved session opens.
        let opened = CaptureSession(store: store)
        var changes = opened.changes.makeAsyncIterator()
        await opened.publishStoredTraffic()
        #expect(await nextUpdate(&changes)?.map(\.id) == [first, ExchangeID(rawValue: 2)])
    }

    @Test func dropsTheOldestExchangesPastTheLimit() async throws {
        let store = try temporaryStore(TrafficStore.Limits(exchanges: 2))
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        await record(events(1) + events(2) + events(3), in: session)

        var removed: [ExchangeID] = []
        var kept: [ExchangeID] = []
        while let change = await changes.next() {
            if case .updated(let summaries, let ids) = change, !ids.isEmpty {
                removed = ids
                kept = summaries.map(\.id)
                break
            }
        }
        // In the same change as the exchanges that took their place.
        #expect(removed == [first])
        #expect(kept == [ExchangeID(rawValue: 2), ExchangeID(rawValue: 3)])
    }

    @Test func keepsBodyBytesOnlyUpToTheLimit() async throws {
        let store = try temporaryStore(TrafficStore.Limits(bodySize: 4))
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        await record(events(1, body: "partly cloudy"), in: session)

        _ = await nextUpdate(&changes)
        let exchange = await session.exchange(first)
        #expect(exchange?.responseBody == Data("part".utf8))
        #expect(exchange?.bytesReceived == 13)
    }

    @Test func creditsTrafficToTheAppThatSentIt() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let safari = Source(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app")
        let session = CaptureSession(
            store: store, findOrigin: { client, _ in client.port == 50_000 ? Origin(source: safari) : nil })
        var changes = session.changes.makeAsyncIterator()
        let client = ClientAddress(ip: "127.0.0.1", port: 50_000)
        await session.record(.connectionOpened(ConnectionID(rawValue: 1), client: client, at: start))
        await record(events(1), in: session)

        // The lookup may answer before or after the exchange is first saved.
        var credited: ExchangeSummary?
        while credited == nil, let summaries = await nextUpdate(&changes) {
            credited = summaries.first { $0.id == first && $0.source != nil }
        }
        #expect(credited?.source == safari)
        #expect(await session.exchange(first)?.source == safari)
    }

    @Test func creditsTrafficToTheDeviceThatSentIt() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let phone = Device(id: "ip:192.168.1.23", kind: .network, name: "192.168.1.23", address: "192.168.1.23")
        let session = CaptureSession(
            store: store, findOrigin: { client, _ in client.ip == "192.168.1.23" ? Origin(device: phone) : nil })
        var changes = session.changes.makeAsyncIterator()
        let client = ClientAddress(ip: "192.168.1.23", port: 50_100)
        await session.record(.connectionOpened(ConnectionID(rawValue: 1), client: client, at: start))
        await record(events(1), in: session)

        var credited: ExchangeSummary?
        while credited == nil, let summaries = await nextUpdate(&changes) {
            credited = summaries.first { $0.id == first && $0.device != nil }
        }
        #expect(credited?.device == phone)
        #expect(credited?.source == nil)

        // Naming the device names it in the traffic it sent, saved or not.
        await session.renameDevice(phone.id, to: "Parsa's iPhone")
        await session.flush()
        #expect(await session.exchange(first)?.device?.name == "Parsa's iPhone")
        #expect(try await store.summaries().first?.device?.name == "Parsa's iPhone")
    }

    @Test func triesAScriptOnACapturedExchange() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        let head = RequestHead(
            method: "GET", scheme: "https", host: "api.weatherly.dev", port: 443, target: "/v1/forecast")
        await record(
            [
                .requestHead(first, ConnectionID(rawValue: 1), head, at: start),
                .requestEnd(first, at: start),
                .responseHead(
                    first, ResponseHead(status: 200, reason: "OK", headers: ["Content-Type": "application/json"]),
                    at: start),
                .responseBody(first, Data(#"{"temperature":14.2}"#.utf8)),
                .responseEnd(first, at: start),
            ],
            in: session
        )
        let code = """
            function onRequest(request) { request.headers.set("X-Debug", "1"); console.log(request.url) }
            function onResponse(response) { response.json.temperature = 99 }
            """
        let trials = await session.tryScript(code, on: first)
        #expect(
            trials == [
                ScriptTrial(
                    part: .request, detail: "Changed 1 header.", logs: ["https://api.weatherly.dev/v1/forecast"],
                    failed: false),
                ScriptTrial(part: .response, detail: "Changed the body.", logs: [], failed: false),
            ])
        #expect(await session.checkScript(code) == nil)
        #expect(await session.checkScript("function onRequest( {")?.hasPrefix("SyntaxError") == true)
    }

    @Test func keepsEachWebSocketMessageInOrder() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        let head = RequestHead(method: "GET", scheme: "http", host: "chat.weatherly.dev", port: 80, target: "/live")
        let hello = WebSocketMessage(direction: .sent, kind: .text, time: start + 1, data: Data("hello".utf8))
        let reply = WebSocketMessage(direction: .received, kind: .text, time: start + 2, data: Data("hi".utf8))
        let close = WebSocketMessage(
            direction: .sent, kind: .close, time: start + 3, data: Data(), size: 2, closeCode: 1000)
        await record(
            [
                .requestHead(first, ConnectionID(rawValue: 1), head, at: start),
                .requestEnd(first, at: start),
                .responseHead(first, ResponseHead(status: 101, reason: "Switching Protocols"), at: start),
                .responseEnd(first, at: start),
                .tunnelOpened(first, at: start),
                .webSocketMessage(first, hello),
                .webSocketMessage(first, reply),
                .webSocketMessage(first, close),
            ],
            in: session
        )
        #expect(await session.messages(of: first) == [hello, reply, close])
        let summary = try await store.summary(first)
        #expect(summary?.messageCount == 3)
        #expect(summary?.bytesSent == 7)
        #expect(summary?.bytesReceived == 2)
    }

    /// After a switch to WebSocket, a finished exchange opens again as a tunnel.
    @Test func followsAnExchangeThatSwitchesProtocols() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        // The traffic happened a minute ago, longer than finished exchanges stay, as when
        // recording falls behind it on a busy Mac. The exchange is still there for the switch.
        let start = self.start - 60
        let head = RequestHead(method: "GET", scheme: "http", host: "chat.weatherly.dev", port: 80, target: "/live")
        await record(
            [
                .requestHead(first, ConnectionID(rawValue: 1), head, at: start),
                .requestEnd(first, at: start),
                .responseHead(first, ResponseHead(status: 101, reason: "Switching Protocols"), at: start),
                .responseEnd(first, at: start),
            ],
            in: session
        )
        #expect(await nextUpdate(&changes)?.first?.state == .completed)

        await session.record(.tunnelOpened(first, at: start + 0.1))
        #expect(await nextUpdate(&changes)?.first?.state == .open)

        await session.record(.tunnelClosed(first, bytesSent: 10, bytesReceived: 20, at: start + 5))
        #expect(await nextUpdate(&changes)?.first?.state == .completed)
        #expect(await session.exchange(first)?.timing.ended == start + 5)
    }

    /// Once the traffic is past a finished exchange's grace period, the session lets go of it,
    /// so a late event for it changes nothing.
    @Test func letsGoOfFinishedExchanges() async throws {
        let store = try temporaryStore()
        defer { store.discard() }
        let session = CaptureSession(store: store)
        var changes = session.changes.makeAsyncIterator()
        await record(events(1), in: session)
        _ = await nextUpdate(&changes)

        let later = start + CaptureSession.finishedGracePeriod + 1
        let head = RequestHead(method: "GET", scheme: "http", host: "api.weatherly.dev", port: 80, target: "/v2/alerts")
        await session.record(.requestHead(ExchangeID(rawValue: 2), ConnectionID(rawValue: 1), head, at: later))
        _ = await nextUpdate(&changes)
        await session.record(.tunnelOpened(first, at: later))
        await session.flush()
        #expect(try await store.summary(first)?.state == .completed)
    }
}
