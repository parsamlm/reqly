import Foundation
import Testing

@testable import ReqlyModel

@Suite struct HeadersTests {
    @Test func namesMatchWithoutCase() {
        let headers: Headers = ["Content-Type": "application/json", "X-Trace": "1"]
        #expect(headers["content-type"] == "application/json")
        #expect(headers["CONTENT-TYPE"] == "application/json")
        #expect(headers.contains("x-trace"))
        #expect(headers["Accept"] == nil)
    }

    @Test func keepsOrderAndRepeatedNames() {
        var headers: Headers = ["Set-Cookie": "a=1", "Vary": "Accept", "Set-Cookie": "b=2"]
        #expect(headers.map(\.name) == ["Set-Cookie", "Vary", "Set-Cookie"])
        #expect(headers.values(named: "set-cookie") == ["a=1", "b=2"])

        headers.remove(named: "SET-COOKIE")
        #expect(headers.map(\.name) == ["Vary"])
    }
}

@Suite struct RequestHeadTests {
    @Test func splitsPathAndQuery() {
        let head = RequestHead(
            method: "GET", scheme: "https", host: "api.weatherly.dev", port: 443, target: "/v2/forecast?city=amsterdam")
        #expect(head.path == "/v2/forecast")
        #expect(head.query == "city=amsterdam")
        #expect(head.authority == "api.weatherly.dev")
        #expect(head.url == URL(string: "https://api.weatherly.dev/v2/forecast?city=amsterdam"))
    }

    @Test func showsPortOnlyWhenItIsNotTheDefault() {
        let head = RequestHead(method: "GET", scheme: "http", host: "localhost", port: 8080, target: "/")
        #expect(head.authority == "localhost:8080")
        #expect(head.query == nil)
    }

    @Test func bracketsIPv6Hosts() {
        let head = RequestHead(method: "GET", scheme: "http", host: "::1", port: 8080, target: "/a")
        #expect(head.authority == "[::1]:8080")
        #expect(head.url?.absoluteString == "http://[::1]:8080/a")
    }

    @Test func tunnelURLHasNoPath() {
        let head = RequestHead(
            method: "CONNECT", scheme: "https", host: "api.weatherly.dev", port: 443, target: "api.weatherly.dev:443")
        #expect(head.url?.absoluteString == "https://api.weatherly.dev")
    }
}

@Suite struct StatusClassTests {
    @Test(arguments: [
        (100, StatusClass.informational), (204, .success), (304, .redirection), (429, .clientError),
        (503, .serverError),
    ])
    func classifies(status: Int, expected: StatusClass) {
        #expect(StatusClass(status: status) == expected)
    }

    @Test func rejectsCodesOutsideTheRange() {
        #expect(StatusClass(status: 99) == nil)
        #expect(StatusClass(status: 600) == nil)
    }
}

@Suite struct HostPatternTests {
    @Test func matchesExactHostsWithoutCase() {
        let pattern = HostPattern(rawValue: "API.weatherly.dev")!
        #expect(pattern.rawValue == "api.weatherly.dev")
        #expect(pattern.matches("api.weatherly.dev"))
        #expect(pattern.matches("API.WEATHERLY.DEV"))
        #expect(!pattern.matches("images.weatherly.dev"))
    }

    @Test func wildcardsMatchSubdomainsOnly() {
        let pattern = HostPattern(rawValue: "*.weatherly.dev")!
        #expect(pattern.matches("api.weatherly.dev"))
        #expect(pattern.matches("a.b.weatherly.dev"))
        #expect(!pattern.matches("weatherly.dev"))
        #expect(!pattern.matches("notweatherly.dev"))
    }

    @Test(arguments: ["", "*.", "api weatherly", "*", "a/b", "*.*.dev"])
    func rejectsWhatIsNotAHost(_ text: String) {
        #expect(HostPattern(rawValue: text) == nil)
    }

    @Test func survivesSavingAndLoading() throws {
        let patterns = [HostPattern(rawValue: "api.weatherly.dev")!, HostPattern(rawValue: "*.apple.com")!]
        let data = try JSONEncoder().encode(patterns)
        #expect(try JSONDecoder().decode([HostPattern].self, from: data) == patterns)
    }
}

