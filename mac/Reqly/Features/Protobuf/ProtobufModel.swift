import BodyKit
import Foundation
import Observation
import Presentation

/// The `.proto` files Reqly reads protobuf and gRPC bodies with, and the message types chosen
/// for bodies that don't say theirs. The list is saved, and the files are read again each time
/// Reqly opens, so changes to them show up.
@Observable
final class ProtobufModel {
    /// A `.proto` file, or a folder of them, that was added.
    typealias Source = ProtobufFiles.Source

    private(set) var sources: [Source] = []
    private(set) var schema = ProtobufSchema()
    private(set) var problems: [ProtoFileProblem] = []
    /// How many `.proto` files each source held when it was last read. A missing one has none.
    private(set) var fileCounts: [String: Int] = [:]
    /// Goes up each time the schema changes, so bodies are read again with it.
    private(set) var version = 0
    private(set) var isLoading = false
    /// Why the list couldn't be saved, if it couldn't.
    private(set) var saveProblem: String?
    private var chosenTypes: [String: String] = [:]

    private let url: URL
    private var loading: Task<Void, Never>?

    init() {
        url = Self.fileURL
        let saved = ProtobufFiles.load(from: url)
        sources = saved.sources
        chosenTypes = saved.chosenTypes
        reload()
    }

    /// Where the list is saved. A debug build takes another file from `-protobufFile path`.
    private static var fileURL: URL {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: DefaultsKey.protobufFile) {
                return URL(filePath: path)
            }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Reqly/Protobuf.json")
    }

    var hasMessageTypes: Bool { !schema.messageNames.isEmpty }

    func add(_ urls: [URL]) {
        let added = urls.map(Source.init).filter { source in !sources.contains { $0.id == source.id } }
        guard !added.isEmpty else { return }
        sources += added
        save()
        reload()
    }

    func remove(_ ids: Set<Source.ID>) {
        sources.removeAll { ids.contains($0.id) }
        save()
        reload()
    }

    /// The message type chosen for bodies like this one, if one was.
    func chosenType(for key: String) -> String? {
        chosenTypes[key]
    }

    /// Reads bodies like this one as `type` from now on, or as Reqly works out when it's `nil`.
    func choose(_ type: String?, for key: String) {
        chosenTypes[key] = type
        save()
    }

    /// Reads the files again, as after they changed.
    func reload() {
        loading?.cancel()
        isLoading = true
        let sources = sources
        loading = Task {
            let result = await Task.detached(priority: .userInitiated) { ProtobufFiles.read(sources) }.value
            guard !Task.isCancelled else { return }
            schema = result.schema
            problems = result.problems
            fileCounts = result.counts
            version += 1
            isLoading = false
        }
    }

    private func save() {
        do {
            try ProtobufFiles.save(ProtobufFiles.Contents(sources: sources, chosenTypes: chosenTypes), to: url)
            saveProblem = nil
        } catch {
            saveProblem = ProtobufFiles.saveProblem(error)
        }
    }
}
