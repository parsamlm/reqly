import BodyKit
import Foundation
import Observation

/// The `.proto` files Reqly reads protobuf and gRPC bodies with, and the message types chosen
/// for bodies that don't say theirs. The list is saved, and the files are read again each time
/// Reqly opens, so changes to them show up.
@Observable
final class ProtobufModel {
    /// A `.proto` file, or a folder of them, that was added.
    nonisolated struct Source: Codable, Hashable, Identifiable, Sendable {
        var path: String
        var isFolder: Bool

        var id: String { path }
        var url: URL { URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory) }
    }

    private struct Saved: Codable {
        var version = 1
        var sources: [Source] = []
        /// Message types chosen for bodies, by ``ProtobufModel/key(for:isRequest:)``.
        var chosenTypes: [String: String] = [:]
    }

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

    /// Files bigger than this aren't `.proto` files anyone wrote by hand.
    nonisolated private static let fileSizeLimit = 8 << 20
    /// A folder with more files than this is probably not the one meant.
    nonisolated private static let fileCountLimit = 5000

    init() {
        url = Self.fileURL
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            sources = saved.sources
            chosenTypes = saved.chosenTypes
        }
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
        let added = urls.map { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return Source(path: url.standardizedFileURL.path(percentEncoded: false), isFolder: isFolder)
        }
        .filter { source in !sources.contains { $0.id == source.id } }
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

    /// Bodies are like one another when they're the same part of requests to the same host
    /// and path, such as responses from `api.weatherly.dev/v1/forecast`.
    nonisolated static func key(for url: URL?, isRequest: Bool) -> String {
        "\(url?.host() ?? "")\(url?.path(percentEncoded: false) ?? "") \(isRequest ? "request" : "response")"
    }

    /// Reads the files again, as after they changed.
    func reload() {
        loading?.cancel()
        isLoading = true
        let sources = sources
        loading = Task {
            let result = await Task.detached(priority: .userInitiated) { Self.read(sources) }.value
            guard !Task.isCancelled else { return }
            schema = result.schema
            problems = result.problems
            fileCounts = result.counts
            version += 1
            isLoading = false
        }
    }

    private func save() {
        let saved = Saved(sources: sources, chosenTypes: chosenTypes)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(saved).write(to: url, options: .atomic)
            saveProblem = nil
        } catch {
            saveProblem = "Reqly couldn't save the list of .proto files: \(error.localizedDescription)"
        }
    }

    /// Every `.proto` file the sources hold, then their types. A folder's files are named by
    /// their paths in it, the way imports name them.
    nonisolated private static func read(_ sources: [Source]) -> (
        schema: ProtobufSchema, problems: [ProtoFileProblem], counts: [String: Int]
    ) {
        var files: [(name: String, text: String)] = []
        var problems: [ProtoFileProblem] = []
        var counts: [String: Int] = [:]
        var seen: Set<String> = []
        let manager = FileManager.default
        for source in sources {
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &isFolder) else {
                problems.append(
                    ProtoFileProblem(
                        file: source.url.lastPathComponent, line: 0,
                        message: "Reqly can't find this anymore. It may have been moved or deleted."))
                continue
            }
            var found: [(url: URL, name: String)] = []
            if isFolder.boolValue {
                let enumerator = manager.enumerator(
                    at: source.url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                let prefix = source.url.standardizedFileURL.path(percentEncoded: false)
                while let file = enumerator?.nextObject() as? URL {
                    guard file.pathExtension == "proto" else { continue }
                    guard found.count < fileCountLimit else {
                        problems.append(
                            ProtoFileProblem(
                                file: source.url.lastPathComponent, line: 0,
                                message:
                                    "This folder has more than \(fileCountLimit.formatted()) .proto files, so Reqly read only that many."
                            ))
                        break
                    }
                    let path = file.standardizedFileURL.path(percentEncoded: false)
                    let name = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file.lastPathComponent
                    found.append((file, name.hasPrefix("/") ? String(name.dropFirst()) : name))
                }
            } else {
                found.append((source.url, source.url.lastPathComponent))
            }
            counts[source.id] = found.count
            for (file, name) in found where seen.insert(file.standardizedFileURL.path(percentEncoded: false)).inserted {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= fileSizeLimit else {
                    problems.append(
                        ProtoFileProblem(file: name, line: 0, message: "This file is too big to be a .proto file."))
                    continue
                }
                guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
                    problems.append(
                        ProtoFileProblem(file: name, line: 0, message: "Reqly can't read this file as text."))
                    continue
                }
                files.append((name, text))
            }
        }
        let loaded = ProtobufSchema.load(files)
        return (loaded.schema, problems + loaded.problems, counts)
    }
}
