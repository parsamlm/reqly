import Foundation
import ReqlyModel
import Testing
import TrafficStore

/// Traffic that looks like an app's, for the benchmarks: a few hosts, paths with IDs, the usual
/// headers, and JSON bodies of 1–4 KB, each different, so the search index takes in as much as it
/// would. The same seed makes the same traffic.
struct BenchmarkTraffic {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    private static let hosts = [
        "api.weatherly.dev", "cdn.weatherly.dev", "auth.example.com", "events.tracker.io", "graph.social.net",
        "images.example.org", "maps.tehran.example", "payments.shop.dev", "telemetry.apple.example", "localhost",
    ]
    private static let words = [
        "forecast", "temperature", "amsterdam", "lisbon", "tehran", "wind", "humidity", "sunrise", "sunset",
        "pressure", "visibility", "cloud", "rain", "snow", "storm", "user", "account", "session", "token",
        "profile", "settings", "items", "orders", "cart", "price", "currency", "amount", "status", "pending",
        "complete", "failed", "retry", "event", "click", "view", "screen", "device", "version", "build",
        "locale", "timezone", "latitude", "longitude", "street", "city", "country", "postal", "image",
        "thumbnail", "width", "height", "format", "quality", "cache", "etag", "created", "updated", "deleted",
    ]
    private static let agents = [
        "Weatherly/4.2 (iPhone; iOS 26.1)", "curl/8.7.1", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        "okhttp/4.12.0",
    ]