@Suite struct DecryptedHostsTests {
    let api = HostPattern(rawValue: "api.weatherly.dev")!
    let weatherly = HostPattern(rawValue: "*.weatherly.dev")!
    let images = HostPattern(rawValue: "*.images.weatherly.dev")!

    @Test func decryptsTheHostsSwitchedOn() {
        let hosts = DecryptedHosts(entries: [.init(weatherly), .init(HostPattern(rawValue: "apple.com")!, isOn: false)])
        #expect(hosts.decrypts("api.weatherly.dev"))
        #expect(!hosts.decrypts("apple.com"))
        #expect(!hosts.decrypts("example.com"))
        #expect(hosts.onCount == 1)
    }

    @Test func theMostSpecificEntryDecides() {
        let hosts = DecryptedHosts(entries: [.init(api, isOn: false), .init(weatherly), .init(images, isOn: false)])
        #expect(!hosts.decrypts("api.weatherly.dev"))
        #expect(hosts.decrypts("auth.weatherly.dev"))
        #expect(!hosts.decrypts("cdn.images.weatherly.dev"))
        #expect(hosts.entry(for: "API.weatherly.dev")?.pattern == api)
    }

    @Test func everyHostLeavesOutTheOnesSwitchedOff() {
        let hosts = DecryptedHosts(entries: [.init(api, isOn: false)], includesEveryHost: true)
        #expect(hosts.decrypts("example.com"))
        #expect(hosts.decrypts("auth.weatherly.dev"))
        #expect(!hosts.decrypts("api.weatherly.dev"))
    }
}

@Suite struct TimingPhaseTests {
    let start = Date(timeIntervalSinceReferenceDate: 1000)

    func exchange(_ kind: ExchangeKind = .http, scheme: String = "https", host: String = "api.weatherly.dev")
        -> Exchange
    {
        let target = kind == .tunnel ? "\(host):443" : "/v2/forecast"
        return Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 1), kind: kind,
            request: RequestHead(
                method: kind == .tunnel ? "CONNECT" : "GET", scheme: scheme, host: host, port: 443, target: target),
            started: start)
    }

    @Test func followsEachStepOfANewSecureConnection() throws {
        var exchange = exchange()
        exchange.timing.connectStarted = start + 0.001
        exchange.timing.resolved = start + 0.013
        exchange.timing.connected = start + 0.031
        exchange.timing.secured = start + 0.062
        exchange.timing.requestSent = start + 0.063
        exchange.timing.responseStarted = start + 0.167
        exchange.timing.ended = start + 0.182
        exchange.state = .completed

        let phases = exchange.timingPhases
        #expect(
            phases.map(\.step) == [
                .queued, .dnsLookup, .connecting, .tlsHandshake, .requestSent, .waiting, .downloading,
            ])
        #expect(phases.first?.start == start)
        #expect(zip(phases, phases.dropFirst()).allSatisfy { $0.end == $1.start })
        let waiting = try #require(phases.first { $0.step == .waiting })
        #expect(abs(waiting.duration - 0.104) < 0.0001)
    }

    @Test func aReusedConnectionStartsWithTheRequest() {
        var exchange = exchange()
        exchange.reusedConnection = true
        exchange.timing.requestSent = start + 0.001
        exchange.timing.responseStarted = start + 0.05
        exchange.timing.ended = start + 0.06
        exchange.state = .completed
        #expect(exchange.timingPhases.map(\.step) == [.requestSent, .waiting, .downloading])
        #expect(exchange.timingPhases.first?.start == start)
    }

    @Test func plainHTTPToAnAddressNeedsNoLookupOrHandshake() {
        var exchange = exchange(scheme: "http", host: "127.0.0.1")
        exchange.timing.connectStarted = start
        exchange.timing.connected = start + 0.001
        exchange.timing.requestSent = start + 0.002
        exchange.timing.responseStarted = start + 0.01
        exchange.timing.ended = start + 0.011
        exchange.state = .completed
        #expect(exchange.timingPhases.map(\.step) == [.queued, .connecting, .requestSent, .waiting, .downloading])
    }

    @Test func endsWithTheStepItFailedIn() {
        var exchange = exchange()
        exchange.timing.connectStarted = start
        exchange.timing.resolved = start + 0.01
        exchange.timing.ended = start + 20
        exchange.state = .failed(.cannotConnect("the server didn't answer in time."))
        #expect(exchange.timingPhases.map(\.step) == [.queued, .dnsLookup, .connecting])
        #expect(exchange.timingPhases.last?.end == start + 20)
    }

    @Test func showsNoStepsForARequestThatNeverLeft() {
        var exchange = exchange()
        exchange.timing.ended = start
        exchange.state = .failed(.loopDetected)
        #expect(exchange.timingPhases.isEmpty)
    }

    @Test func stopsAtTheLatestStepWhileInProgress() {
        var exchange = exchange()
        exchange.reusedConnection = true
        exchange.timing.requestSent = start + 0.001
        exchange.state = .waiting
        #expect(exchange.timingPhases.map(\.step) == [.requestSent])
    }

    @Test func tunnelsStayOpenUntilTheyClose() {
        var tunnel = exchange(.tunnel, host: "gateway.icloud.com")
        tunnel.timing.connectStarted = start
        tunnel.timing.resolved = start + 0.005
        tunnel.timing.connected = start + 0.02
        tunnel.state = .open
        #expect(tunnel.timingPhases.map(\.step) == [.queued, .dnsLookup, .connecting])

        tunnel.timing.ended = start + 30
        tunnel.state = .completed
        #expect(tunnel.timingPhases.map(\.step) == [.queued, .dnsLookup, .connecting, .open])
    }
}

