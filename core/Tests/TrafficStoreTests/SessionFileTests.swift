import Foundation
import GRDB
import ReqlyModel
import Testing

@testable import TrafficStore

#if canImport(Glibc)
    import Glibc
#endif

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

    #if !os(Windows)
        /// A name near the 255 bytes most file systems take saves as a short one does, as a new
        /// file and over itself, and leaves nothing beside it.
        @Test func savesUnderAVeryLongName() async throws {
            let store = try await sampleStore()
            defer { store.discard() }
            // 240 bytes: 117 Persian letters of 2 bytes each, and ".reqly".
            let name = String(repeating: "هوا", count: 39) + ".reqly"
            #expect(name.utf8.count == 240)
            let url = file(name)
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try await store.saveSession(to: url, hidingSecrets: false)
            try await store.saveSession(to: url, hidingSecrets: false)

            let root = F.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let opened = try await TrafficStore.openSession(url, in: root)
            defer { opened.discard() }
            #expect(try await opened.summaries() == store.summaries())
            let left = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            #expect(left == [name])
        }
    #endif

    #if os(Linux)
        /// Whether /dev/shm and the folder Foundation makes its temporary copies in, which follows
        /// TMPDIR, are on two file systems, as `/tmp` in a tmpfs and your home are on Debian 13 and
        /// Ubuntu 26.04. Docker gives every container a /dev/shm of its own.
        static let shmIsAnotherFileSystem: Bool = {
            let shm = URL(filePath: "/dev/shm/ReqlyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            guard (try? FileManager.default.createDirectory(at: shm, withIntermediateDirectories: false)) != nil
            else { return false }
            defer { try? FileManager.default.removeItem(at: shm) }
            guard
                let scratch = try? FileManager.default.url(
                    for: .itemReplacementDirectory, in: .userDomainMask,
                    appropriateFor: shm.appending(path: "Weatherly.reqly"), create: true)
            else { return false }
            defer { try? FileManager.default.removeItem(at: scratch) }
            var shmStatus = stat()
            var scratchStatus = stat()
            guard stat(shm.path(percentEncoded: false), &shmStatus) == 0,
                stat(scratch.path(percentEncoded: false), &scratchStatus) == 0
            else { return false }
            return shmStatus.st_dev != scratchStatus.st_dev
        }()

        /// Saving over a file takes its place in one step, even where Foundation's temporary
        /// folder is on another file system, as it is wherever `/tmp` is a tmpfs.
        @Test(
            .enabled(
                if: shmIsAnotherFileSystem,
                "/dev/shm and Foundation's temporary folder are on one file system here, so this can't be tested"))
        func savesOverAFileOnAnotherFileSystem() async throws {
            let store = try await sampleStore()
            defer { store.discard() }
            let folder = URL(filePath: "/dev/shm/ReqlyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            // A file only you can read, saved before.
            let url = folder.appending(path: "Weatherly.reqly")
            let path = url.path(percentEncoded: false)
            #expect(
                FileManager.default.createFile(
                    atPath: path, contents: Data("An older session".utf8), attributes: [.posixPermissions: 0o600]))
            try await store.saveSession(to: url, hidingSecrets: false)

            // The new session took its place whole, kept its mode, and left nothing beside it.
            let root = F.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let opened = try await TrafficStore.openSession(url, in: root)
            defer { opened.discard() }
            #expect(try await opened.summaries() == store.summaries())
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
            let left = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            #expect(left == ["Weatherly.reqly"])
        }
    #endif

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

    /// Every session merges its search index as `searchDeleteMerge` says: a new one, and one
    /// opened from a file saved before Reqly set it. A saved file keeps the setting.
    @Test func setsWhenTheSearchIndexMerges() async throws {
        let setting = "SELECT v FROM search_config WHERE k = 'deletemerge'"
        let store = try await sampleStore()
        defer { store.discard() }
        #expect(try await store.database.read { try Int.fetchOne($0, sql: setting) } == TrafficStore.searchDeleteMerge)

        let mac = SessionCompatibilityTests.sessions.appending(path: "Mac 1.0.reqly")
        var readOnly = Configuration()
        readOnly.readonly = true
        let file = try DatabaseQueue(path: mac.path(percentEncoded: false), configuration: readOnly)
        #expect(try await file.read { try Int.fetchOne($0, sql: setting) } == nil)
        try file.close()
        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = try await TrafficStore.openSession(mac, in: root)
        defer { opened.discard() }
        #expect(try await opened.database.read { try Int.fetchOne($0, sql: setting) } == TrafficStore.searchDeleteMerge)

        let url = self.file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await opened.saveSession(to: url, hidingSecrets: false)
        let saved = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: readOnly)
        defer { try? saved.close() }
        #expect(try await saved.read { try Int.fetchOne($0, sql: setting) } == TrafficStore.searchDeleteMerge)
    }

    /// A saved file's search index is there to be thrown away, so a file whose index is damaged
    /// opens all the same, with a new one, wherever SQLite can build a new one.
    @Test func opensAFileWhoseSearchIndexIsDamaged() async throws {
        let root = F.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var data = try Data(contentsOf: SessionCompatibilityTests.sessions.appending(path: "Mac 1.0.reqly"))
        // The empty index's structure record, which SQLite calls corrupt as it reads it with
        // another byte in its marker.
        let structure = Data([0, 0, 0, 0, 0xFF, 0, 0, 1, 0, 0, 0])
        let record = try #require(data.range(of: structure))
        #expect(data.range(of: structure, in: record.upperBound..<data.endIndex) == nil)
        data[record.lowerBound + 4] = 0xFE
        let damaged = root.appending(path: "Damaged.reqly")
        try data.write(to: damaged)

        // Older SQLite, such as Ubuntu 24.04's 3.45, reads the structure as soon as it uses the
        // index at all, so it can't build a new one in such a file, which never opened there.
        // Newer ones read it only to change a setting.
        let copy = root.appending(path: "Copy.reqly")
        try data.write(to: copy)
        let queue = try DatabaseQueue(path: copy.path(percentEncoded: false))
        let rebuilds =
            (try? await queue.write { try $0.execute(sql: "INSERT INTO search(search) VALUES('delete-all')") }) != nil
        try queue.close()
        guard rebuilds else {
            await #expect(throws: (any Error).self) { try await TrafficStore.openSession(damaged, in: root) }
            return
        }

        let opened = try await TrafficStore.openSession(damaged, in: root)
        defer { opened.discard() }
        let saved = try await SessionSample.store(in: root)
        defer { saved.discard() }
        #expect(try await opened.summaries() == saved.summaries())
        #expect(try await opened.search("Lisbon").contains(SessionSample.id(1)))
        let setting = "SELECT v FROM search_config WHERE k = 'deletemerge'"
        #expect(try await opened.database.read { try Int.fetchOne($0, sql: setting) } == TrafficStore.searchDeleteMerge)
    }
}
