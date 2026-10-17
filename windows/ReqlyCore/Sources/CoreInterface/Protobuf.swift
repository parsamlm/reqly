import BodyKit
import Foundation
import Presentation

/// The `.proto` files bodies are read with, and the message types chosen for bodies that don't say
/// theirs, shared by every session open, as the Mac's windows share them. They're kept in the same
/// file the Mac keeps them in.
public actor ProtobufLibrary {
    /// The library of this run of Reqly.
    public static let shared = ProtobufLibrary()

    private var book = ProtobufBook()
    /// Counts the times the files are read, so only the latest reading is kept.
    private var readings = 0

    public init() {}

    func open(_ url: URL) async -> WireProtobuf {
        book.open(url)
        await read()
        return book.wire
    }

    var wire: WireProtobuf { book.wire }

    func add(_ urls: [URL]) async -> WireProtobuf {
        if book.add(urls) {
            await read()
        }
        return book.wire
    }

    func remove(_ path: String) async -> WireProtobuf {
        book.remove(path)
        await read()
        return book.wire
    }

    /// Reads the files again, as after they changed.
    func reload() async -> WireProtobuf {
        await read()
        return book.wire
    }

    func choose(_ type: String?, for key: String) {
        book.choose(type, for: key)
    }

    /// What a body is read with: the message types, their reading, and the type chosen for bodies like it.
    func reading(for key: String) -> (schema: ProtobufSchema, version: Int, chosenType: String?) {
        (book.schema, book.version, book.chosenType(for: key))
    }

    /// Reads the files away from the calls that come meanwhile. Only the latest reading is kept.
    private func read() async {
        readings += 1
        let reading = readings
        let sources = book.contents.sources
        let read = await Task.detached(priority: .userInitiated) { ProtobufFiles.read(sources) }.value
        if reading == readings {
            book.use(read)
        }
    }
}

/// The list of `.proto` files, what they hold, and the types chosen.
struct ProtobufBook {
    private(set) var contents = ProtobufFiles.Contents()
    private(set) var schema = ProtobufSchema()
    private(set) var problems: [ProtoFileProblem] = []
    private(set) var counts: [String: Int] = [:]
    /// Goes up each time the files are read, so bodies are made ready again with them.
    private(set) var version = 0
    private(set) var saveProblem: String?
    private var file: URL?

    mutating func open(_ url: URL) {
        file = url
        contents = ProtobufFiles.load(from: url)
    }

    mutating func use(_ reading: ProtobufFiles.Reading) {
        schema = reading.schema
        problems = reading.problems
        counts = reading.counts
        version += 1
    }

    /// Adds files and folders that aren't on the list yet. Says whether any were.
    mutating func add(_ urls: [URL]) -> Bool {
        let added = urls.map(ProtobufFiles.Source.init).filter { source in
            !contents.sources.contains { $0.id == source.id }
        }
        guard !added.isEmpty else { return false }
        contents.sources += added
        save()
        return true
    }

    mutating func remove(_ path: String) {
        contents.sources.removeAll { $0.path == path }
        save()
    }

    func chosenType(for key: String) -> String? {
        contents.chosenTypes[key]
    }

    /// Reads bodies like this one as `type` from now on, or as Reqly works out when it's `nil`.
    mutating func choose(_ type: String?, for key: String) {
        contents.chosenTypes[key] = type
        save()
    }

    private mutating func save() {
        guard let file else { return }
        do {
            try ProtobufFiles.save(contents, to: file)
            saveProblem = nil
        } catch {
            saveProblem = ProtobufFiles.saveProblem(error)
        }
    }

    var wire: WireProtobuf {
        WireProtobuf(
            sources: contents.sources.map {
                WireProtobuf.Source(
                    path: $0.path, isFolder: $0.isFolder, name: $0.url.lastPathComponent,
                    count: counts[$0.id].flatMap { $0 > 0 ? $0 : nil })
            },
            summary: ProtobufFiles.summary(schema, hasSources: !contents.sources.isEmpty),
            problems: problems.prefix(200).map {
                WireProtobuf.Problem(file: $0.file, line: $0.line, message: $0.message)
            },
            saveProblem: saveProblem, types: schema.messageNames, version: version)
    }
}

/// The `.proto` files, as Settings list them, and the message types they hold.
struct WireProtobuf: Encodable, Sendable {
    struct Source: Encodable, Sendable {
        var path: String
        var isFolder: Bool
        /// The file's or the folder's name.
        var name: String
        /// How many `.proto` files it holds, or none when it's missing or has none.
        var count: Int?
    }

    struct Problem: Encodable, Sendable {
        var file: String
        /// 0 when the problem is with the whole file.
        var line: Int
        var message: String
    }

    var sources: [Source]
    /// Such as "14 message types and 2 services."
    var summary: String
    /// At most 200, in the order of the sources.
    var problems: [Problem]
    var saveProblem: String?
    /// Every message type, by its full name, for a body's message type menu.
    var types: [String]
    var version: Int
}