@Suite struct ExchangeFailureTests {
    @Test func namesThePartCancelledAtABreakpoint() {
        let request = ExchangeFailure.cancelledAtBreakpoint(part: .request)
        let response = ExchangeFailure.cancelledAtBreakpoint(part: .response)
        #expect(request.message == "You cancelled this request at a breakpoint.")
        #expect(response.message == "You cancelled this response at a breakpoint.")
    }

    @Test func readsSessionsSavedBeforeThePartWasKept() throws {
        let saved = Data(#"{"cancelledAtBreakpoint":{}}"#.utf8)
        let failure = try JSONDecoder().decode(ExchangeFailure.self, from: saved)
        #expect(failure == .cancelledAtBreakpoint(part: nil))
        #expect(failure.message == "You cancelled this request at a breakpoint.")
    }

    @Test func savesThePartWhereAnOlderReqlyLooksPastIt() throws {
        // An older Reqly ignores the part, so it can still open the session.
        let data = try JSONEncoder().encode(ExchangeFailure.cancelledAtBreakpoint(part: .response))
        #expect(String(decoding: data, as: UTF8.self) == #"{"cancelledAtBreakpoint":{"part":"response"}}"#)
    }
}

@Suite struct DecryptedExchangeTests {
    func exchange(scheme: String = "https", kind: ExchangeKind = .http) -> Exchange {
        let tunnel = kind == .tunnel
        return Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 1), kind: kind,
            request: RequestHead(
                method: tunnel ? "CONNECT" : "GET", scheme: scheme, host: "api.weatherly.dev", port: 443,
                target: tunnel ? "api.weatherly.dev:443" : "/v2/forecast"),
            started: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test func anAppsHTTPSIsDecrypted() {
        #expect(exchange().isDecrypted)
        // Whichever app sent it, Reqly too: its own requests, such as the update check, go
        // through the proxy like any app's.
        var own = exchange()
        own.source = Source(name: "Reqly", bundleID: "net.reqly.Reqly", path: "/Applications/Reqly.app")
        #expect(own.isDecrypted)
    }

