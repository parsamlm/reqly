import Foundation
import ReqlyModel
import Testing
import TrafficStore

/// Builds exchanges for the tests, and stores in temporary folders.
struct Fixtures {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func id(_ value: UInt64) -> ExchangeID { ExchangeID(rawValue: value) }

    static func exchange(
        _ id: UInt64,
        target: String = "/v2/forecast",
        state: ExchangeState = .completed,
        requestHeaders: Headers = [:],
        responseHeaders: Headers = ["Content-Type": "application/json"]
    ) -> Exchange {
        var exchange = Exchange(
            id: Self.id(id),
            connectionID: ConnectionID(rawValue: 1),
            kind: .http,
            request: RequestHead(
                method: "GET", scheme: "https", host: "api.weatherly.dev", port: 443, target: target,
                headers: requestHeaders
            ),
            started: start + Double(id)
        )
        exchange.response = ResponseHead(status: 200, reason: "OK", headers: responseHeaders)
        exchange.state = state
        exchange.timing.responseStarted = start + Double(id) + 0.1
        exchange.timing.ended = state.isFinished ? start + Double(id) + 0.25 : nil
        return exchange
    }

    static func chunk(_ id: UInt64, _ part: BodyPart, _ text: String) -> BodyChunk {
        BodyChunk(exchange: Self.id(id), part: part, data: Data(text.utf8))
    }

    static func temporaryFolder() -> URL {
        URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func store(_ limits: TrafficStore.Limits = TrafficStore.Limits()) throws -> TrafficStore {
        try TrafficStore(directory: temporaryFolder(), limits: limits)
    }

    static func bodyFiles(of store: TrafficStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: store.directory.appending(path: "bodies").path(percentEncoded: false)
        ).sorted()
    }
}

