import CoreInterface
import Foundation
import Presentation
import ReqlyModel
import Testing

@testable import ReqlyApp

/// What the details' heading and pages say, as the Mac's do, without a window.
@Suite struct DetailsWordsTests {
    static let english = Locale(identifier: "en_US")
    static let utc = TimeZone(identifier: "UTC")!
    static let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// A finished HTTPS request, decrypted, with every step of its timing, as the Mac's saved
    /// session has its forecast.
    static func forecast() -> Exchange {
        var exchange = Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 1), kind: .http,
            request: RequestHead(
                method: "GET", scheme: "https", host: "api.weatherly.dev", port: 443,
                target: "/v2/forecast?city=Lisbon&days=3",
                headers: ["Accept": "application/json", "Authorization": "Bearer secret-token", "Cookie": "a=1; b=2"]),
            started: start)
        exchange.response = ResponseHead(
            status: 200, reason: "OK",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": "session=7f3a; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/; Secure",
            ])
        exchange.responseBody = Data(#"{"city":"Lisbon"}"#.utf8)
        exchange.bytesReceived = Int64(exchange.responseBody.count)
        exchange.state = .completed
        exchange.timing.requestEnded = start + 0.001
        exchange.timing.connectStarted = start + 0.002
        exchange.timing.resolved = start + 0.0625
        exchange.timing.connected = start + 0.125
        exchange.timing.secured = start + 0.25
        exchange.timing.requestSent = start + 0.25
        exchange.timing.responseStarted = start + 0.5
        exchange.timing.ended = start + 0.75
        exchange.remoteAddress = "203.0.113.24:443"
        exchange.tlsVersion = "1.3"
        exchange.serverProtocol = "HTTP/2"
        exchange.source = Source(name: "Weatherly", bundleID: "dev.weatherly.app")
        return exchange
    }

    /// An encrypted connection Reqly passed through.
    static func tunnel(state: ExchangeState = .completed) -> Exchange {
        var exchange = Exchange(
            id: ExchangeID(rawValue: 6), connectionID: ConnectionID(rawValue: 6), kind: .tunnel,
            request: RequestHead(
                method: "CONNECT", scheme: "https", host: "maps.weatherly.dev", port: 443,
                target: "maps.weatherly.dev:443"),
            started: start)
        exchange.state = state
        exchange.bytesSent = 1_203
        exchange.bytesReceived = 48_119
        if state.isFinished {
            exchange.timing.ended = start + 3.5
        }
        exchange.source = Source(name: "Weatherly")
        return exchange
    }

    @Test func writesDurationsSizesAndTimesAsTheMacDoes() {
        func duration(_ seconds: TimeInterval?, tenths: Bool = false) -> String {
            Format.duration(seconds, showingTenths: tenths, locale: Self.english)
        }
        #expect(duration(nil) == "")
        #expect(duration(0.34) == "340 ms")
        #expect(duration(0.0004) == "0 ms")
        #expect(duration(1.2345) == "1.23 s")
        #expect(duration(252) == "4 min 12 s")
        #expect(duration(7_500) == "2 h 5 min")
        // The Timing page's short steps keep a tenth of a millisecond, under 10 ms.
        #expect(duration(0.0004, tenths: true) == "0.4 ms")
        #expect(duration(0.0099, tenths: true) == "9.9 ms")
        #expect(duration(0.02, tenths: true) == "20 ms")
        // The time of day as the list has it, as on the Mac. ICU puts a narrow space before AM.
        #expect(Format.time(Self.start + 1, locale: Self.english, timeZone: Self.utc) == "4:00:01\u{202F}AM")
        #expect(
            DetailsFormat.moment(Self.start + 1.25, locale: Self.english, timeZone: Self.utc) == "Oct 3 at 04:00:01.250"
        )
        let expiry = Date(timeIntervalSince1970: 1_792_567_680)
        #expect(DetailsFormat.day(expiry, locale: Self.english, timeZone: Self.utc) == "Oct 21, 2026 at 07:28")
        #expect(DetailsFormat.messages(1, locale: Self.english) == "1 message")
        #expect(DetailsFormat.messages(1_204, locale: Self.english) == "1,204 messages")
        #expect(DetailsFormat.host(scheme: "https", host: "api.weatherly.dev", port: 443) == "api.weatherly.dev")
        #expect(DetailsFormat.host(scheme: "http", host: "localhost", port: 8080) == "localhost:8080")
        #expect(DetailsFormat.host(scheme: "http", host: "localhost", port: 443) == "localhost:443")
    }

    @Test func headsARequestWithItsStatusLine() {
        var exchange = Self.forecast()
        exchange.device = Device(id: "1", kind: .simulator, name: "iPhone 17 Pro")
        let heading = DetailsHeading(
            exchange.summary, reason: "OK", grpc: nil, locale: Self.english, timeZone: Self.utc)
        #expect(heading.method == "GET")
        #expect(heading.title == "/v2/forecast")
        #expect(heading.subtitle == "api.weatherly.dev · Weatherly · iPhone 17 Pro")
        #expect(heading.mark == .dot(.success))
        #expect(heading.code == "200")
        #expect(heading.status == "OK")
        #expect(heading.line == "200 OK · 750 ms · 17 B · 4:00:00\u{202F}AM")
        #expect(heading.afterCode == "OK · 750 ms · 17 B · 4:00:00\u{202F}AM")

        // A reason the server left out leaves the code on its own.
        let bare = DetailsHeading(exchange.summary, reason: "", grpc: nil, locale: Self.english, timeZone: Self.utc)
        #expect(bare.line == "200 · 750 ms · 17 B · 4:00:00\u{202F}AM")
        #expect(bare.afterCode == "· 750 ms · 17 B · 4:00:00\u{202F}AM")

        // gRPC's status and a WebSocket's messages come before the rest.
        exchange.messageCount = 3
        let call = DetailsHeading(
            exchange.summary, reason: "OK", grpc: GRPCStatus(code: 5), locale: Self.english, timeZone: Self.utc)
        #expect(call.facts == ["gRPC NOT_FOUND", "3 messages", "750 ms", "17 B", "4:00:00\u{202F}AM"])
    }

    @Test func headsTunnelsFailuresAndRequestsInProgress() {
        let open = DetailsHeading(
            Self.tunnel(state: .open).summary, reason: nil, grpc: nil, locale: Self.english, timeZone: Self.utc)
        #expect(open.method == "CONNECT")
        #expect(open.title == "maps.weatherly.dev")
        #expect(open.subtitle == "Encrypted connection · Weatherly")
        #expect(open.mark == .lock)
        #expect(open.line == "Open · 48.1 KB · 4:00:00\u{202F}AM")
        let closed = DetailsHeading(
            Self.tunnel().summary, reason: nil, grpc: nil, locale: Self.english, timeZone: Self.utc)
        #expect(closed.line == "Closed · 3.50 s · 48.1 KB · 4:00:00\u{202F}AM")

        var failed = Self.forecast()
        failed.response = nil
        failed.state = .failed(.serverClosed)
        let failure = DetailsHeading(failed.summary, reason: nil, grpc: nil, timeZone: Self.utc)
        #expect(failure.mark == .failed && failure.code == nil)
        #expect(failure.line.hasPrefix("Failed · 750 ms · "))

        var waiting = Self.forecast()
        waiting.response = nil
        waiting.state = .waiting
        waiting.timing.ended = nil
        waiting.bytesReceived = 0
        let progress = DetailsHeading(
            waiting.summary, reason: nil, grpc: nil, locale: Self.english, timeZone: Self.utc)
        #expect(progress.mark == .none)
        #expect(progress.line == "In progress · 0 B · 4:00:00\u{202F}AM")
    }

    @Test func readsTheDetailsAgainOnlyWhenMoreThanTheMarksChange() {
        let summary = Self.forecast().summary
        var marked = summary
        marked.annotation = Annotation(isPinned: true, color: .red, comment: "Looks right")
        #expect(!marked.differsInDetails(from: summary))
        #expect(summary.differsInDetails(from: nil))
        var grown = summary
        grown.bytesReceived += 1
        #expect(grown.differsInDetails(from: marked))
        var done = summary
        done.state = .failed(.serverClosed)
        #expect(done.differsInDetails(from: summary))
    }

    @Test func givesOverviewTheMacsRowsLeavingOutEmptyOnes() {
        let words = OverviewWords(ExchangeDetails(Self.forecast()), locale: Self.english, timeZone: Self.utc)
        #expect(words.url == "https://api.weatherly.dev/v2/forecast?city=Lisbon&days=3")
        #expect(words.failure == nil && words.rules == nil && words.scripts.isEmpty)
        #expect(words.sections.map(\.title) == ["Request", "Response", "Connection"])
        let request = words.sections[0].rows.map { "\($0.name): \($0.value)" }
        #expect(
            request == [
                "Method: GET", "App: Weatherly", "Bundle ID: dev.weatherly.app", "Started: Oct 3 at 04:00:00.000",
                "Sent: 0 B",
            ])
        let response = words.sections[1].rows.map { "\($0.name): \($0.value)" }
        #expect(
            response == [
                "Status: 200 OK", "Received: 17 B", "Content type: application/json", "Duration: 750 ms",
            ])
        let connection = words.sections[2].rows.map { "\($0.name): \($0.value)" }
        #expect(connection == ["Protocol: HTTP/1.1", "To the server: HTTP/2", "HTTPS: Decrypted by Reqly"])
        #expect(!words.sections.flatMap(\.rows).contains { $0.value.isEmpty || $0.value == "None" })

        // Reqly's own request, through proxies, with a certificate, and with no content type.
        var sent = Self.forecast()
        sent.sentByReqly = true
        sent.reverseProxy = "localhost:8080"
        sent.upstreamProxy = "proxy.example.com:8080"
        sent.clientCertificate = "Reqly Test Client"
        sent.response?.headers = [:]
        sent.device = Device(id: "a4", kind: .network, name: "Parsa's iPhone", address: "192.168.1.23")
        let own = OverviewWords(ExchangeDetails(sent), locale: Self.english, timeZone: Self.utc)
        #expect(own.sections[0].rows[1] == DetailsRow(name: "Device", value: "Parsa's iPhone · 192.168.1.23"))
        #expect(!own.sections[1].rows.contains { $0.name == "Content type" })
        #expect(
            own.sections[2].rows.map(\.value) == [
                "HTTP/1.1", "HTTP/2", "Sent over TLS by Reqly", "The app sent it to localhost:8080",
                "proxy.example.com:8080", "Reqly Test Client",
            ])
    }

    @Test func saysWhatBecameOfFailuresRulesAndTunnels() {
        var blocked = Self.forecast()
        blocked.response = nil
        blocked.state = .failed(.blocked(rule: "No ads"))
        blocked.appliedRules = [AppliedRule(name: "No ads", kind: .block, detail: "Closed the connection.")]
        let words = OverviewWords(ExchangeDetails(blocked), locale: Self.english, timeZone: Self.utc)
        #expect(words.failure == "The rule “No ads” blocked this request, so Reqly closed the connection.")
        #expect(
            words.rules
                == DetailsSection(
                    "Rules", count: 1, rows: [DetailsRow(name: "No ads", value: "Closed the connection.")]))
        #expect(words.sections[1] == DetailsSection("Response", rows: [], note: "No response yet."))

        let tunnel = OverviewWords(ExchangeDetails(Self.tunnel()), locale: Self.english, timeZone: Self.utc)
        #expect(tunnel.sections.map(\.title) == ["Request", "Connection"])
        #expect(
            tunnel.sections[1].rows.map { "\($0.name): \($0.value)" } == [
                "HTTPS: Encrypted, passed through untouched", "Received: 48.1 KB", "Duration: 3.50 s",
            ])
        var refused = Self.tunnel()
        refused.state = .failed(.certificateRejected)
        #expect(OverviewWords.tunnelEncryption(refused) == "Reqly tried to decrypt it, but the app's handshake failed")
    }

    @Test func notesDecryptionInTheMacsWords() {
        let host = "api.weatherly.dev"
        #expect(DecryptionNote(.plain, host: host, isDecrypting: true) == nil)
        let tunnel = DecryptionNote(.encryptedTunnel, host: host, isDecrypting: false)
        #expect(tunnel?.text == "This connection is encrypted, so Reqly can't show what's inside.")
        #expect(tunnel?.actionTitle == "Decrypt api.weatherly.dev")
        #expect(tunnel?.isSuggested == true && tunnel?.look == .locked)
        let decrypting = DecryptionNote(.encryptedTunnel, host: host, isDecrypting: true)
        #expect(decrypting?.text == "Reqly now decrypts api.weatherly.dev. Its next requests show up decrypted.")
        #expect(decrypting?.actionTitle == "Stop Decrypting api.weatherly.dev")
        let decrypted = DecryptionNote(.decrypted, host: host, isDecrypting: true)
        #expect(decrypted?.text == "Reqly decrypted this request." && decrypted?.action == .stopDecrypting)
        let stopped = DecryptionNote(.decrypted, host: host, isDecrypting: false)
        #expect(stopped?.text == "Reqly no longer decrypts api.weatherly.dev. Its connections pass through encrypted.")
        #expect(stopped?.action == .decrypt && stopped?.isSuggested == false)
        let rejected = DecryptionNote(.certificateRejected, host: host, isDecrypting: true)
        #expect(
            rejected?.text == "Stopping decryption for api.weatherly.dev lets its traffic through again, encrypted.")
        #expect(rejected?.look == .warning)
        let device = DecryptionNote(.certificateRejected, host: host, isDecrypting: true, device: "Pixel 9")
        #expect(device?.text.hasPrefix("Pixel 9 may trust an earlier Reqly certificate.") == true)
        // A saved session decrypts nothing, so its notes have no button.
        #expect(DecryptionNote(.decrypted, host: host, isDecrypting: nil)?.action == nil)
        #expect(DecryptionNote(.encryptedTunnel, host: host, isDecrypting: nil)?.actionTitle == nil)
        #expect(DecryptionNote(.certificateRejected, host: host, isDecrypting: nil) == nil)
    }

    @Test func showsTheMessagesSecretsAsDots() {
        let details = ExchangeDetails(Self.forecast())
        let request = MessageWords(details, part: .request, locale: Self.english, timeZone: Self.utc)
        #expect(request.query.map { "\($0.name)=\($0.value)" } == ["city=Lisbon", "days=3"])
        #expect(request.headers.map(\.isSecret) == [false, true, true])
        #expect(request.cookies.map { "\($0.name)=\($0.value)" } == ["a=1", "b=2"])
        #expect(!request.hasBody && request.note == "This request has no body." && !request.isWholePage)
        #expect(request.headersText == "Accept: application/json\nAuthorization: Bearer secret-token\nCookie: a=1; b=2")

        let response = MessageWords(details, part: .response, locale: Self.english, timeZone: Self.utc)
        #expect(response.hasBody && response.bodySize == 17 && response.note == nil)
        #expect(response.cookies.count == 1)
        #expect(response.cookies.first?.attributes == "Expires Oct 21, 2026 at 07:28 · Path / · Secure")
        #expect(response.query.isEmpty && response.trailers.isEmpty)

        var unread = Self.forecast()
        unread.response = nil
        unread.state = .waiting
        #expect(MessageWords(ExchangeDetails(unread), part: .response).note == "No response yet.")
        let tunnel = MessageWords(ExchangeDetails(Self.tunnel()), part: .response)
        #expect(tunnel.note == "Reqly doesn't decrypt this host, so the response isn't readable." && tunnel.isWholePage)

        var call = Self.forecast()
        call.responseTrailers = ["grpc-status": "0"]
        #expect(MessageWords(ExchangeDetails(call), part: .response).trailers.map(\.name) == ["grpc-status"])

        // Between 8 and 16 dots, whatever the secret's length.
        #expect(MessageWords.mask("abc") == String(repeating: "•", count: 8))
        #expect(MessageWords.mask("twelve chars") == String(repeating: "•", count: 12))
        #expect(MessageWords.mask(String(repeating: "x", count: 40)) == String(repeating: "•", count: 16))
        #expect(MessageWords.name(of: MessageWords.Cookie(name: "", value: "1")) == "No name")
    }

    @Test func placesRawHeaderNamesInCharacters() {
        var exchange = Self.forecast()
        exchange.request.headers = ["X-City": "تهران", "X-Sky": "☀️ then 🌧", "Authorization": "Bearer token"]
        exchange.requestBody = Data("city=تهران".utf8)
        let message = RawMessage(request: exchange.request, body: exchange.requestBody, hidingSecrets: true)
        let text = RawText(message)
        let scalars = Array(text.text.unicodeScalars)
        func words(_ range: Range<Int>) -> String {
            String(String.UnicodeScalarView(scalars[range]))
        }
        #expect(text.names.map(words) == ["X-City", "X-Sky", "Authorization"])
        #expect(text.text.contains("Authorization: ••••••••\n"))
        #expect(text.notes.isEmpty)

        exchange.response?.headers = ["Content-Encoding": "gzip", "Content-Type": "application/json"]
        exchange.responseBody = Data([0x1f, 0x8b, 0x08])
        let packed = RawText(
            RawMessage(
                response: exchange.response!, body: exchange.responseBody, trailers: nil, hidingSecrets: true))
        #expect(
            packed.notes.map(characters(in: packed)) == [
                "‹3 B of gzip-compressed data. The Response tab shows it unpacked.›"
            ])

        #expect(RawWords.secrets(showing: false) == ("Cookies and authorization headers are hidden.", "Show Them"))
        #expect(RawWords.secrets(showing: true) == ("Cookies and authorization headers are showing.", "Hide Them"))
        #expect(RawWords.noResponse(Self.tunnel()) == "Reqly doesn't decrypt this host.")
        #expect(RawWords.hasSecrets(exchange))
        exchange.request.version = "HTTP/2"
        #expect(RawWords.note(exchange)?.hasPrefix("HTTP/2 sends these as binary frames.") == true)
    }

    /// The characters `range` covers in `text`'s text.
    private func characters(in text: RawText) -> (Range<Int>) -> String {
        let scalars = Array(text.text.unicodeScalars)
        return { String(String.UnicodeScalarView(scalars[$0])) }
    }

    @Test func drawsTheWaterfallInTheMacsColors() {
        let waterfall = Waterfall(ExchangeDetails(Self.forecast()), locale: Self.english)
        #expect(
            waterfall.steps.map(\.title) == [
                "Queued", "DNS lookup", "Connecting", "TLS handshake", "Request sent", "Waiting for server",
                "Downloading",
            ])
        #expect(waterfall.steps.map(\.look) == [.dim, .dim, .dim, .dim, .dim, .accent, .halfAccent])
        #expect(waterfall.steps[0].value == "2.0 ms" && waterfall.steps[4].value == "0.0 ms")
        #expect(waterfall.steps[3].value == "125 ms" && waterfall.steps[6].value == "250 ms")
        #expect(waterfall.total == "750 ms" && waterfall.isShown)
        // On one timeline: waiting starts a third of the way, and takes a third.
        let waiting = waterfall.steps[5]
        #expect(abs(waiting.offset - 1.0 / 3) < 0.001 && abs(waiting.length - 1.0 / 3) < 0.001)
        #expect(
            waterfall.connection.map { "\($0.name): \($0.value)" } == [
                "Protocol: HTTP/1.1", "To the server: HTTP/2", "Remote address: 203.0.113.24:443", "TLS: 1.3",
                "Reused connection: No",
            ])

        // A failed exchange's last step is red.
        var blocked = Self.forecast()
        blocked.response = nil
        blocked.timing.responseStarted = nil
        blocked.state = .failed(.blocked(rule: "No ads"))
        let failed = Waterfall(ExchangeDetails(blocked))
        #expect(failed.steps.last?.title == "Waiting for server" && failed.steps.last?.look == .failed)

        // A reused connection has three steps.
        var reused = Self.forecast()
        reused.reusedConnection = true
        reused.timing.connectStarted = nil
        let three = Waterfall(ExchangeDetails(reused))
        #expect(three.steps.map(\.title) == ["Request sent", "Waiting for server", "Downloading"])
        #expect(three.connection.last == DetailsRow(name: "Reused connection", value: "Yes"))

        // Still open, in progress, and none for a connection that never reached a server.
        #expect(Waterfall(ExchangeDetails(Self.tunnel(state: .open))).total == "Still open")
        var waiting2 = Self.forecast()
        waiting2.state = .waiting
        waiting2.timing.responseStarted = nil
        waiting2.timing.ended = nil
        #expect(Waterfall(ExchangeDetails(waiting2)).total == "In progress")
        let none = Waterfall(ExchangeDetails(Self.tunnel()))
        #expect(
            !none.isShown
                && none.connection == [DetailsRow(name: "HTTPS", value: "Encrypted, passed through untouched")])
    }

    @Test func namesTheMarksColors() {
        #expect(
            MarkColor.allCases.map(\.title) == [
                "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray",
            ])
    }
}