    @Test func requestsReqlySentOverTLSItselfAreNot() {
        // From the composer or Resend, whichever copy of Reqly saved them.
        var composed = exchange()
        composed.sentByReqly = true
        composed.source = Source(name: "Reqly", bundleID: "net.reqly.Reqly.debug", path: "/tmp/Reqly.app")
        #expect(!composed.isDecrypted)
        // The app spoke plain HTTP to a reverse proxy, and Reqly spoke TLS with the server.
        var reversed = exchange()
        reversed.reverseProxy = "localhost:8080"
        #expect(!reversed.isDecrypted)
        #expect(!exchange(scheme: "http").isDecrypted)
        #expect(!exchange(kind: .tunnel).isDecrypted)
    }
}

@Suite struct TrafficFilterTests {
    func summary(
        _ method: String = "GET",
        host: String = "api.weatherly.dev",
        status: Int? = 200,
        contentType: String? = "application/json",
        state: ExchangeState = .completed,
        source: Source? = nil
    ) -> ExchangeSummary {
        var exchange = Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 1), kind: .http,
            request: RequestHead(method: method, scheme: "https", host: host, port: 443, target: "/v2/forecast"),
            started: Date(timeIntervalSinceReferenceDate: 0))
        if let status {
            var headers = Headers()
            if let contentType {
                headers.append(name: "Content-Type", value: contentType)
            }
            exchange.response = ResponseHead(status: status, reason: "", headers: headers)
        }
        exchange.state = state
        exchange.source = source
        return exchange.summary
    }

    @Test func letsEverythingThroughWhenNothingIsSet() {
        let filter = TrafficFilter()
        #expect(!filter.isActive)
        #expect(filter.matches(summary()))
        #expect(filter.matches(summary(status: nil, state: .waiting)))
    }

    @Test func showsAnyOfTheChosenStatuses() {
        var filter = TrafficFilter()
        filter.statuses = [.clientError, .serverError]
        #expect(filter.matches(summary(status: 404)))
        #expect(filter.matches(summary(status: 503)))
        #expect(!filter.matches(summary(status: 200)))
        #expect(!filter.matches(summary(status: 304)))
        // No response yet, so no status to match.
        #expect(!filter.matches(summary(status: nil, state: .waiting)))
    }

    @Test func failuresCountAsFailedWhateverTheirStatus() {
        let cutOff = summary(status: 200, state: .failed(.serverClosed))
        var filter = TrafficFilter()
        filter.statuses = [.success]
        #expect(!filter.matches(cutOff))
        filter.statuses = [.failed]
        #expect(filter.matches(cutOff))
        #expect(filter.matches(summary(status: nil, state: .failed(.cannotConnect("refused")))))
        #expect(!filter.matches(summary(status: 500)))
    }

    @Test func needsEveryKindOfFilterToMatch() {
        let weatherly = Source(name: "Weatherly", bundleID: "dev.weatherly.app", path: nil)
        var filter = TrafficFilter()
        filter.source = weatherly
        filter.host = "api.weatherly.dev"
        filter.method = "POST"
        filter.contents = [.json]
        #expect(filter.isActive)
        #expect(filter.matches(summary("POST", source: weatherly)))
        #expect(!filter.matches(summary("GET", source: weatherly)))
        #expect(!filter.matches(summary("POST", host: "images.weatherly.dev", source: weatherly)))
        #expect(!filter.matches(summary("POST", contentType: "image/png", source: weatherly)))
        #expect(!filter.matches(summary("POST", source: nil)))
    }

    @Test(arguments: [
        ("application/json; charset=utf-8", ContentGroup.json),
        ("application/problem+json", .json),
        ("Application/JSON", .json),
        ("text/xml", .xml),
        ("application/atom+xml", .xml),
        ("text/html; charset=UTF-8", .html),
        ("application/xhtml+xml", .html),
        ("text/javascript", .javascript),
        ("text/css", .css),
        ("image/svg+xml", .image),
        ("image/png", .image),
        ("video/mp4", .media),
        ("application/vnd.apple.mpegurl", .media),
        ("text/plain", .other),
        ("application/octet-stream", .other),
    ])
    func groupsContentTypes(contentType: String, expected: ContentGroup) {
        #expect(ContentGroup(contentType: contentType) == expected)
    }

    @Test func responsesWithoutAContentTypeAreOther() {
        #expect(ContentGroup(contentType: nil) == .other)
        var filter = TrafficFilter()
        filter.contents = [.other]
        #expect(filter.matches(summary(status: 204, contentType: nil)))
        #expect(filter.matches(summary(status: nil, contentType: nil, state: .waiting)))
    }
}

@Suite struct RuleTests {
    func matches(
        _ match: RequestMatch, _ method: String = "GET", host: String = "api.weatherly.dev", port: Int = 443,
        target: String = "/v2/forecast?city=amsterdam"
    ) -> Bool {
        match.matches(method: method, host: host, port: port, target: target)
    }

