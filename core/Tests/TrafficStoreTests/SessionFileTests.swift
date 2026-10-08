import Foundation
import GRDB
import ReqlyModel
import Testing

@testable import TrafficStore

@Suite(.timeLimit(.minutes(1))) struct SessionFileTests {
    typealias F = Fixtures

    func file(_ name: String = "Weatherly.reqly") -> URL {
        F.temporaryFolder().appending(path: name)
    }

    /// A session with a body in a file, an annotation, an app, and secrets in its headers.
    func sampleStore() async throws -> TrafficStore {
        let store = try F.store(TrafficStore.Limits(inlineBodySize: 8))
        var first = F.exchange(
            1, requestHeaders: ["Authorization": "Bearer secret-token"],
            responseHeaders: ["Content-Type": "application/json", "Set-Cookie": "session=secret-cookie"])
        first.source = Source(name: "Weatherly", bundleID: "dev.weatherly.app", path: "/Applications/Weatherly.app")
        let second = F.exchange(2, target: "/v2/alerts")
        try await store.write(
            [first, second],
            chunks: [F.chunk(1, .response, "{\"forecast\":\"sunny all week\"}"), F.chunk(2, .response, "[]")])
        try await store.annotate(F.id(1), with: Annotation(isPinned: true, color: .green, comment: "Looks right"))
        return store
    }

    @Test func savesASessionToOneFileAndOpensItAgain() async throws {
        let store = try await sampleStore()
        defer { store.discard() }
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await store.saveSession(to: url, hidingSecrets: false)
        let saved = try Data(contentsOf: url)

        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = try await TrafficStore.openSession(url, in: root)
        #expect(try await opened.summaries() == store.summaries())
        #expect(try await opened.exchange(F.id(1)) == store.exchange(F.id(1)))
        // The body that had a file of its own is inside the saved file now.
        #expect(try F.bodyFiles(of: opened).isEmpty)
        #expect(try await opened.search("sunny all") == [F.id(1)])
        #expect(try await opened.search("alerts") == [F.id(2)])
        // Opening the file left it as it was.
        #expect(try Data(contentsOf: url) == saved)
        opened.discard()
    }

    @Test func hidesSecretsWhenAsked() async throws {
        let store = try await sampleStore()
        defer { store.discard() }
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await store.saveSession(to: url, hidingSecrets: true)

        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("secret-token".utf8)) == nil)
        #expect(bytes.range(of: Data("secret-cookie".utf8)) == nil)
        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = try await TrafficStore.openSession(url, in: root)
        let exchange = try #require(try await opened.exchange(F.id(1)))
        #expect(exchange.request.headers["Authorization"] == Headers.hiddenValue)
        #expect(exchange.response?.headers["Set-Cookie"] == Headers.hiddenValue)
        #expect(exchange.response?.headers["Content-Type"] == "application/json")
        opened.discard()
    }

    @Test func refusesFilesThatAreNotSessions() async throws {
        let folder = F.temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appending(path: "notes.reqly")
        try Data("not a database".utf8).write(to: text)
        let other = folder.appending(path: "other.sqlite")
        try await DatabaseQueue(path: other.path(percentEncoded: false)).write { db in
            try db.execute(sql: "CREATE TABLE notes (text TEXT)")
        }

        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for url in [text, other] {
            await #expect(throws: SessionFileError.notASession) {
                _ = try await TrafficStore.openSession(url, in: root)
            }
        }
        // Nothing is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).isEmpty)
    }

    @Test func refusesSessionsFromANewerReqly() async throws {
        let store = try await sampleStore()
        defer { store.discard() }
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await store.saveSession(to: url, hidingSecrets: false)
        try await DatabaseQueue(path: url.path(percentEncoded: false)).write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99: from the future')")
        }

        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: SessionFileError.savedByNewerReqly) {
            _ = try await TrafficStore.openSession(url, in: root)
        }
    }

    @Test func opensSessionsSavedBeforeReqlyMarkedTheRequestsItSent() async throws {
        let store = try F.store()
        defer { store.discard() }
        var composed = F.exchange(1)
        composed.sentByReqly = true
        try await store.write([composed, F.exchange(2)], chunks: [])
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await store.saveSession(to: url, hidingSecrets: false)

        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = try await TrafficStore.openSession(url, in: root)
        #expect(try await opened.exchange(F.id(1))?.sentByReqly == true)
        #expect(try await opened.exchange(F.id(2))?.sentByReqly == false)
        opened.discard()

        // The file as a Reqly from before "v12: sent by Reqly" saved it.
        try await DatabaseQueue(path: url.path(percentEncoded: false)).write { db in
            try db.execute(sql: "ALTER TABLE exchange DROP COLUMN sentByReqly")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v12: sent by Reqly'")
        }
        let older = try await TrafficStore.openSession(url, in: root)
        #expect(try await older.exchange(F.id(1))?.sentByReqly == false)
        #expect(try await older.summaries().count == 2)
        older.discard()
    }

    @Test func startsASessionWithExchangesFromElsewhere() async throws {
        var imported = F.exchange(1)
        imported.requestBody = Data("{}".utf8)
        imported.responseBody = Data("{\"t\":14}".utf8)
        imported.annotation.comment = "From the HAR file"
        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await TrafficStore.newSession(in: root, with: [imported])
        defer { store.discard() }
        #expect(try await store.exchange(F.id(1)) == imported)
        #expect(try await store.search("\"t\":14") == [F.id(1)])
    }
}
