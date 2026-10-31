import CertificateAuthority
import CoreInterface
import Foundation
import Presentation
import ReqlyModel
import Synchronization
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The events a session handed over, as a Swift app gets them.
final class SessionEvents: Sendable {
    private let events = Mutex<[Event]>([])

    func record(_ event: Event) {
        events.withLock { $0.append(event) }
    }

    /// How many events came so far, to wait only for the ones after.
    var count: Int {
        events.withLock { $0.count }
    }

    /// Waits up to five seconds for an event, after the first `skipping`, that `matches` picks
    /// something from, and gives what it picked from the latest such event.
    func wait<Found>(skipping: Int = 0, for matches: (Event) -> Found?) async -> Found? {
        for _ in 0..<500 {
            if let found = events.withLock({ $0.dropFirst(skipping) }).reversed().lazy.compactMap(matches).first {
                return found
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// The rows as an app keeps them: every `rows` event's steps so far, applied in order to a
    /// list that starts empty, as the Windows app applies them. Nil when a version is skipped or
    /// a step names a place the list doesn't have.
    var mirroredRows: (version: Int, ids: [ExchangeID])? {
        events.withLock { events in
            var version = 0
            var ids: [ExchangeID] = []
            for case .rows(let next, _, _, let steps) in events {
                guard next == version + 1 else { return nil }
                version = next
                for step in steps {
                    switch step {
                    case .removed(let rows):
                        // From the last, so the places before it stay as they were.
                        for row in rows.reversed() {
                            guard ids.indices.contains(row) else { return nil }
                            ids.remove(at: row)
                        }
                    case .inserted(let rows):
                        for row in rows {
                            guard (0...ids.count).contains(row.row) else { return nil }
                            ids.insert(row.id, at: row.row)
                        }
                    case .changed:
                        break
                    case .reset(let all):
                        ids = all
                    }
                }
            }
            return (version, ids)
        }
    }

    /// Whether the rows kept from the events are the session's own, as of the same version.
    func mirror(_ host: SessionHost) async -> Bool {
        for _ in 0..<500 {
            let rows = await host.rowIDs()
            guard let mirrored = mirroredRows else { return false }
            if mirrored.version == rows.version { return mirrored.ids == rows.ids }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Waits for a `rows` event, after the first `skipping`, that shows `shown` rows.
    func waitForRows(skipping: Int = 0, shown: Int, total: Int? = nil) async -> Bool {
        await wait(skipping: skipping) { event in
            guard case .rows(_, let all, let count, _) = event, count == shown, total.map({ $0 == all }) ?? true
            else { return nil }
            return true
        } ?? false
    }
}

/// The Linux app's way in: SessionHost's Swift methods and its typed events, with no JSON
/// anywhere, on the same stand-ins as the other tests.
@Suite struct SessionAPITests {
    static func folder() -> URL {
        URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
    }

    @Test func capturesListsAndShowsThroughSwift() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = SessionEvents()
        let options = OpenOptions(
            sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false,
            rootStandIn: folder.appending(path: "Root").path)
        let host = try await SessionHost.open(options, system: .standIns, events: events.record)
        let opened = await events.wait { event -> Sidebar? in
            if case .sidebar(let sidebar) = event { sidebar } else { nil }
        }
        #expect(opened?.total == 0)

        // HTTPS, on a stand-in certificate store the session counts as trusted.
        #expect(try await host.https().status == .notSetUp)
        let https = try await host.setUpHTTPS()
        #expect(https.status == .trusted && https.certificate?.isEmpty == false && https.created != nil)
        let hosts = try await host.decryptHost("api.weatherly.dev")
        #expect(hosts.hosts.entries.map(\.pattern.rawValue) == ["api.weatherly.dev"])
        #expect(try await host.decryptsHost("api.weatherly.dev"))
        #expect(try await host.decryptsHost("cdn.weatherly.dev") == false)

        // Port 0 picks a free one. Only this computer can connect.
        let port = try await host.startCapturing(port: 0)
        #expect(port > 0)
        var total = 0
        #if !os(Windows)
            // As an app would, through the proxy. With no server there, Reqly answers itself, and
            // the exchange is recorded all the same.
            let answer = try await Self.get("http://127.0.0.1:9/", host: "127.0.0.1:9", throughProxyAt: port)
            #expect(answer.hasPrefix("HTTP/1.1 "))
            total += 1
            #expect(await events.waitForRows(shown: total))
            #expect(await events.mirror(host))
        #else
            // Self.get is written for POSIX sockets, so it isn't built on Windows. A row of another
            // host and method lets the search, the sidebar and the filter below narrow the list
            // there too.
            _ = try await host.send(RequestDraft(url: "forecast.invalid/today"))
            total += 1
            #expect(await events.waitForRows(shown: total))
            #expect(await events.mirror(host))
        #endif
        // .invalid never resolves, so nothing leaves the computer.
        let sent = try await host.send(
            RequestDraft(
                method: "POST", url: "weather.invalid/v2/report",
                headers: [.init(name: "X-Kept", value: "1"), .init(name: "X-Off", value: "2", isOn: false)],
                body: Data("sunny".utf8)))
        total += 1
        let inserted = await events.wait { event -> [RowStep.InsertedRow]? in
            guard case .rows(_, total, _, let steps) = event else { return nil }
            return steps.flatMap { step -> [RowStep.InsertedRow] in
                if case .inserted(let rows) = step { rows } else { [] }
            }
        }
        #expect(inserted?.contains { $0.id == sent } == true)
        #expect(await events.mirror(host))

        // The rows, by the exchanges' IDs, as the list shows them.
        let (version, ids) = await host.rowIDs()
        #expect(version > 0 && ids.count == total && ids.last == sent)
        let rows = await host.rows(ids + [ExchangeID(rawValue: 999)])
        #expect(rows.map(\.id) == ids)
        #expect(rows.last?.host == "weather.invalid" && rows.last?.method == "POST")
        #expect(await host.trafficSummary().total == total)

        // An exchange's details and its body.
        var exchange = try await host.exchange(sent)
        for _ in 0..<200 where !exchange.state.isFinished {
            try await Task.sleep(for: .milliseconds(25))
            exchange = try await host.exchange(sent)
        }
        #expect(exchange.sentByReqly)
        #expect(exchange.request.url?.absoluteString == "https://weather.invalid/v2/report")
        #expect(exchange.request.headers["X-Kept"] == "1" && exchange.request.headers["X-Off"] == nil)
        let presented = try await host.presentBody(sent, part: .request)
        #expect(presented.body.content == Data("sunny".utf8) && presented.hasMessageTypes == false)
        await #expect(throws: Problem(.notFound, "The session has no exchange 999.")) {
            try await host.exchange(ExchangeID(rawValue: 999))
        }

        // Search, a sidebar row and a filter narrow the list, and each says so with a `rows` event.
        var seen = events.count
        await host.setSearch("v2/report")
        #expect(await events.waitForRows(skipping: seen, shown: 1, total: total))
        #expect(await events.mirror(host))
        seen = events.count
        await host.setSearch("")
        #expect(await events.waitForRows(skipping: seen, shown: total))
        #expect(await events.mirror(host))
        let sidebar = try #require(
            await events.wait { event -> Sidebar? in
                guard case .sidebar(let sidebar) = event, sidebar.total == total else { return nil }
                return sidebar
            })
        let row = try #require(sidebar.hosts.first { $0.name == "weather.invalid" })
        #expect(row.count == 1)
        seen = events.count
        try await host.setScope(row.key)
        #expect(await events.waitForRows(skipping: seen, shown: 1))
        #expect(await events.mirror(host))
        seen = events.count
        try await host.setScope("all")
        #expect(await events.waitForRows(skipping: seen, shown: total))
        #expect(await events.mirror(host))
        await #expect(throws: Problem.self) { try await host.setScope("nowhere") }
        var posts = TrafficFilter()
        posts.method = "POST"
        seen = events.count
        await host.setFilter(posts)
        #expect(await events.waitForRows(skipping: seen, shown: 1))
        #expect(await events.mirror(host))
        seen = events.count
        await host.setFilter(TrafficFilter())
        #expect(await events.waitForRows(skipping: seen, shown: total))
        #expect(await events.mirror(host))

        // A rule made from the exchange, checked, then saved, which switches its kind on.
        let draft = try await host.newRuleDraft(kind: .block, from: sent)
        #expect(draft.host == "weather.invalid")
        let check = await host.checkRuleDraft(draft)
        #expect(check.problem == nil && check.matchCount == 1)
        let rules = try await host.saveRuleDraft(draft)
        #expect(rules.set.rules.map(\.kind) == [.block] && rules.set.kindsOn.contains(.block))
        #expect(await host.rules() == rules)

        // A pin shows in the row and in the sidebar's counts.
        seen = events.count
        try await host.annotate(sent, isPinned: true, comment: .set("  checked  "))
        let annotation = await host.rows([sent]).first?.annotation
        #expect(annotation?.isPinned == true && annotation?.comment == "checked")
        #expect(
            await events.wait(skipping: seen) { event -> Int? in
                switch event {
                case .counts(_, let pinned, _): pinned
                case .sidebar(let sidebar): sidebar.pinned
                default: nil
                }
            } == 1)

        try await host.stopCapturing()
        #expect(await host.capture.isCapturing == false)
        await host.close()
    }

    @Test func holdsARequestAndTakesTheEditBack() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = SessionEvents()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false),
            system: .standIns, events: events.record)
        await host.setRules(
            RuleSet(
                rules: [
                    Rule(
                        id: UUID(), name: "Hold the weather", isOn: true, match: RequestMatch(host: "weather.invalid"),
                        action: .breakpoint(.request))
                ], kindsOn: [.breakpoint]))

        // .invalid never resolves, so nothing leaves the computer.
        let id = try await host.send(RequestDraft(url: "https://weather.invalid/v2/forecast"))
        var edit = try #require(
            await events.wait { event -> PausedEdit? in
                guard case .paused(id, let edit) = event else { return nil }
                return edit
            })
        #expect(edit.breakpoint == "Hold the weather" && edit.url == "https://weather.invalid/v2/forecast")
        #expect(await host.pausedEdit(id)?.url == edit.url)

        // An edit that can't go on is kept, and the problem says what to fix.
        edit.url = "ftp://weather.invalid/"
        await #expect(throws: Problem(.badRequest, "Enter a URL that starts with http:// or https://.")) {
            try await host.resumePaused(id, as: edit)
        }
        #expect(await host.pausedEdit(id)?.url == "ftp://weather.invalid/")
        edit.url = "https://weather.invalid/v2/edited"
        var seen = events.count
        try await host.resumePaused(id, as: edit)
        let resumed = await events.wait(skipping: seen) { event -> Bool? in
            if case .resumed(id) = event { true } else { nil }
        }
        #expect(resumed == true)
        #expect(await host.pausedEdit(id) == nil)
        await #expect(throws: Problem(.notFound, "Nothing is waiting at a breakpoint for exchange \(id.rawValue).")) {
            try await host.resumePaused(id, as: edit)
        }

        // Stopping one sends it no further.
        let stopped = try await host.send(RequestDraft(url: "https://weather.invalid/v2/stopped"))
        #expect(
            await events.wait { event -> Bool? in
                if case .paused(stopped, _) = event { true } else { nil }
            } == true)
        seen = events.count
        try await host.stopPaused(stopped)
        #expect(
            await events.wait(skipping: seen) { event -> Bool? in
                if case .resumed(stopped) = event { true } else { nil }
            } == true)
        #expect(await host.pausedEdit(stopped) == nil)
        await #expect(throws: Problem.self) { try await host.stopPaused(stopped) }
        await host.close()
    }

    @Test func setsUpAndRemovesHTTPSThroughSwift() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await SessionHost.open(
            OpenOptions(
                sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false,
                rootStandIn: folder.appending(path: "Root").path),
            system: .standIns, events: { _ in })
        let set = try await host.setUpHTTPS()
        #expect(set.status == .trusted && set.certificateName != nil)

        // The list of hosts: one switched off stays on it, and every host can be decrypted at once.
        _ = try await host.decryptHost("api.weatherly.dev")
        var state = try await host.addDecryptedHost(" *.weatherly.dev ")
        #expect(state.hosts.entries.map(\.pattern.rawValue) == ["api.weatherly.dev", "*.weatherly.dev"])
        do {
            _ = try await host.addDecryptedHost("not a host")
            Issue.record("A host that isn't one was added.")
        } catch {
            #expect(error.code == .badRequest)
        }
        state = try await host.stopDecryptingHost("api.weatherly.dev")
        #expect(state.hosts.entries.first { $0.pattern.rawValue == "api.weatherly.dev" }?.isOn == false)
        #expect(try await host.decryptsHost("api.weatherly.dev") == false)
        #expect(try await host.decryptsHost("cdn.weatherly.dev"))
        state = try await host.setDecryptsEveryHost(true)
        #expect(state.hosts.includesEveryHost)
        #expect(try await host.decryptsHost("example.com"))

        // Removing the certificate takes it and its date away; the hosts stay.
        state = try await host.removeHTTPS()
        #expect(state.status == .notSetUp && state.certificate == nil && state.created == nil)
        #expect(state.certificateName == nil && state.hosts.includesEveryHost)
        await host.close()

        // A session with no certificate store doesn't decrypt.
        let plain = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false),
            system: .standIns, events: { _ in })
        do {
            _ = try await plain.https()
            Issue.record("A session with no certificate store has HTTPS.")
        } catch {
            #expect(error.code == .notAvailable)
        }
        await plain.close()
    }

    /// The Linux app makes the certificate and trusts it itself, place by place, then has the
    /// session read it again, so the session decrypts as soon as a place trusts it.
    @Test func readsTheCertificateAgainAfterTheAppChangesIt() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PlacesRootStore()
        let system = SystemParts(rootStore: { _ in store }, secrets: { file, _ in PlainSecrets(file: file) })
        let host = try await SessionHost.open(
            OpenOptions(
                sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false,
                rootFile: folder.appending(path: "Certificate.dat").path),
            system: system, events: { _ in })
        #expect(await host.reloadHTTPS().status == .notSetUp)
        _ = try await host.decryptHost("api.weatherly.dev")

        // Made and saved, but no place trusts it yet, so nothing is decrypted.
        let root = try RootIdentity.create()
        try store.save(root)
        var state = await host.reloadHTTPS()
        #expect(state.status == .notTrusted && state.certificateName == root.name && state.certificate == nil)

        // A place trusts it now.
        store.trustsIt()
        state = await host.reloadHTTPS()
        let der = Data(try root.certificateDER)
        #expect(state.status == .trusted && state.certificate == der)
        #expect(state.hosts.entries.map(\.pattern.rawValue) == ["api.weatherly.dev"])
        #expect(try await host.https() == state)
        await host.close()

        // A session with no certificate store has nothing to read.
        let plain = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false),
            system: .standIns, events: { _ in })
        #expect(await plain.reloadHTTPS() == HTTPSState(status: .notSetUp, hosts: DecryptedHosts()))
        await plain.close()
    }

    /// What an app's model would be, holding the session that hands it events.
    final class Model: Sendable {
        let events = SessionEvents()
    }

    @Test func closingLetsGoOfTheEvents() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var model: Model? = Model()
        weak let watched = model
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false),
            system: .standIns, events: { [model] in model?.events.record($0) })
        model = nil
        #expect(watched != nil)
        await host.close()
        #expect(watched == nil)
    }

    @Test func namesDevicesAndJoinsRules() {
        #expect(Device(id: "a", kind: .simulator, name: "iPhone 17 Pro").fullName == "iPhone 17 Pro · Simulator")
        #expect(Device(id: "b", kind: .emulator, name: "Pixel 10").fullName == "Pixel 10 · Android emulator")
        #expect(
            Device(id: "c", kind: .network, name: "Phone", address: "192.168.1.20").fullName
                == "Phone · 192.168.1.20")
        #expect(
            Device(id: "d", kind: .network, name: "192.168.1.21", address: "192.168.1.21").fullName == "192.168.1.21")
        let rules = [
            AppliedRule(name: "Hold", kind: .breakpoint, detail: "Held the request."),
            AppliedRule(name: "Hide", kind: .rewrite, detail: "Removed a header."),
            AppliedRule(name: "Hold", kind: .breakpoint, detail: "Held the response."),
        ]
        #expect(
            rules.joinedByRule == [
                AppliedRule(name: "Hold", kind: .breakpoint, detail: "Held the request. Held the response."),
                AppliedRule(name: "Hide", kind: .rewrite, detail: "Removed a header."),
            ])
    }

    #if !os(Windows)
        /// Sends a GET for `url` through the proxy on `port`, as an app would, and returns the
        /// answer, or what came of it in five seconds. It waits on a thread of its own.
        static func get(_ url: String, host: String, throughProxyAt port: Int) async throws -> String {
            try await onOwnThread { () throws -> String in
                #if canImport(Glibc)
                    let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                #else
                    let client = socket(AF_INET, SOCK_STREAM, 0)
                #endif
                try #require(client >= 0)
                defer { close(client) }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(port).bigEndian
                address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                try #require(connected == 0)
                let request = Array("GET \(url) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
                _ = request.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                var answer: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                    guard count > 0 else { break }
                    answer += buffer[..<count]
                }
                return String(decoding: answer, as: UTF8.self)
            }
        }
    #endif
}

/// A certificate store that the app changes behind the session's back, as Linux's is: the app
/// saves the root, then a place trusts it.
private final class PlacesRootStore: RootStore {
    private let kept = Mutex<(root: RootIdentity?, isTrusted: Bool)>((nil, false))

    func trustsIt() {
        kept.withLock { $0.isTrusted = true }
    }

    func load() throws -> RootIdentity? { kept.withLock { $0.root } }
    func save(_ root: RootIdentity) throws { kept.withLock { $0.root = root } }
    func isTrusted(_ root: RootIdentity) -> Bool { kept.withLock { $0.isTrusted } }
    func trust(_ root: RootIdentity) throws { trustsIt() }
    func remove(_ root: RootIdentity) throws { kept.withLock { $0 = (nil, false) } }
}