    @Test func starsMatchAnything() {
        #expect(Wildcard.matches("*", ""))
        #expect(Wildcard.matches("/v2/*", "/v2/forecast"))
        #expect(Wildcard.matches("/v2/*/hourly", "/v2/forecast/hourly"))
        #expect(Wildcard.matches("*.weatherly.dev", "api.weatherly.dev"))
        #expect(!Wildcard.matches("*.weatherly.dev", "weatherly.dev"))
        #expect(!Wildcard.matches("/v2/forecast", "/v2/forecasts"))
        #expect(Wildcard.matches("a*b*c", "aXXbYYc"))
        #expect(!Wildcard.matches("a*b*c", "aXXbYY"))
    }

    @Test func matchesHostsPathsAndMethods() {
        #expect(matches(RequestMatch()))
        #expect(matches(RequestMatch(host: "API.weatherly.dev")))
        #expect(!matches(RequestMatch(host: "images.weatherly.dev")))
        // The query counts only when the pattern asks about it.
        #expect(matches(RequestMatch(path: "/v2/forecast")))
        #expect(matches(RequestMatch(path: "v2/forecast*")))
        #expect(matches(RequestMatch(path: "/v2/forecast?city=*")))
        #expect(!matches(RequestMatch(path: "/v2/forecast?city=utrecht")))
        #expect(matches(RequestMatch(method: "get")))
        #expect(!matches(RequestMatch(method: "POST")))
    }

    @Test func aHostWithAPortMatchesOnlyThatPort() {
        let local = RequestMatch(host: "localhost:9096")
        #expect(matches(local, host: "localhost", port: 9096))
        #expect(!matches(local, host: "localhost", port: 9095))
    }

    @Test func actsOnlyWhenTheRuleAndItsKindAreOn() {
        let block = Rule(name: "No ads", match: RequestMatch(host: "*.ads.dev"), action: .block(.status(403)))
        var off = block
        off.isOn = false
        let breakpoint = Rule(name: "Forecast", match: RequestMatch(path: "/v2/*"), action: .breakpoint(.response))
        var rules = RuleSet(rules: [block, off, breakpoint], kindsOn: [.block])
        #expect(rules.matching(method: "GET", host: "x.ads.dev", port: 443, target: "/").map(\.name) == ["No ads"])
        #expect(rules.matching(method: "GET", host: "api.weatherly.dev", port: 443, target: "/v2/forecast").isEmpty)
        rules.kindsOn.insert(.breakpoint)
        #expect(
            rules.matching(method: "GET", host: "api.weatherly.dev", port: 443, target: "/v2/forecast").map(\.name)
                == ["Forecast"])
    }

    @Test func slowsDownTheHostsItNames() {
        var rules = RuleSet(network: NetworkConditions(profile: .threeG, hosts: ["*.weatherly.dev"]))
        #expect(rules.networkConditions(for: "api.weatherly.dev") == nil)
        rules.kindsOn.insert(.slowNetwork)
        #expect(rules.networkConditions(for: "api.weatherly.dev") == .threeG)
        #expect(rules.networkConditions(for: "www.apple.com") == nil)
        rules.network.hosts = []
        #expect(rules.networkConditions(for: "www.apple.com") == .threeG)
    }

    @Test func survivesSavingAndLoading() throws {
        let rules = RuleSet(
            rules: [
                Rule(
                    name: "Staging", match: RequestMatch(host: "api.weatherly.dev"),
                    action: .mapRemote(MapRemote(destination: "https://staging.weatherly.dev"))),
                Rule(
                    name: "No cache", match: RequestMatch(),
                    action: .rewrite([.setHeader(.response, name: "Cache-Control", value: "no-store"), .setStatus(503)])
                ),
            ],
            kindsOn: [.mapRemote, .slowNetwork], network: NetworkConditions(profile: .lossy))
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(RuleSet.self, from: data) == rules)
    }
}

