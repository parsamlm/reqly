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

    /// Opens the list of `.proto` files and reads them, so protobuf bodies show their fields' names.
    public func open(_ url: URL) async -> ProtobufState {
        book.open(url)
        await read()
        return book.state
    }

    /// The `.proto` files and what they hold.
    public var state: ProtobufState { book.state }

    /// Adds files and folders that aren't on the list yet, and reads them.
    public func add(_ urls: [URL]) async -> ProtobufState {
        if book.add(urls) {
            await read()
        }
        return book.state
    }

    public func remove(_ path: String) async -> ProtobufState {
        book.remove(path)
        await read()
        return book.state
    }

    /// Reads the files again, as after they changed.
    public func reload() async -> ProtobufState {
        await read()
        return book.state
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

    var state: ProtobufState {
        ProtobufState(
            sources: contents.sources.map {
                ProtobufState.Source(
                    path: $0.path, isFolder: $0.isFolder, name: $0.url.lastPathComponent,
                    count: counts[$0.id].flatMap { $0 > 0 ? $0 : nil })
            },
            summary: ProtobufFiles.summary(schema, hasSources: !contents.sources.isEmpty), problems: problems,
            saveProblem: saveProblem, types: schema.messageNames, version: version)
    }
}

/// The `.proto` files, as Settings list them, and the message types they hold.
public struct ProtobufState: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        public var path: String
        public var isFolder: Bool
        /// The file's or the folder's name.
        public var name: String
        /// How many `.proto` files it holds, or none when it's missing or has none.
        public var count: Int?

        public init(path: String, isFolder: Bool, name: String, count: Int? = nil) {
            self.path = path
            self.isFolder = isFolder
            self.name = name
            self.count = count
        }
    }

    public var sources: [Source]
    /// Such as "14 message types and 2 services."
    public var summary: String
    /// In the order of the sources.
    public var problems: [ProtoFileProblem]
    public var saveProblem: String?
    /// Every message type, by its full name, for a body's message type menu.
    public var types: [String]
    /// Goes up each time the files are read.
    public var version: Int

    public init(
        sources: [Source], summary: String, problems: [ProtoFileProblem], saveProblem: String? = nil, types: [String],
        version: Int
    ) {
        self.sources = sources
        self.summary = summary
        self.problems = problems
        self.saveProblem = saveProblem
        self.types = types
        self.version = version
    }
}
