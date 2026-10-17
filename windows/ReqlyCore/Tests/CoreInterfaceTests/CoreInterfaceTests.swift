import Capture
import Foundation
import Presentation
import ProxyEngine
import ReqlyCore
import ReqlyModel
import Synchronization
import Testing
import TrafficStore
import WindowsSystem

@testable import CoreInterface

/// The events a session sent, as the app would get them.
final class EventLog: Sendable {
    private let events = Mutex<[Data]>([])

    func record(_ json: Data) {
        events.withLock { $0.append(json) }
    }

    var all: [[String: Any]] {
        events.withLock { $0 }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// Waits up to five seconds for an event that `matches` says is the one.
    func wait(for matches: ([String: Any]) -> Bool) async -> [String: Any]? {
        for _ in 0..<500 {
            if let event = all.last(where: matches) {
                return event
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

/// Made-up exchanges, saved as a session file the tests open.
enum Saved {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func exchange(_ id: UInt64, target: String, body: String) -> Exchange {
        var exchange = Exchange(
            id: ExchangeID(rawValue: id),
            connectionID: ConnectionID(rawValue: 1),
            kind: .http,
            request: RequestHead(
                method: "GET", scheme: "https", host: "api.weatherly.dev", port: 443, target: target,
                headers: ["Accept": "application/json"]),
            started: start + Double(id)
        )
        exchange.response = ResponseHead(status: 200, reason: "OK", headers: ["Content-Type": "application/json"])
        exchange.responseBody = Data(body.utf8)
        exchange.state = .completed
        exchange.timing.ended = start + Double(id) + 0.25
        return exchange
    }

    static let exchanges = [
        exchange(1, target: "/v2/forecast?city=Tehran", body: #"{"city":"Tehran","wind":"light"}"#),
        exchange(2, target: "/v2/cities", body: #"["Tehran","Lisbon"]"#),
        exchange(3, target: "/v2/forecast?city=Oslo", body: #"{"city":"Oslo","wind":"strong"}"#),
    ]

    /// A folder for a test's sessions, and a saved session in it.
    static func file(with exchanges: [Exchange] = exchanges) async throws -> (folder: URL, file: URL) {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        let store = try await TrafficStore.newSession(in: folder.appending(path: "Made"), with: exchanges)
        let file = folder.appending(path: "Weather.reqly")
        try await store.saveSession(to: file, hidingSecrets: false)
        store.discard()
        return (folder, file)
    }
}

/// Reads a reply's result, or fails the test with its problem.
func result(_ reply: Data) throws -> [String: Any] {
    let object = try #require((try JSONSerialization.jsonObject(with: reply)) as? [String: Any])
    if let problem = object["problem"] {
        Issue.record("The call failed: \(problem)")
    }
    return try #require(object["result"] as? [String: Any])
}

func problem(_ reply: Data) throws -> String? {
    let object = try #require((try JSONSerialization.jsonObject(with: reply)) as? [String: Any])
    return (object["problem"] as? [String: Any])?["code"] as? String
}

func call(_ host: SessionHost, _ json: String) async -> Data {
    await host.reply(to: Data(json.utf8))
}

@Suite struct CallTests {
    func parse(_ json: String) -> Result<Call, Problem> {
        Result { () throws(Problem) in try Call(json: Data(json.utf8)) }
    }

    @Test func readsEachCall() throws {
        #expect(try parse(#"{"call":"version"}"#).get() == .version)
        #expect(try parse(#"{"call":"startCapturing","port":9090}"#).get() == .startCapturing(port: 9090))
        #expect(try parse(#"{"call":"rows","ids":[3,1]}"#).get() == .rows(ids: [3, 1]))
        #expect(try parse(#"{"call":"trafficSummary"}"#).get() == .trafficSummary)
        #expect(try parse(#"{"call":"setSearch","text":"Tehran"}"#).get() == .setSearch(text: "Tehran"))
        let present = #"{"call":"presentBody","id":2,"part":"request"}"#
        #expect(try parse(present).get() == .presentBody(id: 2, part: .request))
        let weatherly = try #require(HostPattern(rawValue: "*.weatherly.dev"))
        let switched = #"{"call":"setHostDecrypted","pattern":"*.Weatherly.dev","isOn":false}"#
        #expect(try parse(switched).get() == .setHostDecrypted(weatherly, isOn: false))
        let removed = #"{"call":"removeDecryptedHosts","patterns":["*.weatherly.dev"]}"#
        #expect(try parse(removed).get() == .removeDecryptedHosts([weatherly]))
        #expect(try parse(#"{"call":"decryptHost","host":"x.dev"}"#).get() == .decryptHost("x.dev"))
        // A host that isn't one, from a settings file edited by hand, leaves the rest.
        let saved = """
            {"call":"setDecryptedHosts","hosts":{"entries":[{"pattern":"not a host","isOn":true},\
            {"pattern":"*.weatherly.dev","isOn":false}],"includesEveryHost":true}}
            """
        let hosts = DecryptedHosts(entries: [.init(weatherly, isOn: false)], includesEveryHost: true)
        #expect(try parse(saved).get() == .setDecryptedHosts(hosts))
    }

    @Test func saysWhatsWrongWithARequest() {
        func code(_ json: String) -> Problem.Code? {
            if case .failure(let problem) = parse(json) { problem.code } else { nil }
        }
        #expect(code("not json") == .badRequest)
        #expect(code(#"{"port":1}"#) == .badRequest)
        #expect(code(#"{"call":"fly"}"#) == .unknownCall)
        #expect(code(#"{"call":"startCapturing"}"#) == .badRequest)
        #expect(code(#"{"call":"presentBody","id":2,"part":"trailer"}"#) == .badRequest)
        #expect(code(#"{"call":"removeDecryptedHosts","patterns":["not a host"]}"#) == .badRequest)
    }
}

@Suite struct SessionHostTests {
    @Test func opensASavedSessionAndShowsItsRows() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: log.record)

        let first = try #require(await log.wait { $0["event"] as? String == "rows" })
        #expect(first["total"] as? Int == 3)
        #expect(first["shown"] as? Int == 3)
        let steps = try #require(first["steps"] as? [[String: Any]])
        let inserted = try #require(steps.first?["inserted"] as? [[String: Any]])
        #expect(inserted.map { $0["id"] as? Int } == [1, 2, 3])
        #expect(inserted.map { $0["row"] as? Int } == [0, 1, 2])

        #expect(try result(await call(host, #"{"call":"version"}"#))["version"] as? Int == interfaceVersion)
        let ids = try result(await call(host, #"{"call":"rowIDs"}"#))
        #expect(ids["ids"] as? [Int] == [1, 2, 3])
        #expect(ids["version"] as? Int == first["version"] as? Int)

        let reply = try result(await call(host, #"{"call":"rows","ids":[2,9]}"#))
        let rows = try #require(reply["rows"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["target"] as? String == "/v2/cities")
        #expect(rows.first?["state"] as? String == "completed")
        #expect(rows.first?["status"] as? Int == 200)
        await host.close()
    }

    @Test func sumsUpEveryExchangeWhateverTheListShows() async throws {
        var exchanges = Saved.exchanges
        for index in exchanges.indices {
            exchanges[index].bytesSent = 100
            exchanges[index].bytesReceived = 1_000 * Int64(index + 1)
        }
        let (folder, file) = try await Saved.file(with: exchanges)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: log.record)
        _ = await log.wait { $0["event"] as? String == "rows" }

        _ = try result(await call(host, #"{"call":"setSearch","text":"cities"}"#))
        _ = await log.wait { $0["shown"] as? Int == 1 }
        let summary = try result(await call(host, #"{"call":"trafficSummary"}"#))
        #expect(summary["total"] as? Int == 3)
        #expect(summary["bytes"] as? Int == 6_300)
        let newest = try #require(summary["newest"] as? [String: Any])
        #expect(newest["target"] as? String == "/v2/forecast?city=Oslo")
        await host.close()
    }

    @Test func sumsUpAnEmptySession() async throws {
        let (folder, file) = try await Saved.file(with: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: { _ in })

        let summary = try result(await call(host, #"{"call":"trafficSummary"}"#))
        #expect(summary["total"] as? Int == 0)
        #expect(summary["bytes"] as? Int == 0)
        #expect(summary["newest"] == nil)
        await host.close()
    }

    @Test func searchesTheListThenTheStore() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: log.record)
        _ = await log.wait { $0["event"] as? String == "rows" }

        // "cities" is in one request's path, which the list checks at once.
        _ = try result(await call(host, #"{"call":"setSearch","text":"cities"}"#))
        let narrowed = try #require(await log.wait { $0["shown"] as? Int == 1 })
        #expect((narrowed["steps"] as? [[String: Any]])?.first?["removed"] as? [Int] == [0, 2])

        // "Lisbon" is only in a body, which the store finds a moment later.
        _ = try result(await call(host, #"{"call":"setSearch","text":"Lisbon"}"#))
        let found = try #require(
            await log.wait { event in
                let steps = event["steps"] as? [[String: Any]] ?? []
                return event["shown"] as? Int == 1 && steps.contains { $0["inserted"] != nil }
            })
        let inserted = (found["steps"] as? [[String: Any]])?.compactMap { $0["inserted"] as? [[String: Any]] }.first
        #expect(inserted?.first?["id"] as? Int == 2)

        _ = try result(await call(host, #"{"call":"setSearch","text":""}"#))
        #expect(await log.wait { $0["shown"] as? Int == 3 } != nil)
        await host.close()
    }

    @Test func givesDetailsAndBodies() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: { _ in })

        let details = try result(await call(host, #"{"call":"details","id":1}"#))
        let url = try #require(details["url"] as? String)
        #expect(url.hasPrefix("https://api.weatherly.dev") && url.hasSuffix("/v2/forecast?city=Tehran"))
        #expect(details["responseBodySize"] as? Int == 32)
        #expect((details["responseHeaders"] as? [[String: Any]])?.first?["value"] as? String == "application/json")
        #expect(details["path"] as? String == "/v2/forecast")
        let query = try #require(details["query"] as? [[String: Any]])
        #expect(query.map { "\($0["name"] ?? "")=\($0["value"] ?? "")" } == ["city=Tehran"])
        let started = try #require(details["started"] as? Double)
        #expect(abs(started - (Saved.start.timeIntervalSince1970 + 1)) < 0.001)
        #expect(details["kind"] as? String == "http")
        #expect(details["host"] as? String == "api.weatherly.dev")
        #expect(details["decryption"] as? String == "decrypted")

        let body = try result(await call(host, #"{"call":"presentBody","id":1,"part":"response"}"#))
        #expect(body["kind"] as? String == "JSON")
        #expect(body["modes"] as? [String] == ["formatted", "tree", "raw", "hex"])
        // Short objects stay on one line, laid out with spaces.
        let formatted = try #require(body["formatted"] as? [String: Any])
        #expect((formatted["text"] as? String)?.contains(#""city": "Tehran""#) == true)
        // Each token is its place, its length and its kind.
        let tokens = try #require(formatted["tokens"] as? [[Any]])
        #expect(tokens.contains { $0.last as? String == "key" })
        let nodes = try #require((body["tree"] as? [String: Any])?["nodes"] as? [[String: Any]])
        #expect(nodes.map { $0["label"] as? String } == ["Response", "city", "wind"])
        let node = try result(await call(host, #"{"call":"bodyNode","id":1,"part":"response","node":1}"#))
        #expect(node["path"] as? String == "city" && node["copy"] as? String == "Tehran")

        let raw = try result(await call(host, #"{"call":"raw","id":1}"#))
        let rawRequest = try #require((raw["request"] as? [String: Any])?["text"] as? String)
        #expect(rawRequest.hasPrefix("GET /v2/forecast?city=Tehran HTTP/1.1\nAccept: application/json\n"))
        #expect(raw["hasSecrets"] as? Bool == false)
        #expect(await host.body(1, part: .response, offset: 0, limit: 8, unpacked: true) == Data(#"{"city":"#.utf8))

        let bytes = await host.body(1, part: .response, offset: 2, limit: 4)
        #expect(bytes == Data("city".utf8))
        #expect(await host.body(1, part: .response, offset: 99, limit: 4) == nil)
        #expect(await host.body(7, part: .response, offset: 0, limit: 4) == nil)

        #expect(try problem(await call(host, #"{"call":"details","id":7}"#)) == "notFound")
        #expect(try problem(await call(host, #"{"call":"nope"}"#)) == "unknownCall")
        await host.close()
    }

    @Test func startsAndStopsCapturing() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(OpenOptions(sessionsFolder: folder.path), send: { _ in })
        // Port 0 picks a free one. Only this computer can connect.
        let port = try #require(try result(await call(host, #"{"call":"startCapturing","port":0}"#))["port"] as? Int)
        #expect(port > 0)
        #expect(await host.capture.isCapturing)
        _ = try result(await call(host, #"{"call":"stopCapturing"}"#))
        #expect(await host.capture.isCapturing == false)
        await host.close()
        // Closing lets go of the session's folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

@Suite struct ComposerTests {
    @Test func fillsADraftFromARequestAndChecksTheURL() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: { _ in })
        let draft = try result(await call(host, #"{"call":"draft","id":1}"#))
        #expect(draft["method"] as? String == "GET")
        #expect((draft["url"] as? String)?.hasSuffix("/v2/forecast?city=Tehran") == true)
        #expect((draft["headers"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Accept"])
        #expect(draft["body"] as? String == "")
        let bad = await call(
            host, #"{"call":"send","request":{"method":"GET","url":"ftp://example.com","headers":[]}}"#)
        #expect(try problem(bad) == "badRequest")
        #expect(String(decoding: bad, as: UTF8.self).contains("Enter a URL that starts with http:// or https://."))
        await host.close()
    }

    @Test func sendsAndResendsRequestsYouWrite() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), send: log.record)
        // .invalid never resolves, so nothing leaves the computer.
        let sent = try result(
            await call(
                host,
                #"{"call":"send","request":{"method":"POST","url":"weather.invalid/v2/report","headers":[{"name":"X-Kept","value":"1"},{"name":"X-Off","value":"2","isOn":false}],"body":"sunny"}}"#
            ))
        let id = try #require(sent["id"] as? Int)
        #expect(await log.wait { $0["event"] as? String == "rows" && $0["total"] as? Int == 1 } != nil)
        var details: [String: Any] = [:]
        for _ in 0..<200 {
            details = try result(await call(host, #"{"call":"details","id":\#(id)}"#))
            if details["state"] as? String == "failed" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(details["url"] as? String == "https://weather.invalid/v2/report")
        #expect(details["sentByReqly"] as? Bool == true)
        let headers = (details["requestHeaders"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(headers.contains("X-Kept") && !headers.contains("X-Off"))
        let again = try result(await call(host, #"{"call":"resend","id":\#(id)}"#))
        #expect((again["id"] as? Int).map { $0 != id } == true)
        #expect(await log.wait { $0["event"] as? String == "rows" && $0["total"] as? Int == 2 } != nil)
        await host.close()
    }
}

@Suite struct RuleTests {
    @Test func holdsARequestAtABreakpointUntilYouDecide() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), send: log.record)
        let rules = RuleSet(
            rules: [
                Rule(
                    id: UUID(), name: "Hold the weather", isOn: true, match: RequestMatch(host: "weather.invalid"),
                    action: .breakpoint(.request))
            ], kindsOn: [.breakpoint])
        let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        _ = try result(await call(host, #"{"call":"setRules","rules":\#(json)}"#))

        // .invalid never resolves, so nothing leaves the computer.
        let request =
            #"{"call":"send","request":{"method":"GET","url":"https://weather.invalid/v2/forecast","headers":[]}}"#
        let id = try #require(try result(await call(host, request))["id"] as? Int)
        let paused = try #require(await log.wait { $0["event"] as? String == "paused" })
        let held = try #require(paused["paused"] as? [String: Any])
        #expect(held["id"] as? Int == id && held["part"] as? String == "request")
        #expect(held["breakpoint"] as? String == "Hold the weather")
        #expect(held["url"] as? String == "https://weather.invalid/v2/forecast")

        let bad = await call(host, #"{"call":"decide","id":\#(id),"edit":{"url":"ftp://weather.invalid/"}}"#)
        #expect(try problem(bad) == "badRequest")
        #expect(String(decoding: bad, as: UTF8.self).contains("Enter a URL that starts with http:// or https://."))
        _ = try result(
            await call(host, #"{"call":"decide","id":\#(id),"edit":{"url":"https://weather.invalid/v2/edited"}}"#))
        #expect(await log.wait { $0["event"] as? String == "resumed" && $0["id"] as? Int == id } != nil)
        var details = await Self.failed(host, id)
        // The request shows as it came, and the rule says what you changed before it went on.
        let applied = try #require((details["appliedRules"] as? [[String: Any]])?.first)
        #expect(applied["kind"] as? String == "breakpoint" && applied["name"] as? String == "Hold the weather")
        #expect((applied["detail"] as? String)?.isEmpty == false)

        let second = try #require(try result(await call(host, request))["id"] as? Int)
        #expect(await log.wait { ($0["paused"] as? [String: Any])?["id"] as? Int == second } != nil)
        _ = try result(await call(host, #"{"call":"decide","id":\#(second)}"#))
        details = await Self.failed(host, second)
        #expect(details["failure"] as? String == "You cancelled this request at a breakpoint.")
        #expect(try problem(await call(host, #"{"call":"decide","id":\#(second)}"#)) == "notFound")
        await host.close()
    }

    @Test func letsHeldRequestsGoOnWhenYouClear() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), send: log.record)
        let rules = RuleSet(
            rules: [
                Rule(
                    id: UUID(), name: "Hold the weather", isOn: true, match: RequestMatch(host: "weather.invalid"),
                    action: .breakpoint(.request))
            ], kindsOn: [.breakpoint])
        let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        _ = try result(await call(host, #"{"call":"setRules","rules":\#(json)}"#))
        let request =
            #"{"call":"send","request":{"method":"GET","url":"https://weather.invalid/v2/forecast","headers":[]}}"#
        let id = try #require(try result(await call(host, request))["id"] as? Int)
        #expect(await log.wait { ($0["paused"] as? [String: Any])?["id"] as? Int == id } != nil)

        // Clearing takes the request's row away, and with it the only way to decide, so it goes on as it came.
        _ = try result(await call(host, #"{"call":"clear"}"#))
        #expect(await log.wait { $0["event"] as? String == "resumed" && $0["id"] as? Int == id } != nil)
        #expect(try problem(await call(host, #"{"call":"decide","id":\#(id)}"#)) == "notFound")
        await host.close()
    }

    /// An exchange's details once it has failed, waiting up to five seconds. Until the store has
    /// it, the session has no such exchange.
    static func failed(_ host: SessionHost, _ id: Int) async -> [String: Any] {
        var details: [String: Any] = [:]
        for _ in 0..<200 {
            let reply = await call(host, #"{"call":"details","id":\#(id)}"#)
            let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            details = object?["result"] as? [String: Any] ?? [:]
            if details["state"] as? String == "failed" { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return details
    }

    @Test func checksScripts() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), send: { _ in })
        let fine = try result(
            await call(host, #"{"call":"checkScript","code":"function onRequest(request) { return request }"}"#))
        #expect(fine["problem"] is NSNull)
        let broken = try result(await call(host, #"{"call":"checkScript","code":"function onRequest( {"}"#))
        #expect((broken["problem"] as? String)?.isEmpty == false)
        await host.close()
    }

    @Test func colorsScripts() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), send: { _ in })
        // In UTF-16 code units, so the é counts once.
        let code = "// é\nfunction onRequest(r) { return \"ok\" }"
        let request = try JSONSerialization.data(withJSONObject: ["call": "highlightScript", "code": code])
        let reply = try result(await host.reply(to: request))
        let tokens = try #require(reply["tokens"] as? [[Any]])
        let found = tokens.compactMap { token -> String? in
            guard let location = token[0] as? Int, let length = token[1] as? Int, let kind = token[2] as? String
            else { return nil }
            return "\(kind) \(location) \(length)"
        }
        #expect(found == ["comment 0 4", "keyword 5 8", "keyword 29 6", "string 36 4"])
        await host.close()
    }
}

/// A reply's result that's a list, or fails the test with its problem.
func results(_ reply: Data) throws -> [[String: Any]] {
    let object = try #require((try JSONSerialization.jsonObject(with: reply)) as? [String: Any])
    if let problem = object["problem"] {
        Issue.record("The call failed: \(problem)")
    }
    return try #require(object["result"] as? [[String: Any]])
}

/// A call, written as JSON from its fields.
func call(_ host: SessionHost, _ fields: [String: Any]) async -> Data {
    let json = try! JSONSerialization.data(withJSONObject: fields)
    return await host.reply(to: json)
}

@Suite struct RulesWindowTests {
    /// A session of saved traffic, and a rules file that isn't there yet.
    static func open() async throws -> (host: SessionHost, folder: URL, rulesFile: URL) {
        let (folder, file) = try await Saved.file()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: { _ in })
        return (host, folder, folder.appending(path: "Settings/Rules.json"))
    }

    @Test func makesARuleFromARequestAndKeepsItInTheRulesFile() async throws {
        let (host, folder, rulesFile) = try await Self.open()
        defer { try? FileManager.default.removeItem(at: folder) }
        var rules = try result(
            await call(host, ["call": "openRules", "path": rulesFile.path(percentEncoded: false)]))
        #expect((rules["rules"] as? [Any])?.isEmpty == true && (rules["kindsOn"] as? [Any])?.isEmpty == true)
        #expect(rules["problem"] == nil)
        #expect(((rules["network"] as? [String: Any])?["profile"] as? [String: Any])?["name"] as? String == "3G")

        var draft = try result(await call(host, ["call": "newRuleDraft", "kind": "mapRemote", "id": 1]))
        #expect(draft["isNew"] as? Bool == true && draft["exchange"] as? Int == 1)
        #expect(draft["host"] as? String == "api.weatherly.dev" && draft["path"] as? String == "/v2/forecast")
        #expect(draft["method"] as? String == "GET" && draft["destination"] as? String == "https://api.weatherly.dev")
        draft["destination"] = "staging"
        let check = try result(await call(host, ["call": "checkRuleDraft", "draft": draft]))
        #expect(check["problem"] as? String == "Enter a URL that starts with http:// or https://.")
        #expect(check["defaultName"] as? String == "api.weatherly.dev/v2/forecast")
        // Two of the three requests are for the forecast; the script's list is for scripts only.
        #expect(check["matchCount"] as? Int == 2 && check["matching"] == nil)
        #expect(try problem(await call(host, ["call": "saveRuleDraft", "draft": draft])) == "badRequest")

        draft["destination"] = "https://staging.weatherly.dev"
        rules = try result(await call(host, ["call": "saveRuleDraft", "draft": draft]))
        let row = try #require((rules["rules"] as? [[String: Any]])?.first)
        #expect(row["kind"] as? String == "mapRemote" && row["name"] as? String == "api.weatherly.dev/v2/forecast")
        #expect(row["match"] as? String == "GET · api.weatherly.dev/v2/forecast")
        #expect(row["tag"] as? String == "staging.weatherly.dev" && row["isOn"] as? Bool == true)
        // A rule you just made acts, so its kind comes on with it.
        #expect(rules["kindsOn"] as? [String] == ["mapRemote"])
        // The file is the one the Mac keeps.
        let saved = try RulesFile.load(from: rulesFile)
        #expect(
            saved.kindsOn == [.mapRemote]
                && saved.rules.first?.action == .mapRemote(MapRemote(destination: "https://staging.weatherly.dev")))

        // Editing a saved rule starts from it as it is.
        let id = try #require(row["id"] as? String)
        var edit = try result(await call(host, ["call": "ruleDraft", "rule": id]))
        #expect(edit["isNew"] as? Bool == false && edit["destination"] as? String == "https://staging.weatherly.dev")
        edit["name"] = "Staging"
        _ = try result(await call(host, ["call": "rules"]))
        rules = try result(await call(host, ["call": "saveRuleDraft", "draft": edit]))
        #expect((rules["rules"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Staging"])
        #expect(try RulesFile.load(from: rulesFile).rules.map(\.name) == ["Staging"])

        let script = try result(await call(host, ["call": "newRuleDraft", "kind": "script"]))
        #expect(script["code"] as? String == ScriptExamples.starter)
        let tries = try result(await call(host, ["call": "checkRuleDraft", "draft": script]))
        #expect(tries["problem"] == nil && tries["matchCount"] as? Int == 3)
        let matching = try #require(tries["matching"] as? [[String: Any]])
        #expect(matching.map { $0["id"] as? Int } == [3, 2, 1])
        #expect(matching.first?["description"] as? String == "GET api.weatherly.dev/v2/forecast?city=Oslo · 200")
        #expect(try problem(await call(host, ["call": "newRuleDraft", "kind": "block", "id": 99])) == "notFound")
        #expect(try problem(await call(host, ["call": "newRuleDraft", "kind": "slowNetwork"])) == "badRequest")
        await host.close()
    }

    @Test func switchesMovesCopiesAndRemovesRules() async throws {
        let (host, folder, rulesFile) = try await Self.open()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try result(await call(host, ["call": "openRules", "path": rulesFile.path(percentEncoded: false)]))
        var ids: [String] = []
        for (name, status) in [("Ads", 403), ("Trackers", 451)] {
            var draft = try result(await call(host, ["call": "newRuleDraft", "kind": "block"]))
            draft["name"] = name
            draft["blockStatus"] = status
            let rules = try result(await call(host, ["call": "saveRuleDraft", "draft": draft]))
            ids = (rules["rules"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }
        var breakpoint = try result(await call(host, ["call": "newRuleDraft", "kind": "breakpoint"]))
        breakpoint["phase"] = "response"
        var rules = try result(await call(host, ["call": "saveRuleDraft", "draft": breakpoint]))
        func names(_ rules: [String: Any]) -> [String] {
            (rules["rules"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        }
        func tags(_ rules: [String: Any]) -> [String] {
            (rules["rules"] as? [[String: Any]])?.compactMap { $0["tag"] as? String } ?? []
        }
        #expect(names(rules) == ["Ads", "Trackers", "Any host"] && tags(rules) == ["403", "451", "Response"])
        #expect(rules["kindsOn"] as? [String] == ["breakpoint", "block"])

        // Moving a rule keeps it among the rules of its kind.
        rules = try result(await call(host, ["call": "moveRule", "rule": ids[1], "to": 0]))
        #expect(names(rules) == ["Trackers", "Ads", "Any host"])
        rules = try result(await call(host, ["call": "duplicateRule", "rule": ids[0]]))
        #expect(names(rules) == ["Trackers", "Ads", "Any host", "Ads copy"])
        rules = try result(await call(host, ["call": "moveRule", "rule": ids[1], "to": 9]))
        #expect(names(rules) == ["Ads", "Ads copy", "Any host", "Trackers"])

        rules = try result(await call(host, ["call": "setRuleOn", "rule": ids[0], "isOn": false]))
        #expect((rules["rules"] as? [[String: Any]])?.first?["isOn"] as? Bool == false)
        rules = try result(await call(host, ["call": "setRuleKindOn", "kind": "breakpoint", "isOn": false]))
        #expect(rules["kindsOn"] as? [String] == ["block"])
        rules = try result(await call(host, ["call": "removeRules", "ruleIDs": [ids[0], ids[1]]]))
        #expect(names(rules) == ["Ads copy", "Any host"])

        let lte = try #require(
            try results(await call(host, ["call": "networkPresets"])).first { $0["name"] as? String == "LTE" })
        #expect(lte["downloadBytesPerSecond"] as? Int == 1_500_000 && lte["latency"] as? Int == 50)
        rules = try result(
            await call(host, ["call": "setNetwork", "network": ["profile": lte, "hosts": ["*.weatherly.dev"]]]))
        #expect((rules["network"] as? [String: Any])?["hosts"] as? [String] == ["*.weatherly.dev"])
        rules = try result(await call(host, ["call": "setRuleKindOn", "kind": "slowNetwork", "isOn": true]))
        let saved = try RulesFile.load(from: rulesFile)
        #expect(saved.network == NetworkConditions(profile: .lte, hosts: ["*.weatherly.dev"]))
        #expect(saved.kindsOn == [.block, .slowNetwork] && saved.rules.map(\.name) == ["Ads copy", "Any host"])

        let examples = try results(await call(host, ["call": "scriptExamples"]))
        #expect(examples.map { $0["id"] as? String } == ScriptExamples.all.map(\.id))
        await host.close()
    }

    @Test func leavesRulesItCantUseAsTheyAre() async throws {
        let (host, folder, rulesFile) = try await Self.open()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: rulesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"version": 3, "ruleSet": {"rules": []}}"#.utf8)
        try newer.write(to: rulesFile)
        var rules = try result(await call(host, ["call": "openRules", "path": rulesFile.path(percentEncoded: false)]))
        #expect((rules["problem"] as? String)?.hasPrefix("A newer version of Reqly saved the rules") == true)
        // Changes still act, but aren't saved over the newer Reqly's rules.
        rules = try result(await call(host, ["call": "setRuleKindOn", "kind": "breakpoint", "isOn": true]))
        #expect(rules["kindsOn"] as? [String] == ["breakpoint"])
        #expect(try Data(contentsOf: rulesFile) == newer)
        await host.close()
    }
}

@Suite struct ConnectionsTests {
    /// A live session that doesn't capture, with its own settings and plain secrets files.
    static func open(in existing: URL? = nil) async throws -> (host: SessionHost, folder: URL, file: URL, secrets: URL)
    {
        let folder = existing ?? URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), send: { _ in })
        return (host, folder, folder.appending(path: "Connections.json"), folder.appending(path: "Secrets.json"))
    }

    static func openConnections(_ host: SessionHost, _ file: URL, _ secrets: URL) async throws -> [String: Any] {
        try result(
            await call(
                host,
                [
                    "call": "openConnections", "path": file.path(percentEncoded: false),
                    "secretsPath": secrets.path(percentEncoded: false), "protectsSecrets": false,
                ]))
    }

    @Test func keepsTheUpstreamProxyAndItsPasswordApart() async throws {
        let opened = try await Self.open()
        var host = opened.host
        let (folder, file, secrets) = (opened.folder, opened.file, opened.secrets)
        defer { try? FileManager.default.removeItem(at: folder) }
        var connections = try await Self.openConnections(host, file, secrets)
        let blank = try #require(connections["upstreamProxy"] as? [String: Any])
        #expect(blank["isOn"] as? Bool == false && blank["bypassesLocalAddresses"] as? Bool == true)
        #expect(connections["activeUpstreamProxy"] == nil)

        var proxy: [String: Any] = [
            "isOn": true, "host": "", "port": "8080", "username": "parsa", "password": "hunter2",
            "bypass": "intranet.example.com", "bypassesLocalAddresses": true,
        ]
        let empty = try result(await call(host, ["call": "checkUpstreamProxy", "proxy": proxy, "proxyPort": 9090]))
        #expect(empty["problem"] as? String == "Enter the proxy's server.")
        #expect(
            try problem(await call(host, ["call": "setUpstreamProxy", "proxy": proxy, "proxyPort": 9090]))
                == "badRequest")
        proxy["host"] = "Proxy.Example.com"
        connections = try result(await call(host, ["call": "setUpstreamProxy", "proxy": proxy, "proxyPort": 9090]))
        #expect(connections["activeUpstreamProxy"] as? String == "proxy.example.com:8080")
        #expect((connections["upstreamProxy"] as? [String: Any])?["password"] as? String == "hunter2")
        // The settings are the Mac's file, without the password; the password is in the secrets file.
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("hunter2"))
        #expect(ConnectionsFile.load(from: file).contents.upstreamProxy?.host == "proxy.example.com")
        #expect(
            String(decoding: try Data(contentsOf: secrets), as: UTF8.self).contains(
                Data("hunter2".utf8).base64EncodedString()))
        await host.close()

        // Opened again, the password comes back with the rest.
        host = try await Self.open(in: folder).host
        connections = try await Self.openConnections(host, file, secrets)
        #expect((connections["upstreamProxy"] as? [String: Any])?["password"] as? String == "hunter2")
        #expect(connections["activeUpstreamProxy"] as? String == "proxy.example.com:8080")
        proxy["isOn"] = false
        proxy["username"] = ""
        connections = try result(await call(host, ["call": "setUpstreamProxy", "proxy": proxy, "proxyPort": 9090]))
        #expect(connections["activeUpstreamProxy"] == nil)
        #expect(
            !String(decoding: try Data(contentsOf: secrets), as: UTF8.self).contains(
                Data("hunter2".utf8).base64EncodedString()))
        await host.close()
    }

    @Test func addsChangesAndRemovesReverseProxies() async throws {
        let (host, folder, file, secrets) = try await Self.open()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await Self.openConnections(host, file, secrets)
        var proxy = try result(await call(host, ["call": "newReverseProxy", "proxyPort": 8080]))
        #expect(proxy["port"] as? String == "8081" && proxy["serverURL"] as? String == "")
        var check = try result(await call(host, ["call": "checkReverseProxy", "proxy": proxy, "proxyPort": 8080]))
        #expect(check["problem"] as? String == "Enter the server that requests go to." && check["note"] == nil)
        proxy["serverURL"] = "staging.weatherly.dev"
        check = try result(await call(host, ["call": "checkReverseProxy", "proxy": proxy, "proxyPort": 8080]))
        #expect(check["problem"] == nil)
        #expect(check["note"] as? String == "Apps that use http://localhost:8081 reach https://staging.weatherly.dev.")
        var connections = try result(await call(host, ["call": "saveReverseProxy", "proxy": proxy, "proxyPort": 8080]))
        var row = try #require((connections["reverseProxies"] as? [[String: Any]])?.first)
        #expect(
            row["localAddress"] as? String == "localhost:8081"
                && row["server"] as? String == "https://staging.weatherly.dev")
        // Not capturing, so nothing listens yet, and nothing's wrong.
        #expect(row["problem"] == nil)
        var second = try result(await call(host, ["call": "newReverseProxy", "proxyPort": 8080]))
        #expect(second["port"] as? String == "8082")
        second["port"] = "8081"
        second["serverURL"] = "https://api.weatherly.dev"
        #expect(
            try problem(await call(host, ["call": "saveReverseProxy", "proxy": second, "proxyPort": 8080]))
                == "badRequest")
        let id = try #require(row["id"] as? String)
        connections = try result(await call(host, ["call": "setReverseProxyOn", "reverseProxy": id, "isOn": false]))
        row = try #require((connections["reverseProxies"] as? [[String: Any]])?.first)
        #expect(row["isOn"] as? Bool == false)
        #expect(ConnectionsFile.load(from: file).contents.reverseProxies.first?.isOn == false)
        connections = try result(await call(host, ["call": "removeReverseProxy", "reverseProxy": id]))
        #expect((connections["reverseProxies"] as? [Any])?.isEmpty == true)
        await host.close()
    }

    @Test func readsAClientCertificateAndKeepsItsKeyApart() async throws {
        let opened = try await Self.open()
        var host = opened.host
        let (folder, file, secrets) = (opened.folder, opened.file, opened.secrets)
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await Self.openConnections(host, file, secrets)
        let pem = folder.appending(path: "client.pem")
        try Data((Self.certificate + Self.key).utf8).write(to: pem)
        let files = [pem.path(percentEncoded: false)]
        let hosts = try result(await call(host, ["call": "checkHosts", "text": "api.bank.dev, bad/host"]))
        #expect(hosts["problem"] as? String == "“bad/host” isn't a host name or a pattern such as *.example.com.")
        #expect(hosts["count"] as? Int == 1)
        let missing = await call(
            host, ["call": "addClientCertificate", "files": ["/nowhere/client.p12"], "hosts": "api.bank.dev"])
        #expect(String(decoding: missing, as: UTF8.self).contains("Reqly can't read this file as a certificate."))
        #expect(
            try problem(await call(host, ["call": "addClientCertificate", "files": files, "hosts": " "]))
                == "badRequest")
        var connections = try result(
            await call(
                host,
                ["call": "addClientCertificate", "files": files, "password": "", "hosts": "api.bank.dev, *.bank.dev"]))
        var certificate = try #require((connections["clientCertificates"] as? [[String: Any]])?.first)
        #expect(
            certificate["name"] as? String == "Reqly Test Client"
                && certificate["issuer"] as? String == "Reqly Test Client")
        #expect(certificate["hosts"] as? String == "api.bank.dev, *.bank.dev" && certificate["isOn"] as? Bool == true)
        #expect(certificate["isMissing"] as? Bool == false && certificate["hasExpired"] as? Bool == false)
        #expect((certificate["expires"] as? Double ?? 0) > Date().timeIntervalSince1970)
        let id = try #require(certificate["id"] as? String)
        // What the app shows of it is in the settings; its key is only in the secrets file.
        #expect(ConnectionsFile.load(from: file).contents.clientCertificates.first?.name == "Reqly Test Client")
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("PRIVATE"))
        #expect(
            String(decoding: try Data(contentsOf: secrets), as: UTF8.self).contains("Reqly Client Certificate/\(id)"))
        connections = try result(
            await call(host, ["call": "setClientCertificateHosts", "certificate": id, "hosts": "api.bank.dev"]))
        #expect((connections["clientCertificates"] as? [[String: Any]])?.first?["hosts"] as? String == "api.bank.dev")
        await host.close()

        // Opened again, it has its key, unless the secrets file lost it.
        host = try await Self.open(in: folder).host
        connections = try await Self.openConnections(host, file, secrets)
        certificate = try #require((connections["clientCertificates"] as? [[String: Any]])?.first)
        #expect(certificate["isMissing"] as? Bool == false && certificate["hosts"] as? String == "api.bank.dev")
        await host.close()
        try Data("{}".utf8).write(to: secrets)
        host = try await Self.open(in: folder).host
        connections = try await Self.openConnections(host, file, secrets)
        certificate = try #require((connections["clientCertificates"] as? [[String: Any]])?.first)
        #expect(certificate["isMissing"] as? Bool == true)
        connections = try result(await call(host, ["call": "removeClientCertificate", "certificate": id]))
        #expect((connections["clientCertificates"] as? [Any])?.isEmpty == true)
        await host.close()
    }

    /// A self-signed client certificate, "Reqly Test Client", as ProxyEngine's tests have it.
    static let certificate = """
        -----BEGIN CERTIFICATE-----
        MIIBRjCB7gIJAIYTvbQ1hBdlMAoGCCqGSM49BAMCMCwxGjAYBgNVBAMMEVJlcWx5
        IFRlc3QgQ2xpZW50MQ4wDAYDVQQKDAVSZXFseTAeFw0yNjEwMDMxNTU1NTBaFw0z
        NjA5MzAxNTU1NTBaMCwxGjAYBgNVBAMMEVJlcWx5IFRlc3QgQ2xpZW50MQ4wDAYD
        VQQKDAVSZXFseTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOXR0U4hcG0kJpmf
        5WRsSRu290nJ7vbdV2sD0iEbXUh2uqQe7AjlotiLlxsp+Ps6mYRv2ewgI8Ay7dmM
        eZryULEwCgYIKoZIzj0EAwIDRwAwRAIgNXAxdPGC/zm34w9Rr6FoYqQegMjcrX2u
        DME4oe8yp9wCIC1WHr02Rhwtpi2ixH+BOlzE5ae0IWkUQtRQCI7/fzvK
        -----END CERTIFICATE-----

        """

    static let key = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgT6wrIZbgL6OShGn1
        1y8SJ7exaMykd8qySvBgzh7VWKOhRANCAATl0dFOIXBtJCaZn+VkbEkbtvdJye72
        3VdrA9IhG11IdrqkHuwI5aLYi5cbKfj7OpmEb9nsICPAMu3ZjHma8lCx
        -----END PRIVATE KEY-----

        """
}

@Suite struct ProtobufTests {
    @Test func readsBodiesWithTheProtoFilesAndTheTypeYouChoose() async throws {
        var forecast = Saved.exchange(1, target: "/v1/forecast", body: "")
        forecast.response?.headers = ["Content-Type": "application/x-protobuf"]
        // A Forecast: city "Tehran" (field 1), days 3 (field 2).
        forecast.responseBody = Data([0x0A, 0x06] + Array("Tehran".utf8) + [0x10, 0x03])
        let (folder, file) = try await Saved.file(with: [forecast])
        defer { try? FileManager.default.removeItem(at: folder) }
        let protos = folder.appending(path: "protos/weather/v1")
        try FileManager.default.createDirectory(at: protos, withIntermediateDirectories: true)
        try Data(
            """
            syntax = "proto3";
            package weather.v1;
            message Forecast { string city = 1; int32 days = 2; }
            message Other { bool ok = 1; }
            """.utf8
        ).write(to: protos.appending(path: "forecast.proto"))
        // A library of its own, so other tests' sessions don't share it.
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path),
            protobuf: ProtobufLibrary(), send: { _ in })
        let list = folder.appending(path: "Protobuf.json")
        var protobuf = try result(await call(host, ["call": "openProtobuf", "path": list.path(percentEncoded: false)]))
        #expect((protobuf["sources"] as? [Any])?.isEmpty == true && protobuf["summary"] as? String == "")
        var body = try result(await call(host, #"{"call":"presentBody","id":1,"part":"response"}"#))
        #expect(body["readsAsProtobuf"] as? Bool == true && body["protobufType"] == nil)
        #expect(body["hasMessageTypes"] as? Bool == false)

        let source = folder.appending(path: "protos").path(percentEncoded: false)
        protobuf = try result(await call(host, ["call": "addProtobufSources", "paths": [source]]))
        let row = try #require((protobuf["sources"] as? [[String: Any]])?.first)
        #expect(row["isFolder"] as? Bool == true && row["count"] as? Int == 1 && row["name"] as? String == "protos")
        #expect(protobuf["summary"] as? String == "2 message types.")
        #expect(protobuf["types"] as? [String] == ["weather.v1.Forecast", "weather.v1.Other"])
        body = try result(await call(host, #"{"call":"presentBody","id":1,"part":"response"}"#))
        #expect(body["hasMessageTypes"] as? Bool == true && body["protobufType"] == nil)

        _ = try result(
            await call(host, ["call": "chooseMessageType", "id": 1, "part": "response", "type": "weather.v1.Forecast"]))
        body = try result(await call(host, #"{"call":"presentBody","id":1,"part":"response"}"#))
        #expect(
            body["protobufType"] as? String == "weather.v1.Forecast"
                && body["chosenType"] as? String == "weather.v1.Forecast")
        let labels =
            ((body["tree"] as? [String: Any])?["nodes"] as? [[String: Any]])?.compactMap { $0["label"] as? String }
            ?? []
        #expect(labels.contains("city") && labels.contains("days"))
        #expect(
            ProtobufFiles.load(from: list).chosenTypes == [
                "api.weatherly.dev/v1/forecast response": "weather.v1.Forecast"
            ])

        // Automatic again, and without the files, the fields show by number.
        _ = try result(await call(host, ["call": "chooseMessageType", "id": 1, "part": "response"]))
        // The list's own path for the folder, as the app sends it back.
        let listed = try #require(row["path"] as? String)
        protobuf = try result(await call(host, ["call": "removeProtobufSource", "path": listed]))
        #expect((protobuf["types"] as? [Any])?.isEmpty == true)
        body = try result(await call(host, #"{"call":"presentBody","id":1,"part":"response"}"#))
        #expect(body["protobufType"] == nil && body["chosenType"] == nil)
        await host.close()
    }
}

@Suite struct DevicesTests {
    /// Asks about a device as if it had connected, without anything listening on the network:
    /// the session doesn't capture.
    @Test func asksAboutADeviceAndKeepsTheOnesYouLetIn() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), send: log.record)
        let file = folder.appending(path: "Devices.json")
        var devices = try result(await call(host, ["call": "openDevices", "path": file.path(percentEncoded: false)]))
        #expect(devices["allowsNetworkDevices"] as? Bool == false && (devices["known"] as? [Any])?.isEmpty == true)
        let phone = ClientAddress(ip: "192.168.1.20", port: 50_000)
        #expect(await host.admit(phone) == false)

        devices = try result(await call(host, ["call": "setAllowsNetworkDevices", "isOn": true]))
        #expect(devices["allowsNetworkDevices"] as? Bool == true && devices["problem"] == nil)
        let asking = Task { await host.admit(phone) }
        let event = try #require(await log.wait { $0["event"] as? String == "deviceWaiting" })
        #expect(event["id"] as? String == "ip:192.168.1.20" && event["address"] as? String == "192.168.1.20")
        #expect(event["waiting"] as? Int == 1)
        devices = try result(await call(host, ["call": "devices"]))
        #expect((devices["waiting"] as? [[String: Any]])?.first?["id"] as? String == "ip:192.168.1.20")
        devices = try result(
            await call(host, ["call": "decideDevice", "device": "ip:192.168.1.20", "allow": true, "name": " Phone "]))
        #expect(await asking.value == true)
        let known = try #require((devices["known"] as? [[String: Any]])?.first)
        #expect(known["name"] as? String == "Phone" && known["address"] as? String == "192.168.1.20")
        #expect(DevicesFile.load(from: file).names == ["ip:192.168.1.20": "Phone"])
        // Let in once, it isn't asked about again.
        #expect(await host.admit(phone) == true)

        let tablet = ClientAddress(ip: "192.168.1.21", port: 50_001)
        let refused = Task { await host.admit(tablet) }
        _ = await log.wait { $0["event"] as? String == "deviceWaiting" && $0["id"] as? String == "ip:192.168.1.21" }
        // Turning devices off turns away the ones waiting.
        _ = try result(await call(host, ["call": "setAllowsNetworkDevices", "isOn": false]))
        #expect(await refused.value == false)

        devices = try result(await call(host, ["call": "forgetDevice", "device": "ip:192.168.1.20"]))
        #expect((devices["known"] as? [Any])?.isEmpty == true)
        #expect(
            try problem(await call(host, ["call": "renameDevice", "device": "ip:192.168.1.20", "name": " "]))
                == "badRequest")
        await host.close()
    }

    @Test func renamesADevicesTrafficInTheList() async throws {
        var fromPhone = Saved.exchange(1, target: "/v2/forecast", body: "{}")
        fromPhone.device = Device(id: "mac:aa:bb", kind: .network, name: "192.168.1.20", address: "192.168.1.20")
        let (folder, file) = try await Saved.file(with: [fromPhone])
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: log.record)
        _ = try result(
            await call(
                host,
                ["call": "openDevices", "path": folder.appending(path: "Devices.json").path(percentEncoded: false)]))
        _ = try result(await call(host, ["call": "renameDevice", "device": "mac:aa:bb", "name": "Parsa's phone"]))
        let rows = try result(await call(host, #"{"call":"rows","ids":[1]}"#))
        #expect((rows["rows"] as? [[String: Any]])?.first?["device"] as? String == "Parsa's phone")
        await host.close()
    }
}

@Suite struct SessionFileTests {
    @Test func savesASessionAndExportsHARThatBothOpenAgain() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sessions = folder.appending(path: "Sessions").path
        let host = try await SessionHost.open(OpenOptions(sessionsFolder: sessions, file: file.path), send: { _ in })
        let saved = folder.appending(path: "Saved Again.reqly")
        _ = try result(
            await call(host, #"{"call":"saveSession","path":\#(ListTests.json(saved.path)),"hidesSecrets":true}"#))
        let har = folder.appending(path: "Weather.har")
        let exported = try result(
            await call(host, #"{"call":"exportHAR","path":\#(ListTests.json(har.path)),"version":"0.1"}"#))
        #expect(exported["exported"] as? Int == 3)
        let one = try result(
            await call(host, #"{"call":"exportHAR","path":\#(ListTests.json(har.path + "2")),"ids":[2]}"#))
        #expect(one["exported"] as? Int == 1)
        await host.close()

        for opened in [saved, har] {
            let log = EventLog()
            let again = try await SessionHost.open(
                OpenOptions(sessionsFolder: sessions, file: opened.path), send: log.record)
            #expect(
                await log.wait { $0["event"] as? String == "rows" && $0["total"] as? Int == 3 } != nil,
                "\(opened.lastPathComponent)")
            await again.close()
        }
        let broken = folder.appending(path: "Broken.har")
        try Data("not json".utf8).write(to: broken)
        await #expect(throws: Problem.self) {
            _ = try await SessionHost.open(OpenOptions(sessionsFolder: sessions, file: broken.path), send: { _ in })
        }
    }
}

@Suite struct DetailsTests {
    @Test func marksSecretsAndReadsCookies() async throws {
        var exchange = Saved.exchange(1, target: "/v1/me?=&x=1", body: "{}")
        exchange.request.headers = ["Cookie": "session=abc; theme=dark", "Authorization": "Bearer xyz"]
        exchange.response?.headers = [
            "Set-Cookie": "session=new; Path=/; Secure; HttpOnly; Expires=Wed, 21 Oct 2026 07:28:00 GMT"
        ]
        let (folder, file) = try await Saved.file(with: [exchange])
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: { _ in })
        let details = try result(await call(host, #"{"call":"details","id":1}"#))
        let headers = try #require(details["requestHeaders"] as? [[String: Any]])
        #expect(headers.map { $0["isSecret"] as? Bool } == [true, true])
        let cookies = try #require(details["requestCookies"] as? [[String: Any]])
        #expect(cookies.map { $0["name"] as? String } == ["session", "theme"])
        let setCookie = try #require((details["responseCookies"] as? [[String: Any]])?.first)
        #expect(setCookie["attributes"] as? [String] == ["Path /", "Secure", "HttpOnly"])
        #expect(setCookie["expires"] as? Double == 1_792_567_680)
        // A lone "=" in the query has neither a name nor a value.
        let query = try #require(details["query"] as? [[String: Any]])
        #expect(query.map { "\($0["name"] ?? "")=\($0["value"] ?? "")" } == ["=", "x=1"])

        let hidden = try result(await call(host, #"{"call":"raw","id":1}"#))
        let request = try #require((hidden["request"] as? [String: Any])?["text"] as? String)
        #expect(request.contains("Authorization: ••••••••") && hidden["hasSecrets"] as? Bool == true)
        let shown = try result(await call(host, #"{"call":"raw","id":1,"showsSecrets":true}"#))
        #expect(((shown["request"] as? [String: Any])?["text"] as? String)?.contains("Bearer xyz") == true)
        await host.close()
    }
}

@Suite struct ListTests {
    /// The latest rows event's count of rows shown, once it's `shown`.
    func waitForShown(_ log: EventLog, _ shown: Int, total: Int? = nil) async -> Bool {
        await log.wait { event in
            event["event"] as? String == "rows" && event["shown"] as? Int == shown
                && (total.map { event["total"] as? Int == $0 } ?? true)
        } != nil
    }

    func row(_ host: SessionHost, _ id: Int) async throws -> [String: Any] {
        let rows = try #require(
            try result(await call(host, #"{"call":"rows","ids":[\#(id)]}"#))["rows"] as? [[String: Any]])
        return try #require(rows.first)
    }

    @Test func filtersByStatusContentHostAndMethod() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: log.record)
        #expect(await waitForShown(log, 3))

        _ = try result(await call(host, #"{"call":"setFilter","filter":{"statuses":["clientError","failed"]}}"#))
        #expect(await waitForShown(log, 0, total: 3))
        _ = try result(
            await call(host, #"{"call":"setFilter","filter":{"contents":["json"],"host":"api.weatherly.dev"}}"#))
        #expect(await waitForShown(log, 3))
        _ = try result(await call(host, #"{"call":"setFilter","filter":{"method":"POST"}}"#))
        #expect(await waitForShown(log, 0))
        _ = try result(await call(host, #"{"call":"setFilter","filter":{}}"#))
        #expect(await waitForShown(log, 3))
        #expect(
            try problem(await call(host, #"{"call":"setFilter","filter":{"statuses":["teapot"]}}"#)) == "badRequest")
        await host.close()
    }

    @Test func showsTheSidebarAndNarrowsTheListToARow() async throws {
        var exchanges = Saved.exchanges
        let weather = Source(name: "Weather", path: #"C:\Apps\Weather.exe"#)
        exchanges[0].source = weather
        exchanges[2].source = weather
        var other = Saved.exchange(4, target: "/v1/status", body: "{}")
        other.request.host = "status.weatherly.dev"
        exchanges.append(other)
        let (folder, file) = try await Saved.file(with: exchanges)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: log.record)
        #expect(await waitForShown(log, 4))

        let sidebar = try #require(await log.wait { $0["event"] as? String == "sidebar" && $0["total"] as? Int == 4 })
        let hosts = try #require(sidebar["hosts"] as? [[String: Any]])
        #expect(hosts.map { $0["name"] as? String } == ["api.weatherly.dev", "status.weatherly.dev"])
        #expect(hosts.map { $0["count"] as? Int } == [3, 1])
        let apps = try #require(sidebar["apps"] as? [[String: Any]])
        #expect(apps.map { $0["name"] as? String } == ["Weather"])
        #expect(apps.first?["count"] as? Int == 2)
        #expect(apps.first?["path"] as? String == #"C:\Apps\Weather.exe"#)
        #expect((sidebar["devices"] as? [Any])?.isEmpty == true)
        #expect(sidebar["methods"] as? [String] == ["GET"])

        let app = try #require(apps.first?["key"] as? String)
        _ = try result(await call(host, #"{"call":"setScope","key":\#(Self.json(app))}"#))
        #expect(await waitForShown(log, 2, total: 4))
        let status = try #require(hosts.last?["key"] as? String)
        _ = try result(await call(host, #"{"call":"setScope","key":\#(Self.json(status))}"#))
        #expect(await waitForShown(log, 1))
        _ = try result(await call(host, #"{"call":"setScope","key":"all"}"#))
        #expect(await waitForShown(log, 4))
        #expect(try problem(await call(host, #"{"call":"setScope","key":"host-nowhere"}"#)) == "notFound")

        // Pinning changes a count, which comes with the sidebar or on its own.
        _ = try result(await call(host, #"{"call":"annotate","id":1,"isPinned":true}"#))
        let counts = await log.wait {
            ["counts", "sidebar"].contains($0["event"] as? String) && $0["pinned"] as? Int == 1
        }
        #expect(counts != nil)
        _ = try result(await call(host, #"{"call":"setScope","key":"pinned"}"#))
        #expect(await waitForShown(log, 1))
        await host.close()
    }

    @Test func copiesARequestAsCurlAndItsResponseBody() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: { _ in })
        let command = try #require(try result(await call(host, #"{"call":"curl","id":1}"#))["command"] as? String)
        #expect(command.hasPrefix("curl 'https://api.weatherly.dev/v2/forecast?city=Tehran'"))
        #expect(command.contains("-H 'Accept: application/json'"))
        let body = try result(await call(host, #"{"call":"copyableBody","id":1}"#))
        #expect(body["text"] as? String == #"{"city":"Tehran","wind":"light"}"#)
        #expect(try problem(await call(host, #"{"call":"curl","id":9}"#)) == "notFound")
        await host.close()
    }

    @Test func copiesImagesAsImagesAndTheRestAsHex() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]) + Data(count: 20)
        let image = SessionHost.copyable(png, headers: ["Content-Type": "image/png"])
        #expect(image.image == png.base64EncodedString() && image.text == nil)
        let binary = SessionHost.copyable(
            Data([0x00, 0xFF, 0x10]), headers: ["Content-Type": "application/octet-stream"])
        #expect(binary.hex == "00 FF 10")
    }

    /// Text as a JSON string, quotes and escapes included.
    static func json(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    @Test func pinsMarksCommentsAndClears() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, file: file.path), send: log.record)
        #expect(await waitForShown(log, 3))

        let marked = #"{"call":"annotate","id":2,"isPinned":true,"color":"red","comment":"  Slow on 3G  "}"#
        _ = try result(await call(host, marked))
        var second = try await row(host, 2)
        #expect(second["isPinned"] as? Bool == true)
        #expect(second["color"] as? String == "red")
        #expect(second["comment"] as? String == "Slow on 3G")
        // Left out, the comment stays; null removes the color, and an empty comment removes it.
        _ = try result(await call(host, #"{"call":"annotate","id":2,"color":null}"#))
        second = try await row(host, 2)
        #expect(second["color"] == nil && second["comment"] as? String == "Slow on 3G")
        _ = try result(await call(host, #"{"call":"annotate","id":2,"comment":" "}"#))
        #expect(try await row(host, 2)["comment"] == nil)
        #expect(try problem(await call(host, #"{"call":"annotate","id":9,"isPinned":true}"#)) == "notFound")

        // Clearing keeps the pinned exchange.
        _ = try result(await call(host, #"{"call":"clear"}"#))
        #expect(await waitForShown(log, 1, total: 1))
        _ = try result(await call(host, #"{"call":"unpinAll"}"#))
        #expect(try await row(host, 2)["isPinned"] as? Bool == false)
        await host.close()
    }
}

@Suite struct ProxySwitchTests {
    /// The whole switch, from the session down, on a stand-in for Windows' proxy settings.
    @Test func switchesTheProxyEachTimeCapturingStarts() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let standIn = folder.appending(path: "Windows proxy settings.json")
        let restore = folder.appending(path: "ProxyRestore.json")
        let options = OpenOptions(
            sessionsFolder: folder.appending(path: "Sessions").path, setsSystemProxy: true,
            proxyRestoreFile: restore.path, proxySettingsStandIn: standIn.path, findsApps: false)
        let host = try await SessionHost.open(options, send: { _ in })
        let windows = FileProxySettings(file: standIn)
        for round in 0..<3 {
            let started = try result(await call(host, #"{"call":"startCapturing","port":0}"#))
            let port = try #require(started["port"] as? Int, "round \(round)")
            #expect(try windows.read().pointsAtReqly(port: port))
            #expect(FileManager.default.fileExists(atPath: restore.path))
            _ = try result(await call(host, #"{"call":"stopCapturing"}"#))
            #expect(try windows.read() == ProxySettings())
            #expect(!FileManager.default.fileExists(atPath: restore.path))
        }
        await host.close()
    }
}

@Suite struct HTTPSTests {
    @Test func setsUpRemovesAndDecryptsTheHostsOnTheList() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appending(path: "Root.plist")
        let options = OpenOptions(
            sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false, rootStandIn: root.path)
        let host = try await SessionHost.open(options, send: { _ in })
        #expect(try result(await call(host, #"{"call":"https"}"#))["status"] as? String == "notSetUp")

        let setUp = try result(await call(host, #"{"call":"setUpHTTPS"}"#))
        #expect(setUp["status"] as? String == "trusted")
        #expect((setUp["certificateName"] as? String)?.hasPrefix("Reqly CA") == true)
        // The certificate for devices to install, while it's trusted.
        let certificate = try #require(setUp["certificate"] as? String)
        #expect((Data(base64Encoded: certificate)?.count ?? 0) > 100)
        #expect(FileManager.default.fileExists(atPath: root.path))

        let hosts =
            #"{"call":"setDecryptedHosts","hosts":{"entries":[{"pattern":"*.weatherly.dev","isOn":true}],"includesEveryHost":false}}"#
        let decrypted = try result(await call(host, hosts))
        let entries = try #require((decrypted["hosts"] as? [String: Any])?["entries"] as? [[String: Any]])
        #expect(entries.first?["pattern"] as? String == "*.weatherly.dev")

        await host.close()

        // A new session finds the certificate made before.
        let again = try await SessionHost.open(options, send: { _ in })
        #expect(try result(await call(again, #"{"call":"https"}"#))["status"] as? String == "trusted")
        let removed = try result(await call(again, #"{"call":"removeHTTPS"}"#))
        #expect(removed["status"] as? String == "notSetUp")
        #expect(removed["certificate"] == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await again.close()
    }

    @Test func changesTheHostsToDecrypt() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let options = OpenOptions(
            sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false,
            rootStandIn: folder.appending(path: "Root.plist").path)
        let host = try await SessionHost.open(options, send: { _ in })
        func entries(_ json: String) async throws -> [String] {
            let hosts = try #require(try result(await call(host, json))["hosts"] as? [String: Any])
            let entries = try #require(hosts["entries"] as? [[String: Any]])
            return entries.map { "\($0["pattern"] ?? "?") \(($0["isOn"] as? Bool) == true ? "on" : "off")" }
        }
        func decrypts(_ name: String) async throws -> Bool? {
            try result(await call(host, #"{"call":"decryptsHost","host":"\#(name)"}"#))["decrypts"] as? Bool
        }

        #expect(try await entries(#"{"call":"addDecryptedHost","text":" *.Weatherly.dev "}"#) == ["*.weatherly.dev on"])
        let notAHost = await call(host, #"{"call":"addDecryptedHost","text":"not a host"}"#)
        #expect(try problem(notAHost) == "badRequest")
        #expect(String(decoding: notAHost, as: UTF8.self).contains("isn't a host"))
        #expect(try await decrypts("api.weatherly.dev") == true)
        #expect(try await decrypts("example.com") == false)

        let stopped = try await entries(#"{"call":"stopDecryptingHost","host":"api.weatherly.dev"}"#)
        #expect(stopped == ["*.weatherly.dev on", "api.weatherly.dev off"])
        #expect(try await decrypts("api.weatherly.dev") == false)
        #expect(try await decrypts("auth.weatherly.dev") == true)
        let decrypted = try await entries(#"{"call":"decryptHost","host":"example.com"}"#)
        #expect(decrypted == ["*.weatherly.dev on", "api.weatherly.dev off", "example.com on"])
        let switched = try await entries(#"{"call":"setHostDecrypted","pattern":"*.weatherly.dev","isOn":false}"#)
        #expect(switched.first == "*.weatherly.dev off")
        let removed = try await entries(
            #"{"call":"removeDecryptedHosts","patterns":["*.weatherly.dev","example.com"]}"#)
        #expect(removed == ["api.weatherly.dev off"])

        let everyHost = try result(await call(host, #"{"call":"setDecryptsEveryHost","isOn":true}"#))
        #expect((everyHost["hosts"] as? [String: Any])?["includesEveryHost"] as? Bool == true)
        #expect(try await decrypts("example.com") == true)
        #expect(try await decrypts("api.weatherly.dev") == false)
        await host.close()
    }

    @Test func savedSessionsDontDecrypt() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(
                sessionsFolder: folder.appending(path: "Sessions").path, file: file.path,
                rootStandIn: folder.appending(path: "Root.plist").path),
            send: { _ in })
        #expect(try problem(await call(host, #"{"call":"https"}"#)) == "notAvailable")
        await host.close()
    }
}

/// The C functions, called as the app calls them.
@Suite struct ExportTests {
    /// Where a C callback puts what it gets: the context pointer leads back here.
    final class Inbox: Sendable {
        let events = EventLog()
        let replies = EventLog()
    }

    static let onEvent: ReqlyCallback = { json, context in
        guard let json, let context else { return }
        Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue().events.record(Data(String(cString: json).utf8))
    }

    static let onReply: ReqlyCallback = { json, context in
        guard let json, let context else { return }
        Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue().replies.record(Data(String(cString: json).utf8))
    }

    @Test func worksThroughTheCFunctions() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = Inbox()
        let context = Unmanaged.passRetained(inbox)
        defer { context.release() }
        let options = #"{"sessionsFolder":"\#(folder.appending(path: "Sessions").path)","file":"\#(file.path)"}"#
        // reqly_open waits for the core, so it runs away from the test's own thread, as the app
        // runs it away from its UI thread. The handle crosses between tasks as its address.
        let address = await Task.detached { UInt(bitPattern: reqlyOpen(options, Self.onEvent, context.toOpaque())) }
            .value
        let handle = try #require(UnsafeMutableRawPointer(bitPattern: address))
        #expect(await inbox.events.wait { $0["event"] as? String == "rows" } != nil)

        reqlyCall(handle, #"{"call":"version"}"#, Self.onReply, context.toOpaque())
        let reply = try #require(await inbox.replies.wait { $0["result"] != nil })
        #expect((reply["result"] as? [String: Any])?["version"] as? Int == interfaceVersion)

        let body = await Task.detached { () -> Data? in
            var length: Int64 = 0
            let handle = UnsafeMutableRawPointer(bitPattern: address)
            guard let bytes = reqlyBody(handle, 2, 1, 0, 1000, &length) else { return nil }
            defer { reqlyFree(bytes) }
            return Data(bytes: bytes, count: Int(length))
        }.value
        #expect(body == Data(#"["Tehran","Lisbon"]"#.utf8))

        await Task.detached { reqlyClose(UnsafeMutableRawPointer(bitPattern: address)) }.value
    }

    @Test func saysWhyASessionDidntOpen() async {
        let inbox = Inbox()
        let context = Unmanaged.passRetained(inbox)
        defer { context.release() }
        let missing = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)/Gone.reqly").path
        let sessions = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-x").path
        let options = #"{"sessionsFolder":"\#(sessions)","file":"\#(missing)"}"#
        let address = await Task.detached { UInt(bitPattern: reqlyOpen(options, Self.onEvent, context.toOpaque())) }
            .value
        #expect(address == 0)
        let failed = inbox.events.all.first { $0["event"] as? String == "openFailed" }
        #expect((failed?["problem"] as? [String: Any])?["code"] as? String == "failed")
        #expect(reqlyOpen("not json", Self.onEvent, context.toOpaque()) == nil)
        try? FileManager.default.removeItem(at: URL.temporaryDirectory.appending(path: "ReqlyCoreTests-x"))
    }
}