@Suite struct RuleSavingTests {
    @Test func savesEachKindOfRuleAsPlainJSON() throws {
        let rules = RuleSet(
            rules: [
                Rule(
                    name: "Forecast",
                    match: RequestMatch(host: "api.weatherly.dev", path: "/v2/forecast*", method: "GET"),
                    action: .breakpoint(.response)),
                Rule(name: "Sunny", match: RequestMatch(), action: .mapLocal(MapLocal(path: "~/sunny.json"))),
                Rule(
                    name: "Staging", isOn: false, match: RequestMatch(host: "api.weatherly.dev"),
                    action: .mapRemote(MapRemote(destination: "https://staging.weatherly.dev"))),
                Rule(
                    name: "Tweaks", match: RequestMatch(),
                    action: .rewrite([
                        .setHeader(.request, name: "X-Debug", value: "1"),
                        .removeHeader(.response, name: "Cache-Control"),
                        .setQueryParameter(name: "units", value: "metric"), .removeQueryParameter(name: "token"),
                        .replaceBody(.response, find: "rain", replace: "sun"), .setStatus(503),
                    ])),
                Rule(name: "No ads", match: RequestMatch(host: "*.ads.example"), action: .block(.status(403))),
                Rule(name: "Offline", match: RequestMatch(), action: .block(.closeConnection)),
            ],
            kindsOn: [.rewrite, .breakpoint, .slowNetwork],
            network: NetworkConditions(profile: .lossy, hosts: ["*.weatherly.dev"]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rules)
        #expect(try JSONDecoder().decode(RuleSet.self, from: data) == rules)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""action":{"phase":"response","type":"breakpoint"}"#))
        #expect(text.contains(#"{"name":"X-Debug","part":"request","type":"setHeader","value":"1"}"#))
        #expect(text.contains(#""action":{"answer":"closeConnection","type":"block"}"#))
        // The kinds that are on keep one order, so the same rules always save the same way.
        #expect(text.contains(#""kindsOn":["breakpoint","rewrite","slowNetwork"]"#))
        #expect(!text.contains("_0"))
    }
}

@Suite struct UserAgentTests {
    @Test func namesTheAppThatSentARequest() {
        func app(_ userAgent: String) -> Source? { UserAgent.app(from: userAgent) }
        #expect(app("Weather/1 CFNetwork/1498.700.2 Darwin/23.6.0") == Source(name: "Weather"))
        #expect(app("Google%20Maps/6.110.0 CFNetwork/1498.700.2 Darwin/23.6.0") == Source(name: "Google Maps"))
        #expect(
            app("nsurlsessiond (unknown version) CFNetwork/1498.700.2 Darwin/23.6.0") == Source(name: "nsurlsessiond"))
        #expect(
            app("com.apple.appstored/1.0 iOS/18.0 model/iPhone16,2 hwp/t8130 build/22A3354 (6; dt:311) AMS/1")
                == Source(name: "com.apple.appstored", bundleID: "com.apple.appstored"))
        #expect(app("Spotify/8.9.30 iOS/18.0 (iPhone16,2)") == Source(name: "Spotify"))
    }

    @Test func namesBrowsersButNotWebViews() {
        func app(_ userAgent: String) -> String? { UserAgent.app(from: userAgent)?.name }
        let safari =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        #expect(app(safari) == "Safari")
        let chrome =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/129.0.6668.69 Mobile/15E148 Safari/604.1"
        #expect(app(chrome) == "Chrome")
        let android =
            "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36"
        #expect(app(android) == "Chrome")
        // A web view inside an app looks like a browser, but names no app.
        let webView =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        #expect(app(webView) == nil)
        let androidWebView =
            "Mozilla/5.0 (Linux; Android 15; Pixel 9 Build/AP3A.241005.015; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/129.0.0.0 Mobile Safari/537.36"
        #expect(app(androidWebView) == nil)
    }

    @Test func leavesLibrariesAndNothingAlone() {
        #expect(UserAgent.app(from: "okhttp/4.12.0") == nil)
        #expect(UserAgent.app(from: "Dalvik/2.1.0 (Linux; U; Android 15; Pixel 9 Build/AP3A.241005.015)") == nil)
        #expect(UserAgent.app(from: "CFNetwork/1498.700.2 Darwin/23.6.0") == nil)
        #expect(UserAgent.app(from: "") == nil)
        #expect(UserAgent.app(from: nil) == nil)
    }
}