@Suite(.timeLimit(.minutes(1))) struct TrafficStoreTests {
    typealias F = Fixtures

    @Test func savesAnExchangeAndItsBodiesAsTheyArrive() async throws {
        let store = try F.store()
        defer { store.discard() }
        var weather = F.exchange(1, state: .receiving)
        weather.bytesSent = 2
        weather.bytesReceived = 4
        try await store.write([weather], chunks: [F.chunk(1, .request, "{}"), F.chunk(1, .response, "{\"t\"")])

        weather.state = .completed
        weather.bytesReceived = 8
        try await store.write([weather], chunks: [F.chunk(1, .response, ":14}")])

        var expected = weather
        expected.requestBody = Data("{}".utf8)
        expected.responseBody = Data("{\"t\":14}".utf8)
        #expect(try await store.exchange(F.id(1)) == expected)
        #expect(try await store.summaries() == [weather.summary])
        #expect(try await store.exchange(F.id(2)) == nil)
    }

    @Test func savesHowEachExchangeReachedTheServer() async throws {
        let store = try F.store()
        defer { store.discard() }
        var first = F.exchange(1)
        first.timing.connectStarted = F.start + 1.001
        first.timing.resolved = F.start + 1.013
        first.timing.connected = F.start + 1.031
        first.timing.secured = F.start + 1.062
        first.timing.requestSent = F.start + 1.063
        first.remoteAddress = "203.0.113.24:443"
        first.tlsVersion = "1.3"
        var second = F.exchange(2)
        second.timing.requestSent = F.start + 2.001
        second.remoteAddress = "203.0.113.24:443"
        second.tlsVersion = "1.3"
        second.reusedConnection = true
        second.serverProtocol = "HTTP/2"
        second.responseTrailers = ["grpc-status": "0", "grpc-message": "fine"]
        second.upstreamProxy = "proxy.example.com:8080"
        second.reverseProxy = "localhost:8080"
        second.clientCertificate = "Weatherly Staging"
        second.sentByReqly = true
        try await store.write([first, second], chunks: [])

        #expect(try await store.exchange(F.id(1)) == first)
        #expect(try await store.exchange(F.id(2)) == second)
        #expect(try await store.summary(F.id(2))?.grpcStatus == 0)
    }

    @Test func keepsEachWebSocketMessage() async throws {
        let store = try F.store(TrafficStore.Limits(messageSize: 4))
        defer { store.discard() }
        var live = F.exchange(1, state: .receiving)
        live.messageCount = 2
        let hello = WebSocketMessage(direction: .sent, kind: .text, time: F.start + 2, data: Data("hello".utf8))
        let ping = WebSocketMessage(direction: .received, kind: .ping, time: F.start + 3, data: Data())
        try await store.write(
            [live], chunks: [],
            messages: [StoredMessage(exchange: F.id(1), number: 0, message: hello)]
                + [StoredMessage(exchange: F.id(1), number: 1, message: ping)]
                // Messages of an exchange the store doesn't have are left out.
                + [StoredMessage(exchange: F.id(9), number: 0, message: ping)])
        var kept = hello
        kept.data = Data("hell".utf8)
        #expect(try await store.messages(of: F.id(1)) == [kept, ping])
        #expect(try await store.messages(of: F.id(1), from: 1) == [ping])
        #expect(try await store.messages(of: F.id(9)).isEmpty)
        #expect(try await store.summary(F.id(1))?.messageCount == 2)
        // The messages go with their exchange.
        try await store.removeUnpinned()
        #expect(try await store.messages(of: F.id(1)).isEmpty)
    }

    @Test func savesTheRulesThatActedOnAnExchange() async throws {
        let store = try F.store()
        defer { store.discard() }
        var exchange = F.exchange(1)
        exchange.appliedRules = [
            AppliedRule(name: "Staging", kind: .mapRemote, detail: "Sent to https://staging.weatherly.dev/v2/forecast"),
            AppliedRule(name: "No cache", kind: .rewrite, detail: "Removed the Cache-Control header."),
        ]
        try await store.write([exchange, F.exchange(2)], chunks: [])

        #expect(try await store.exchange(F.id(1))?.appliedRules == exchange.appliedRules)
        #expect(try await store.exchange(F.id(2))?.appliedRules == [])
    }

    @Test func savesTheDeviceEachExchangeCameFrom() async throws {
        let store = try F.store()
        defer { store.discard() }
        let phone = Device(id: "mac:a4:83:e7:12:34:56", kind: .network, name: "192.168.1.23", address: "192.168.1.23")
        let simulator = Device(id: "540A509F-6929-46AA-8C7B-4F06A17B446B", kind: .simulator, name: "iPhone 17 Pro")
        var first = F.exchange(1)
        first.device = phone
        var second = F.exchange(2)
        second.device = simulator
        try await store.write([first, second, F.exchange(3)], chunks: [])

        #expect(try await store.exchange(F.id(1)) == first)
        #expect(try await store.summaries().map(\.device) == [phone, simulator, nil])

        try await store.renameDevice(phone.id, to: "Parsa's iPhone")
        #expect(try await store.exchange(F.id(1))?.device?.name == "Parsa's iPhone")
        #expect(try await store.summary(F.id(2))?.device == simulator)
    }

    @Test func movesABodyToAFileOnceItOutgrowsTheDatabase() async throws {
        let store = try F.store(TrafficStore.Limits(inlineBodySize: 8))
        defer { store.discard() }
        try await store.write([F.exchange(1, state: .receiving)], chunks: [F.chunk(1, .response, "12345")])
        #expect(try F.bodyFiles(of: store).isEmpty)

        try await store.write([F.exchange(1, state: .receiving)], chunks: [F.chunk(1, .response, "67890")])
        #expect(try F.bodyFiles(of: store) == ["1-response"])

        try await store.write([F.exchange(1)], chunks: [F.chunk(1, .response, "abc")])
        #expect(try await store.exchange(F.id(1))?.responseBody == Data("1234567890abc".utf8))
    }

    @Test func keepsEachBodyUpToTheLimit() async throws {
        let store = try F.store(TrafficStore.Limits(bodySize: 10, inlineBodySize: 4))
        defer { store.discard() }
        try await store.write(
            [F.exchange(1, state: .receiving)],
            chunks: [F.chunk(1, .response, "12345678"), F.chunk(1, .response, "90abcdef")]
        )
        try await store.write([F.exchange(1)], chunks: [F.chunk(1, .response, "more")])
        #expect(try await store.exchange(F.id(1))?.responseBody == Data("1234567890".utf8))
    }

    @Test func savesWhatSentEachExchange() async throws {
        let store = try F.store()
        defer { store.discard() }
        let safari = Source(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app")
        let curl = Source(name: "curl", path: "/usr/bin/curl")
        var exchanges = (1...4).map { F.exchange(UInt64($0)) }
        exchanges[0].source = safari
        exchanges[1].source = curl
        exchanges[2].source = safari
        try await store.write(exchanges)
        #expect(try await store.summaries().map(\.source) == [safari, curl, safari, nil])
        #expect(try await store.exchange(F.id(2))?.source == curl)

        // An exchange whose source is found later gets it.
        exchanges[3].source = curl
        try await store.write([exchanges[3]])
        #expect(try await store.exchange(F.id(4))?.source == curl)
    }

    @Test func findsTextInURLsHeadersAndBodies() async throws {
        let store = try F.store()
        defer { store.discard() }
        // "hello", compressed with gzip.
        let gzip = Data([
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x86,
            0xa6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00,
        ])
        let exchanges = [
            F.exchange(1, target: "/v2/forecast?city=amsterdam"),
            F.exchange(2, requestHeaders: ["Authorization": "Bearer Secret-Token"]),
            F.exchange(3, responseHeaders: ["Content-Type": "text/plain", "Content-Encoding": "gzip"]),
            F.exchange(4, responseHeaders: ["Content-Type": "image/png"]),
            F.exchange(5, state: .receiving),
        ]
        try await store.write(
            exchanges,
            chunks: [
                BodyChunk(exchange: F.id(3), part: .response, data: gzip),
                F.chunk(4, .response, "hello, but in a picture"),
                F.chunk(5, .response, "hello, still arriving"),
            ]
        )

        #expect(try await store.search("AMSTERDAM") == [F.id(1)])
        #expect(try await store.search("secret-token") == [F.id(2)])
        // The unpacked body matches. Images aren't text, and a body still arriving isn't searched yet.
        #expect(try await store.search("hello") == [F.id(3)])
        #expect(try await store.search("he") == [])

        try await store.write([F.exchange(5)])
        #expect(try await store.search("hello") == [F.id(3), F.id(5)])
    }

    @Test func dropsTheOldestFinishedExchangesPastTheLimit() async throws {
        let store = try F.store(TrafficStore.Limits(exchanges: 3, inlineBodySize: 2))
        defer { store.discard() }
        // The oldest exchange is still open, so it stays.
        try await store.write([F.exchange(1, state: .open), F.exchange(2), F.exchange(3)])
        try await store.write([], chunks: [F.chunk(2, .response, "too big to stay in the database")])
        #expect(try F.bodyFiles(of: store) == ["2-response"])

        let removed = try await store.write([F.exchange(4), F.exchange(5)])
        #expect(removed == [F.id(2), F.id(3)])
        #expect(try await store.summaries().map(\.id) == [F.id(1), F.id(4), F.id(5)])
        #expect(try await store.exchange(F.id(2)) == nil)
        #expect(try F.bodyFiles(of: store).isEmpty)
        #expect(try await store.search("weatherly") == [F.id(1), F.id(4), F.id(5)])
    }

    @Test func keepsAnnotationsWhenTrafficIsSavedAgain() async throws {
        let store = try F.store()
        defer { store.discard() }
        try await store.write([F.exchange(1, state: .receiving)])
        let annotation = Annotation(isPinned: true, color: .orange, comment: "Rate limited here")
        try await store.annotate(F.id(1), with: annotation)
        // Capture saves the exchange again as it finishes, with no annotation of its own.
        try await store.write([F.exchange(1)])

        #expect(try await store.exchange(F.id(1))?.annotation == annotation)
        #expect(try await store.summary(F.id(1))?.annotation == annotation)
        #expect(try await store.summaries().map(\.annotation) == [annotation])
        try await store.annotate(F.id(1), with: Annotation())
        #expect(try await store.summary(F.id(1))?.annotation == Annotation())
    }

    @Test func keepsPinnedExchangesWhenCleared() async throws {
        let store = try F.store(TrafficStore.Limits(inlineBodySize: 2))
        defer { store.discard() }
        try await store.write(
            [F.exchange(1), F.exchange(2)],
            chunks: [F.chunk(1, .response, "a body in a file"), F.chunk(2, .response, "another body in a file")])
        try await store.annotate(F.id(2), with: Annotation(isPinned: true))

        try await store.removeUnpinned()
        #expect(try await store.summaries().map(\.id) == [F.id(2)])
        #expect(try await store.search("weatherly") == [F.id(2)])
        #expect(try await store.exchange(F.id(2))?.responseBody == Data("another body in a file".utf8))
        #expect(try F.bodyFiles(of: store).count == 1)
    }

    @Test func keepsPinnedExchangesPastTheLimit() async throws {
        let store = try F.store(TrafficStore.Limits(exchanges: 2))
        defer { store.discard() }
        try await store.write([F.exchange(1), F.exchange(2)])
        try await store.annotate(F.id(1), with: Annotation(isPinned: true))

        #expect(try await store.write([F.exchange(3)]) == [F.id(2)])
        #expect(try await store.summaries().map(\.id) == [F.id(1), F.id(3)])
    }

    @Test func clearsTheSession() async throws {
        let store = try F.store(TrafficStore.Limits(inlineBodySize: 2))
        defer { store.discard() }
        try await store.write([F.exchange(1), F.exchange(2)], chunks: [F.chunk(1, .response, "a body in a file")])

        try await store.removeUnpinned()
        #expect(try await store.summaries().isEmpty)
        #expect(try await store.search("weatherly").isEmpty)
        #expect(try F.bodyFiles(of: store).isEmpty)

        try await store.write([F.exchange(3)])
        #expect(try await store.summaries().map(\.id) == [F.id(3)])
    }

    @Test func newSessionsDeleteOnlyTheOnesNobodyHolds() throws {
        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var first: TrafficStore? = try TrafficStore.newSession(in: root)
        let firstFolder = try #require(first?.directory)
        let second = try TrafficStore.newSession(in: root)
        #expect(FileManager.default.fileExists(atPath: firstFolder.path(percentEncoded: false)))

        // Letting go of a store is what a crash does to it: its session is left behind.
        first = nil
        let third = try TrafficStore.newSession(in: root)
        #expect(!FileManager.default.fileExists(atPath: firstFolder.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: second.directory.path(percentEncoded: false)))

        third.discard()
        #expect(!FileManager.default.fileExists(atPath: third.directory.path(percentEncoded: false)))
    }

    /// The speed check from ARCHITECTURE.md: a session of 100,000 requests stays quick to save,
    /// search and read.
    @Test func keepsUpWithAHundredThousandExchanges() async throws {
        let store = try F.store()
        defer { store.discard() }
        let body = Data(#"{"temperature":14,"city":"Amsterdam","wind":"light"}"#.utf8)
        let clock = ContinuousClock()
        var batches: [Duration] = []
        for batch in 0..<100 {
            let exchanges = (1...1000).map { F.exchange(UInt64(batch * 1000 + $0)) }
            let chunks = exchanges.map { BodyChunk(exchange: $0.id, part: .response, data: body) }
            batches.append(try await clock.measure { try await store.write(exchanges, chunks: chunks) })
        }
        try await store.write([F.exchange(100_001, requestHeaders: ["X-Trace": "needle-in-a-haystack"])])

        var found: Set<ExchangeID> = []
        var read: Exchange?
        var searches: [Duration] = []
        var reads: [Duration] = []
        for _ in 0..<5 {
            searches.append(try await clock.measure { found = try await store.search("needle") })
            reads.append(try await clock.measure { read = try await store.exchange(F.id(50_000)) })
        }
        #expect(found == [F.id(100_001)])
        #expect(read?.responseBody == body)
        #expect(try await store.summaries().count == 100_000)
        // On CI, the other tests running at the same time slow some batches and tries down several
        // times over, which says nothing about the store. So writing counts the median batch of
        // 1,000, and searching and reading their best of five tries.
        let writing = batches.sorted()[batches.count / 2]
        let searching = searches.min()!
        let reading = reads.min()!
        print(
            "100,000 exchanges: writing \(batches.reduce(.zero, +)), \(writing) per 1,000 at the median,",
            "searching \(searching), reading \(reading)")
        // Even a debug build on a slow CI machine saves 4,000 exchanges a second, far more than
        // a busy Mac sends.
        #expect(writing < .milliseconds(250))
        #expect(searching < .milliseconds(100))
        #expect(reading < .milliseconds(50))
    }
}
