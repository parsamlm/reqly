import Foundation
import ReqlyModel
import Testing

@testable import HAR

@Suite struct CurlCommandTests {
    func request(
        _ method: String = "GET", target: String = "/v2/forecast?city=amsterdam", headers: Headers = [:]
    ) -> RequestHead {
        RequestHead(
            method: method, scheme: "https", host: "api.weatherly.dev", port: 443, target: target, headers: headers)
    }

    @Test func sendsAGetWithItsHeaders() {
        let headers: Headers = ["Host": "api.weatherly.dev", "Accept": "application/json", "Connection": "keep-alive"]
        #expect(
            CurlCommand.make(request(headers: headers), body: Data()) == """
                curl 'https://api.weatherly.dev/v2/forecast?city=amsterdam' \\
                  -H 'Accept: application/json'
                """)
    }

    @Test func sendsTextBodiesAsTheyAreAndQuotesQuotes() {
        let headers: Headers = ["Content-Type": "application/json", "Content-Length": "22"]
        let command = CurlCommand.make(
            request("POST", target: "/v2/events", headers: headers), body: Data(#"{"note":"it's sunny"}"#.utf8))
        #expect(
            command == """
                curl 'https://api.weatherly.dev/v2/events' \\
                  -H 'Content-Type: application/json' \\
                  --data-raw '{"note":"it'\\''s sunny"}'
                """)
    }

    @Test func namesMethodsCurlCannotTellFromTheBody() {
        #expect(CurlCommand.make(request("DELETE"), body: Data()).contains("-X 'DELETE'"))
        #expect(CurlCommand.make(request("PUT"), body: Data("x".utf8)).contains("-X 'PUT'"))
        #expect(CurlCommand.make(request("HEAD"), body: Data()).contains("--head"))
        #expect(!CurlCommand.make(request("POST"), body: Data("x".utf8)).contains("-X"))
    }

    @Test func letsCurlUnpackCompressedResponses() {
        let command = CurlCommand.make(request(headers: ["Accept-Encoding": "gzip, br"]), body: Data())
        #expect(command.hasSuffix("--compressed"))
        #expect(!command.contains("Accept-Encoding"))
    }

    @Test func escapesBytesThatAreNotText() {
        let command = CurlCommand.make(request("POST"), body: Data([0x00, 0xFF, 0x27, 0x41, 0x0A]))
        #expect(command.hasSuffix(#"--data-binary $'\x00\xff\'A\n'"#))
    }
}