@Suite struct GRPCStatusTests {
    @Test func readsTheStatusFromTrailersOrHeaders() {
        let trailers: Headers = ["grpc-status": "5", "grpc-message": "No%20such%20city"]
        let status = GRPCStatus(response: ResponseHead(status: 200, reason: "OK"), trailers: trailers)
        #expect(status == GRPCStatus(code: 5, message: "No such city"))
        #expect(status?.name == "NOT_FOUND")
        #expect(status?.title == "Not found")
        #expect(status?.statusClass == .clientError)
        // A call that fails at once sends its status with the headers, and no body.
        let headersOnly = ResponseHead(status: 200, reason: "OK", headers: ["grpc-status": "14"])
        #expect(GRPCStatus(response: headersOnly, trailers: nil)?.statusClass == .serverError)
        #expect(GRPCStatus(response: ResponseHead(status: 200, reason: "OK"), trailers: nil) == nil)
        #expect(GRPCStatus(code: 99).name == "Code 99")
    }

    @Test func colorsAFailedCallAsAFailure() {
        var exchange = Exchange(
            id: ExchangeID(rawValue: 1), connectionID: ConnectionID(rawValue: 1), kind: .http,
            request: RequestHead(method: "POST", scheme: "https", host: "api.weatherly.dev", port: 443, target: "/x"),
            started: Date())
        exchange.response = ResponseHead(status: 200, reason: "OK", headers: ["content-type": "application/grpc"])
        #expect(exchange.summary.statusClass == .success)
        exchange.responseTrailers = ["grpc-status": "13"]
        #expect(exchange.summary.grpcStatus == 13)
        #expect(exchange.summary.statusClass == .serverError)
        exchange.responseTrailers = ["grpc-status": "0"]
        #expect(exchange.summary.statusClass == .success)
    }
}

@Suite struct CookieTests {
    @Test func readsTheCookiesAnAppSent() {
        let headers: Headers = ["Cookie": "session=abc; theme=dark", "Cookie": "flag"]
        #expect(
            headers.requestCookies == [
                RequestCookie(name: "session", value: "abc"), RequestCookie(name: "theme", value: "dark"),
                RequestCookie(name: "", value: "flag"),
            ])
    }

    @Test func readsTheCookiesAServerSet() throws {
        let headers: Headers = [
            "Set-Cookie": "id=a3fWa; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure; HttpOnly; Path=/; SameSite=Lax",
            "Set-Cookie": "token=x=y; Max-Age=3600; Domain=.weatherly.dev; Partitioned",
            "Set-Cookie": "=nameless",
        ]
        let cookies = headers.responseCookies
        #expect(cookies.count == 2)
        let id = try #require(cookies.first)
        #expect(id.name == "id")
        #expect(id.value == "a3fWa")
        #expect(id.isSecure && id.isHTTPOnly && id.sameSite == "Lax" && id.path == "/")
        #expect(id.expiryDate == Date(timeIntervalSince1970: 1_792_567_680))
        #expect(id.attributes == ["Path /", "Secure", "HttpOnly", "SameSite Lax"])
        let token = cookies[1]
        #expect(token.value == "x=y")
        #expect(token.maxAge == 3600)
        #expect(token.domain == ".weatherly.dev")
        #expect(token.isPartitioned)
        #expect(token.expiryDate == nil)
    }

    @Test func readsTheOlderDateForms() {
        let rfc850 = ResponseCookie(setCookie: "a=1; expires=Wednesday, 21-Oct-26 07:28:00 GMT")
        let asctime = ResponseCookie(setCookie: "a=1; expires=Wed Oct 21 07:28:00 2026")
        #expect(rfc850?.expiryDate == Date(timeIntervalSince1970: 1_792_567_680))
        #expect(asctime?.expiryDate == Date(timeIntervalSince1970: 1_792_567_680))
    }
}

@Suite struct AppVersionTests {
    @Test func comparesNumberByNumber() throws {
        let version = try #require(AppVersion("1.10"))
        #expect(version > AppVersion("1.9")!)
        #expect(AppVersion("v1.2.0") == AppVersion("1.2"))
        #expect(AppVersion("1.2")! < AppVersion("1.2.1")!)
        #expect(version.description == "1.10")
        #expect(Set([AppVersion("1.2")!, AppVersion("1.2.0")!]).count == 1)
    }

    @Test(arguments: ["", "v", "1.x", "1..2", "1.2-beta", "-1"])
    func rejectsWhatIsNotAVersion(_ text: String) {
        #expect(AppVersion(text) == nil)
    }
}