    /// SplitMix64.
    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func number(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    private mutating func pick<T>(_ items: [T]) -> T {
        items[number(0...items.count - 1)]
    }

    private mutating func hex(_ count: Int) -> String {
        var text = ""
        while text.count < count {
            text += String(next(), radix: 16)
        }
        return String(text.prefix(count))
    }

    private mutating func uuid() -> String {
        "\(hex(8))-\(hex(4))-\(hex(4))-\(hex(4))-\(hex(12))"
    }

    /// A JSON object of about `size` bytes.
    private mutating func json(about size: Int) -> String {
        var fields: [String] = []
        var length = 2
        while length < size {
            let field: String
            switch number(0...4) {
            case 0: field = "\"id\":\"\(uuid())\""
            case 1: field = "\"\(pick(Self.words))\":\(number(0...99_999))"
            case 2: field = "\"\(pick(Self.words))\":\"\(pick(Self.words)) \(pick(Self.words)) \(hex(6))\""
            case 3: field = "\"\(pick(Self.words))\":{\"\(pick(Self.words))\":\(Double(number(0...9_999)) / 100)}"
            default: field = "\"\(pick(Self.words))\":[\"\(pick(Self.words))\",\"\(pick(Self.words))\"]"
            }
            fields.append(field)
            length += field.utf8.count + 1
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Finished exchanges with these IDs, and their bodies as the chunks a save gets.
    mutating func exchanges(_ ids: ClosedRange<UInt64>) -> ([Exchange], [BodyChunk]) {
        var exchanges: [Exchange] = []
        var chunks: [BodyChunk] = []
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for id in ids {
            let host = pick(Self.hosts)
            let isPost = number(0...3) == 0
            let target =
                "/v\(number(1...3))/\(pick(Self.words))/\(number(1...999_999))?\(pick(Self.words))=\(hex(8))"
                + "&\(pick(Self.words))=\(pick(Self.words))"
            let requestBody = isPost ? json(about: number(100...600)) : ""
            let responseBody = json(about: number(1_000...4_000))
            var requestHeaders: Headers = [
                "Host": host, "User-Agent": pick(Self.agents), "Accept": "application/json",
                "Accept-Language": "en-US,en;q=0.9", "Authorization": "Bearer \(hex(40))",
                "Cookie": "session=\(hex(32)); prefs=\(pick(Self.words))", "X-Request-ID": uuid(),
            ]
            if isPost {
                requestHeaders.append(name: "Content-Type", value: "application/json")
                requestHeaders.append(name: "Content-Length", value: String(requestBody.utf8.count))
            }
            var responseHeaders: Headers = [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": String(responseBody.utf8.count), "Cache-Control": "max-age=\(number(0...3_600))",
                "Date": "Fri, 13 Nov 2026 \(number(10...23)):\(number(10...59)):\(number(10...59)) GMT",
                "ETag": "\"\(hex(16))\"", "Server": "nginx", "X-Trace-ID": hex(24),
            ]
            if number(0...4) == 0 {
                responseHeaders.append(name: "Set-Cookie", value: "session=\(hex(32)); Path=/; HttpOnly")
            }
            let started = start + Double(id) / 100
            var exchange = Exchange(
                id: ExchangeID(rawValue: id), connectionID: ConnectionID(rawValue: id / 4 + 1), kind: .http,
                request: RequestHead(
                    method: isPost ? "POST" : "GET", scheme: host == "localhost" ? "http" : "https", host: host,
                    port: host == "localhost" ? 8080 : 443, target: target, headers: requestHeaders),
                started: started)
            exchange.response = ResponseHead(status: 200, reason: "OK", headers: responseHeaders)
            exchange.state = .completed
            exchange.timing.requestEnded = started + 0.002
            exchange.timing.responseStarted = started + 0.08
            exchange.timing.ended = started + 0.1
            exchange.bytesSent = Int64(requestBody.utf8.count)
            exchange.bytesReceived = Int64(responseBody.utf8.count)
            exchanges.append(exchange)
            if isPost {
                chunks.append(BodyChunk(exchange: exchange.id, part: .request, data: Data(requestBody.utf8)))
            }
            chunks.append(BodyChunk(exchange: exchange.id, part: .response, data: Data(responseBody.utf8)))
        }
        return (exchanges, chunks)
    }
}

/// How long saves take once a session is at its limit, burst after burst. They run only with
/// `REQLY_BENCH=1`, and take minutes, so normal test runs skip them:
///
///     REQLY_BENCH=1 swift test --package-path core -c release -Xswiftc -enable-testing \
///         --filter TrafficStoreBenchmarks
///
/// Each prints lines that start with "bench:".
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["REQLY_BENCH"] == "1"), .serialized,
    .timeLimit(.minutes(60))
) struct TrafficStoreBenchmarks {
    static let clock = ContinuousClock()

    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.0f", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }

    /// The median and the longest of `times`, in ms.
    static func summary(_ times: some Collection<Duration>) -> String {
        let sorted = times.sorted()
        return "\(milliseconds(sorted[sorted.count / 2])) / \(milliseconds(sorted[sorted.count - 1]))"
    }

    /// Fills a session to its limit, then saves ten bursts each of 1, 16, 100 and 1,000 requests,
    /// then 120 saves of 1,000 in a row, as a long burst comes in. At 100,000, that's more than
    /// the whole session replaced.
    @Test(arguments: [300, 100_000]) func savesAtTheLimit(limit: Int) async throws {
        let store = try TrafficStore(
            directory: Fixtures.temporaryFolder(), limits: TrafficStore.Limits(exchanges: limit))
        defer { store.discard() }
        var traffic = BenchmarkTraffic(seed: 2026)
        var nextID: UInt64 = 1

        func save(_ count: Int) async throws -> Duration {
            let (exchanges, chunks) = traffic.exchanges(nextID...nextID + UInt64(count) - 1)
            nextID += UInt64(count)
            return try await Self.clock.measure { try await store.write(exchanges, chunks: chunks) }
        }

        var filling: [Duration] = []
        while nextID <= limit {
            filling.append(try await save(min(1_000, limit - Int(nextID) + 1)))
        }
        print("bench: limit \(limit): filling, median / longest save of \(min(1_000, limit)):", Self.summary(filling))
        for size in [1, 16, 100, 1_000] {
            var times: [Duration] = []
            for _ in 0..<10 {
                times.append(try await save(size))
            }
            print(
                "bench: limit \(limit): 10 saves of \(size) at the limit, median / longest \(Self.summary(times));",
                "each", times.map(Self.milliseconds).joined(separator: " "))
        }
        var long: [Duration] = []
        for _ in 0..<120 {
            long.append(try await save(1_000))
        }
        let tens = stride(from: 0, to: long.count, by: 10).map { Self.summary(long[$0..<$0 + 10]) }
        print(
            "bench: limit \(limit): 120 saves of 1000 at the limit, median / longest of each 10:",
            tens.joined(separator: ", "), "; all \(Self.summary(long))")
        #expect(try await store.summaries().count == limit)

        let files = ["traffic.sqlite", "traffic.sqlite-wal"].map { store.directory.appending(path: $0) }
        let bytes = files.reduce(0) { total, file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
            return total + (attributes?[.size] as? Int ?? 0)
        }
        var searches: [String] = []
        for text in ["tehran", "a1b2c"] {
            var best = Duration.seconds(1_000)
            for _ in 0..<3 {
                best = min(best, try await Self.clock.measure { _ = try await store.search(text) })
            }
            searches.append("\"\(text)\" \(Self.milliseconds(best))")
        }
        print(
            "bench: limit \(limit): database \(bytes >> 20) MB; searching, best of 3 in ms:",
            searches.joined(separator: ", "))
    }
}