@Suite struct HARTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000.25)

    func forecast() -> Exchange {
        var exchange = Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 7), kind: .http,
            request: RequestHead(
                method: "POST", scheme: "https", host: "api.weatherly.dev", port: 443,
                target: "/v2/forecast?city=amsterdam&units=metric",
                headers: [
                    "Content-Type": "application/json", "Authorization": "Bearer secret-token",
                    "Cookie": "session=abc; theme=dark",
                ]),
            started: start)
        exchange.requestBody = Data(#"{"days":3}"#.utf8)
        exchange.response = ResponseHead(
            status: 200, reason: "OK",
            headers: [
                "Content-Type": "application/json", "Content-Encoding": "gzip",
                "Set-Cookie": "session=xyz; Path=/; HttpOnly; Secure",
            ])
        exchange.responseBody = Data(base64Encoded: "H4sIAAAAAAAAA6tWSssvSk1OLC5RslIqLs3Lq1SqBQBEdloJFAAAAA==")!
        exchange.bytesSent = Int64(exchange.requestBody.count)
        exchange.bytesReceived = Int64(exchange.responseBody.count)
        exchange.timing.connectStarted = start + 0.001
        exchange.timing.resolved = start + 0.013
        exchange.timing.connected = start + 0.031
        exchange.timing.secured = start + 0.062
        exchange.timing.requestSent = start + 0.063
        exchange.timing.responseStarted = start + 0.167
        exchange.timing.ended = start + 0.182
        exchange.state = .completed
        exchange.remoteAddress = "203.0.113.24:443"
        exchange.clientCertificate = "Weatherly App"
        exchange.annotation.comment = "Three days ahead"
        return exchange
    }

    func failed() -> Exchange {
        var exchange = Exchange(
            id: ExchangeID(rawValue: 2), connectionID: ConnectionID(rawValue: 8), kind: .http,
            request: RequestHead(method: "GET", scheme: "http", host: "localhost", port: 9, target: "/"),
            started: start + 1)
        exchange.timing.connectStarted = start + 1
        exchange.timing.ended = start + 1.002
        exchange.state = .failed(.cannotConnect("localhost refused the connection."))
        return exchange
    }

    /// Writes the exchanges to a HAR file, and returns the file's JSON and its bytes.
    func export(_ exchanges: [Exchange], options: HARWriter.Options) throws -> ([String: Any], Data) {
        let url = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString).har")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try HARWriter(url: url, options: options, creatorVersion: "1.0")
        for exchange in exchanges {
            try writer.append(exchange)
        }
        try writer.finish()
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json, data)
    }

    @Test func keepsWebSocketMessagesAsChromeDoes() throws {
        let url = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString).har")
        defer { try? FileManager.default.removeItem(at: url) }
        var live = forecast()
        live.response = ResponseHead(status: 101, reason: "Switching Protocols", headers: ["Upgrade": "websocket"])
        live.responseBody = Data()
        let messages = [
            WebSocketMessage(direction: .sent, kind: .text, time: start + 2, data: Data("hello".utf8)),
            WebSocketMessage(direction: .received, kind: .binary, time: start + 3, data: Data([0, 1, 255])),
            WebSocketMessage(direction: .sent, kind: .close, time: start + 4, data: Data("bye".utf8), closeCode: 1000),
        ]
        let writer = try HARWriter(url: url, options: HARWriter.Options(), creatorVersion: "1.0")
        try writer.append(live, messages: messages)
        try writer.finish()
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require(((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first)
        #expect(entry["_resourceType"] as? String == "websocket")
        let written = try #require(entry["_webSocketMessages"] as? [[String: Any]])
        #expect(written.map { $0["type"] as? String } == ["send", "receive", "send"])
        #expect(written.map { $0["opcode"] as? Int } == [1, 2, 8])
        #expect(written[0]["data"] as? String == "hello")
        #expect(written[1]["data"] as? String == "AAH/")
        #expect(written[0]["time"] as? Double == (start + 2).timeIntervalSince1970)

        let read = try #require(try HARReader.entries(from: data).first)
        #expect(read.messages == messages)
        #expect(read.exchange.messageCount == 3)
    }

    @Test func writesEntriesBrowsersCanOpen() throws {
        let (json, _) = try export(
            [forecast(), failed()], options: HARWriter.Options(includesResponseBodies: true, hidesSecrets: false))
        let log = try #require(json["log"] as? [String: Any])
        #expect(log["version"] as? String == "1.2")
        #expect((log["creator"] as? [String: Any])?["name"] as? String == "Reqly")
        let entries = try #require(log["entries"] as? [[String: Any]])
        #expect(entries.count == 2)

        let entry = entries[0]
        let request = try #require(entry["request"] as? [String: Any])
        #expect(request["url"] as? String == "https://api.weatherly.dev/v2/forecast?city=amsterdam&units=metric")
        #expect((request["queryString"] as? [[String: String]])?.map { $0["name"] } == ["city", "units"])
        #expect((request["postData"] as? [String: Any])?["text"] as? String == #"{"days":3}"#)
        #expect((request["cookies"] as? [[String: Any]])?.count == 2)
        let content = try #require((entry["response"] as? [String: Any])?["content"] as? [String: Any])
        // Unpacked from gzip, as HAR keeps bodies.
        #expect(content["text"] as? String == #"{"forecast":"sunny"}"#)
        #expect(content["size"] as? Int == 20)
        let timings = try #require(entry["timings"] as? [String: Double])
        #expect(abs(timings["dns"]! - 12) < 0.01)
        #expect(abs(timings["connect"]! - 49) < 0.01)
        #expect(abs(timings["ssl"]! - 31) < 0.01)
        #expect(abs(timings["wait"]! - 104) < 0.01)
        #expect(abs((entry["time"] as! Double) - 182) < 0.01)
        #expect(entry["serverIPAddress"] as? String == "203.0.113.24")
        #expect(entry["comment"] as? String == "Three days ahead")
        #expect(entry["_clientCertificate"] as? String == "Weatherly App")

        let failure = entries[1]
        #expect((failure["response"] as? [String: Any])?["status"] as? Int == 0)
        #expect((failure["_error"] as? String)?.contains("refused") == true)
        #expect(failure["_clientCertificate"] == nil)
    }

    @Test func hidesSecretsWhenAsked() throws {
        let (_, data) = try export(
            [forecast()], options: HARWriter.Options(includesResponseBodies: false, hidesSecrets: true))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret-token"))
        #expect(!text.contains("session=abc"))
        #expect(!text.contains("xyz"))
        #expect(text.contains(#""value":"(hidden)""#))
        #expect(!text.contains("sunny"))
    }

    @Test func leavesOutEncryptedConnections() throws {
        let tunnel = Exchange(
            id: ExchangeID(rawValue: 3), connectionID: ConnectionID(rawValue: 9), kind: .tunnel,
            request: RequestHead(
                method: "CONNECT", scheme: "https", host: "gateway.icloud.com", port: 443,
                target: "gateway.icloud.com:443"),
            started: start)
        let (json, _) = try export([tunnel], options: HARWriter.Options())
        #expect(((json["log"] as? [String: Any])?["entries"] as? [Any])?.isEmpty == true)
    }

    @Test func readsBackWhatItWrote() throws {
        let (_, data) = try export(
            [forecast(), failed()], options: HARWriter.Options(includesResponseBodies: true, hidesSecrets: false))
        let exchanges = try HARReader.exchanges(from: data)
        #expect(exchanges.count == 2)

        let exchange = exchanges[0]
        #expect(exchange.request.method == "POST")
        #expect(exchange.request.host == "api.weatherly.dev")
        #expect(exchange.request.target == "/v2/forecast?city=amsterdam&units=metric")
        #expect(exchange.request.headers["Authorization"] == "Bearer secret-token")
        #expect(exchange.requestBody == Data(#"{"days":3}"#.utf8))
        #expect(exchange.response?.status == 200)
        #expect(exchange.responseBody == Data(#"{"forecast":"sunny"}"#.utf8))
        // The body is unpacked now, so the header that said otherwise goes.
        #expect(exchange.response?.headers["Content-Encoding"] == nil)
        #expect(exchange.annotation.comment == "Three days ahead")
        #expect(exchange.clientCertificate == "Weatherly App")
        #expect(abs(exchange.timing.started.timeIntervalSince(start)) < 0.001)
        #expect(abs(try #require(exchange.timing.duration) - 0.182) < 0.001)
        #expect(
            exchange.timingPhases.map(\.step) == [
                .queued, .dnsLookup, .connecting, .tlsHandshake, .requestSent, .waiting, .downloading,
            ])

        #expect(exchanges[1].response == nil)
        #expect(exchanges[1].clientCertificate == nil)
        #expect(
            exchanges[1].state
                == .failed(.recorded("Couldn't connect to the server: localhost refused the connection.")))
    }

    @Test func keepsWhoSpokeTLSWithTheServer() throws {
        let options = HARWriter.Options(includesResponseBodies: false, hidesSecrets: false)
        // A request from the composer, and one an app sent to a reverse proxy: Reqly decrypted
        // neither, so neither should say so when the file is opened again.
        var composed = forecast()
        composed.sentByReqly = true
        var reversed = forecast()
        reversed.reverseProxy = "localhost:8080"
        for exchange in [composed, reversed] {
            #expect(!exchange.isDecrypted)
            let (json, data) = try export([exchange], options: options)
            let entry = try #require(((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first)
            #expect(entry["_sentByReqly"] as? Bool == (exchange.sentByReqly ? true : nil))
            #expect(entry["_reverseProxy"] as? String == exchange.reverseProxy)

            let read = try #require(try HARReader.exchanges(from: data).first)
            #expect(read.sentByReqly == exchange.sentByReqly)
            #expect(read.reverseProxy == exchange.reverseProxy)
            #expect(!read.isDecrypted)
        }

        // An app's request through the proxy, which Reqly decrypted, adds neither field.
        let (json, data) = try export([forecast()], options: options)
        let entry = try #require(((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first)
        #expect(entry["_sentByReqly"] == nil)
        #expect(entry["_reverseProxy"] == nil)
        #expect(try #require(try HARReader.exchanges(from: data).first).isDecrypted)
    }

    @Test func readsWhatBrowsersWrite() throws {
        let har = """
            {"log": {"version": "1.2", "creator": {"name": "WebInspector", "version": "537.36"},
              "entries": [{
                "startedDateTime": "2026-10-03T08:15:23.123Z", "time": 50.5,
                "request": {"method": "GET", "url": "https://images.weatherly.dev/icons/sun@2x.png",
                  "httpVersion": "h2", "headers": [{"name": ":authority", "value": "images.weatherly.dev"},
                  {"name": "accept", "value": "image/png"}]},
                "response": {"status": 200, "statusText": "", "httpVersion": "h2",
                  "headers": [{"name": "content-type", "value": "image/png"}],
                  "content": {"size": 4, "mimeType": "image/png", "text": "iVBORw==", "encoding": "base64"}},
                "timings": {"blocked": 1.5, "dns": -1, "connect": -1, "send": 0.5, "wait": 40, "receive": 8.5}
              }]}}
            """
        let exchanges = try HARReader.exchanges(from: Data(har.utf8))
        let exchange = try #require(exchanges.first)
        #expect(exchange.request.version == "HTTP/2")
        #expect(exchange.request.headers.map(\.name) == ["accept"])
        #expect(exchange.responseBody == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(exchange.reusedConnection)
        #expect(!exchange.sentByReqly)
        #expect(exchange.reverseProxy == nil)
        #expect(abs(try #require(exchange.timing.duration) - 0.0505) < 0.0001)
    }

    @Test func refusesFilesThatAreNotHAR() {
        #expect(throws: HARError.unreadable("Reqly couldn't read this file as HAR.")) {
            try HARReader.exchanges(from: Data("not json".utf8))
        }
    }
}
