import CoreInterface
import Foundation
import ReqlyCore
import ReqlyModel
import Synchronization
import Testing
import TrafficStore

// The helpers the core interface's own tests have, for the tests of the C functions and of
// sessions with Windows' parts.

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

/// Runs `work`, which blocks while it waits, on a thread of its own, as the app calls the core from
/// threads of its own. Swift's tasks share as many threads as the computer has cores, four on
/// GitHub's, and work that blocks one holds up every test's tasks, and the core's.
func onOwnThread<T: Sendable, E: Error>(_ work: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
    let result = await withCheckedContinuation { (done: CheckedContinuation<Result<T, E>, Never>) in
        Thread.detachNewThread { done.resume(returning: Result(catching: work)) }
    }
    return try result.get()
}

extension SessionHost {
    /// Opens a session with Windows' own parts, as the app does.
    static func open(
        _ options: OpenOptions, send: @escaping @Sendable (Data) -> Void
    ) async throws(Problem) -> SessionHost {
        try await open(options, system: .windows, send: send)
    }
}
