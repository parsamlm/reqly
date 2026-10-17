import Foundation
import ReqlyModel
import Testing
import TrafficStore

/// A session saved by Reqly for Mac 1.0, or by Reqly for Windows, opens on every system, and reads
/// as the session that was saved: `SessionSample`.
@Suite(.timeLimit(.minutes(1))) struct SessionCompatibilityTests {
    /// The saved sessions, next to this file.
    static let sessions = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Sessions")

    static func temporaryFolder() -> URL {
        URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test(arguments: ["Mac 1.0.reqly", "Windows.reqly"])
    func opensASessionSavedElsewhere(_ name: String) async throws {
        let root = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await SessionSample.store(in: root)
        defer { saved.discard() }
        let opened = try await TrafficStore.openSession(Self.sessions.appending(path: name), in: root)
        defer { opened.discard() }
        #expect(try await opened.summaries() == saved.summaries())
        for exchange in SessionSample.exchanges() {
            let read = try await opened.exchange(exchange.id)
            #expect(read == (try await saved.exchange(exchange.id)), "exchange \(exchange.id.rawValue)")
        }
        let socket = SessionSample.id(11)
        #expect(try await opened.messages(of: socket) == saved.messages(of: socket))
        // Opening builds the search index again, which a saved session leaves out.
        #expect(try await opened.search("Lisbon").contains(SessionSample.id(1)))
        #expect(try await opened.search("تهران").contains(SessionSample.id(2)))
    }

    /// Saves this system's copy of the sample to the file `REQLY_SAVE_SESSION_SAMPLE` names, as
    /// `Sessions/Windows.reqly` was saved on Windows.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REQLY_SAVE_SESSION_SAMPLE"] != nil))
    func savesTheSample() async throws {
        let file = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["REQLY_SAVE_SESSION_SAMPLE"]))
        let root = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = try await SessionSample.store(in: root)
        defer { sample.discard() }
        try await sample.saveSession(to: file, hidingSecrets: false)
    }
}
