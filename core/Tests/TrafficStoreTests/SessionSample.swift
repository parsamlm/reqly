import Foundation
import ReqlyModel
import TrafficStore

/// A session with one of each kind of thing a session holds, which Reqly for Mac 1.0 and Reqly for
/// Windows each saved once, into `Sessions/`. `SessionCompatibilityTests` opens those files and
/// checks they read as this session does, so a session saved on one system opens on the other.
///
/// It uses only what Reqly for Mac 1.0's core has, so the same file built against that core wrote
/// `Sessions/Mac 1.0.reqly`.
enum SessionSample {
    static let start = Date(timeIntervalSince1970: 1_791_000_000)

    static func id(_ value: UInt64) -> ExchangeID { ExchangeID(rawValue: value) }

    /// A completed HTTPS exchange, with every step of its timing.
    static func exchange(
        _ number: UInt64, method: String = "GET", host: String = "api.weatherly.dev", target: String,
        requestHeaders: Headers = [:], status: Int = 200, reason: String = "OK",
        responseHeaders: Headers = ["Content-Type": "application/json"], requestBody: String = "",
        responseBody: Data = Data()
    ) -> Exchange {
        let started = start + Double(number)
        var exchange = Exchange(
            id: id(number), connectionID: ConnectionID(rawValue: number), kind: .http,
            request: RequestHead(
                method: method, scheme: "https", host: host, port: 443, target: target, headers: requestHeaders),
            started: started)
        exchange.requestBody = Data(requestBody.utf8)
        exchange.response = ResponseHead(status: status, reason: reason, headers: responseHeaders)
        exchange.responseBody = responseBody
        exchange.bytesSent = Int64(exchange.requestBody.count)
        exchange.bytesReceived = Int64(responseBody.count)
        exchange.state = .completed
        exchange.timing.requestEnded = started + 0.001
        exchange.timing.connectStarted = started + 0.002
        exchange.timing.resolved = started + 0.0625
        exchange.timing.connected = started + 0.125
        exchange.timing.secured = started + 0.25
        exchange.timing.requestSent = started + 0.25
        exchange.timing.responseStarted = started + 0.5
        exchange.timing.ended = started + 0.75
        exchange.remoteAddress = "203.0.113.24:443"
        exchange.tlsVersion = "1.3"
        exchange.serverProtocol = "HTTP/2"
        exchange.source = weatherly
        return exchange
    }

    static let weatherly = Source(
        name: "Weatherly", bundleID: "dev.weatherly.app", path: "/Applications/Weatherly.app")
    static let edge = Source(
        name: "Microsoft Edge", path: #"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"#)

    static func exchanges() -> [Exchange] {
        var forecast = exchange(
            1, target: "/v2/forecast?city=Lisbon&days=3",
            requestHeaders: ["Accept": "application/json", "Authorization": "Bearer secret-token"],
            responseHeaders: ["Content-Type": "application/json", "Set-Cookie": "session=secret-cookie"],
            responseBody: Data(#"{"city":"Lisbon","days":[{"sky":"clear"},{"sky":"rain"}]}"#.utf8))
        forecast.annotation = Annotation(isPinned: true, color: .green, comment: "Looks right")

        // Persian in the URL, a header, the body and a comment, to check every system reads UTF-8 alike.
        var tehran = exchange(
            2, method: "POST", target: "/v2/search?q=%D8%AA%D9%87%D8%B1%D8%A7%D9%86",
            requestHeaders: ["Content-Type": "application/x-www-form-urlencoded", "X-City": "تهران"],
            requestBody: "city=%D8%AA%D9%87%D8%B1%D8%A7%D9%86&units=metric",
            responseBody: Data(#"{"name":"تهران","country":"ایران"}"#.utf8))
        tehran.annotation = Annotation(color: .red, comment: "شهر تهران")
        tehran.source = edge

        // Packed with gzip as it came: "hello, Reqly".
        let gzip = Data([
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51,
            0x08, 0x4a, 0x2d, 0xcc, 0xa9, 0x04, 0x00, 0xaa, 0xe0, 0x77, 0xf8, 0x0c, 0x00, 0x00, 0x00,
        ])
        let packed = exchange(
            3, target: "/v2/greeting",
            responseHeaders: ["Content-Type": "text/plain; charset=utf-8", "Content-Encoding": "gzip"],
            responseBody: gzip)

        // Past `limits`, so it's in a file of its own until the session is saved, as long bodies are.
        let points = (0..<1_000).map { #"{"x":\#($0)}"# }.joined(separator: ",")
        let radar = exchange(4, target: "/v2/radar.json", responseBody: Data("[\(points)]".utf8))

        // A 2 × 2 picture, all sunny yellow.
        let png =
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR42mP8f4SBgYGBiYGBgYGBAQAWTQHHbkSWbAAAAABJRU5ErkJggg=="
        let icon = exchange(
            5, target: "/icons/sun.png", responseHeaders: ["Content-Type": "image/png"],
            responseBody: Data(base64Encoded: png) ?? Data())

        // A connection Reqly didn't decrypt.
        var tunnel = Exchange(
            id: id(6), connectionID: ConnectionID(rawValue: 6), kind: .tunnel,
            request: RequestHead(
                method: "CONNECT", scheme: "https", host: "maps.weatherly.dev", port: 443,
                target: "maps.weatherly.dev:443"),
            started: start + 6)
        tunnel.state = .completed
        tunnel.bytesSent = 1_203
        tunnel.bytesReceived = 48_119
        tunnel.timing.ended = start + 9.5
        tunnel.source = weatherly

        var unreachable = Exchange(
            id: id(7), connectionID: ConnectionID(rawValue: 7), kind: .http,
            request: RequestHead(method: "GET", scheme: "http", host: "weather.invalid", port: 80, target: "/v2/now"),
            started: start + 7)
        unreachable.state = .failed(.cannotConnect("The name weather.invalid didn't resolve."))
        unreachable.timing.ended = start + 7.125

        var blocked = exchange(8, host: "ads.weatherly.dev", target: "/banner")
        blocked.response = nil
        blocked.timing.responseStarted = nil
        blocked.state = .failed(.blocked(rule: "No ads"))
        blocked.appliedRules = [AppliedRule(name: "No ads", kind: .block, detail: "Closed the connection.")]

        var mapped = exchange(
            9, target: "/v2/alerts", responseBody: Data(#"{"alerts":[]}"#.utf8))
        mapped.appliedRules = [
            AppliedRule(name: "Quiet alerts", kind: .mapLocal, detail: "Answered with alerts.json."),
            AppliedRule(name: "Mark it", kind: .rewrite, detail: "Set the header X-Reqly."),
        ]
        mapped.response?.headers = ["Content-Type": "application/json", "X-Reqly": "rewritten"]

        var scripted = exchange(10, target: "/v2/hourly", responseBody: Data("[]".utf8))
        scripted.appliedRules = [AppliedRule(name: "Log it", kind: .script, detail: "Changed 1 header.")]
        scripted.scriptOutput = [
            ScriptOutput(rule: "Log it", part: .request, lines: ["GET https://api.weatherly.dev/v2/hourly"]),
            ScriptOutput(rule: "Log it", part: .response, lines: ["200", "application/json"]),
        ]

        var socket = exchange(
            11, host: "live.weatherly.dev", target: "/socket",
            requestHeaders: ["Connection": "Upgrade", "Upgrade": "websocket"], status: 101,
            reason: "Switching Protocols", responseHeaders: ["Connection": "Upgrade", "Upgrade": "websocket"])
        socket.messageCount = 3

        var grpc = exchange(
            12, method: "POST", host: "grpc.weatherly.dev", target: "/weather.v1.Forecasts/Get",
            requestHeaders: ["Content-Type": "application/grpc"], responseHeaders: ["Content-Type": "application/grpc"],
            requestBody: "", responseBody: Data([0x00, 0x00, 0x00, 0x00, 0x08, 0x0a, 0x06]) + Data("Tehran".utf8))
        grpc.responseTrailers = ["grpc-status": "0"]

        // From devices: a phone on the network, a simulator, and an Android emulator, with no app of its own.
        var phone = exchange(13, target: "/v2/forecast?city=Tehran")
        phone.device = Device(id: "a4:83:e7:02:34:56", kind: .network, name: "Parsa's iPhone", address: "192.168.1.23")
        phone.source = nil
        var simulator = exchange(14, target: "/v2/forecast?city=Paris")
        simulator.device = Device(id: "4E2F4C35-9B5A-4F6C-9D11-0B4E4C2B9A11", kind: .simulator, name: "iPhone 17 Pro")
        var emulator = exchange(15, target: "/v2/forecast?city=Oslo")
        emulator.device = Device(id: "emulator:Pixel_9", kind: .emulator, name: "Pixel 9")
        emulator.source = nil

        // Sent from the composer, through an upstream proxy, with a client certificate, as a reverse proxy passed it on.
        var composed = exchange(16, method: "PUT", target: "/v2/settings", requestBody: #"{"units":"metric"}"#)
        composed.sentByReqly = true
        composed.source = nil
        composed.upstreamProxy = "proxy.example.com:8080"
        composed.clientCertificate = "Reqly Test Client"
        composed.reverseProxy = "localhost:8080"
        composed.reusedConnection = true
        composed.timing.connectStarted = nil
        composed.timing.resolved = nil
        composed.timing.connected = nil
        composed.timing.secured = nil
        composed.annotation = Annotation(isPinned: true)

        return [
            forecast, tehran, packed, radar, icon, tunnel, unreachable, blocked, mapped, scripted, socket, grpc, phone,
            simulator, emulator, composed,
        ]
    }

    static func messages() -> [ExchangeID: [WebSocketMessage]] {
        [
            id(11): [
                WebSocketMessage(
                    direction: .sent, kind: .text, time: start + 11.5, data: Data(#"{"subscribe":"Lisbon"}"#.utf8)),
                WebSocketMessage(
                    direction: .received, kind: .text, time: start + 12, data: Data(#"{"sky":"clear"}"#.utf8)),
                WebSocketMessage(
                    direction: .received, kind: .close, time: start + 13, data: Data("bye".utf8), closeCode: 1000),
            ]
        ]
    }

    /// A session keeps bodies longer than this in files of their own while it records.
    static let limits = TrafficStore.Limits(inlineBodySize: 4 << 10)

    /// The sample in a session of its own, in `root`.
    static func store(in root: URL) async throws -> TrafficStore {
        try await TrafficStore.newSession(in: root, with: exchanges(), messages: messages(), limits: limits)
    }
}
