import BodyKit
import Foundation
import ReqlyModel

/// The `.proto` files Reqly reads protobuf and gRPC bodies with, and the message types chosen for
/// bodies that don't say theirs, as the Mac and the Windows app both keep them: the list is saved,
/// and the files are read again each time Reqly opens, so changes to them show up.
public enum ProtobufFiles {
    /// A `.proto` file, or a folder of them, that was added.
    public struct Source: Codable, Hashable, Identifiable, Sendable {
        public var path: String
        public var isFolder: Bool

        public init(path: String, isFolder: Bool) {
            self.path = path
            self.isFolder = isFolder
        }

        /// A file or a folder you chose.
        public init(_ url: URL) {
            isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            path = url.standardizedFileURL.path(percentEncoded: false)
        }

        public var id: String { path }
        public var url: URL { URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory) }
    }

    /// The list, as it's saved.
    public struct Contents: Codable, Hashable, Sendable {
        public var version = 1
        public var sources: [Source] = []
        /// Message types chosen for bodies, by ``key(for:isRequest:)``.
        public var chosenTypes: [String: String] = [:]

        public init(sources: [Source] = [], chosenTypes: [String: String] = [:]) {
            self.sources = sources
            self.chosenTypes = chosenTypes
        }
    }

    /// The saved list. One that's missing or can't be read is an empty one.
    public static func load(from url: URL) -> Contents {
        guard let data = try? Data(contentsOf: url), let contents = try? JSONDecoder().decode(Contents.self, from: data)
        else { return Contents() }
        return contents
    }

    public static func save(_ contents: Contents, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileReplacement.write(encoder.encode(contents), to: url)
    }

    /// What to say when the list couldn't be saved.
    public static func saveProblem(_ error: any Error) -> String {
        "Reqly couldn't save the list of .proto files: \(error.localizedDescription)"
    }

    /// Bodies are like one another when they're the same part of requests to the same host and
    /// path, such as responses from `api.weatherly.dev/v1/forecast`. A choice is kept for each.
    public static func key(for url: URL?, isRequest: Bool) -> String {
        "\(url?.host() ?? "")\(url?.path(percentEncoded: false) ?? "") \(isRequest ? "request" : "response")"
    }

    /// What the files hold, such as "14 message types and 2 services." Nothing without sources.
    public static func summary(_ schema: ProtobufSchema, hasSources: Bool) -> String {
        let messages = schema.messageNames.count
        let services = schema.services.count
        guard messages > 0 else { return hasSources ? "These files have no message types yet." : "" }
        let types = messages == 1 ? "1 message type" : "\(messages.formatted()) message types"
        switch services {
        case 0: return "\(types)."
        case 1: return "\(types) and 1 service."
        default: return "\(types) and \(services.formatted()) services."
        }
    }

    /// Files bigger than this aren't `.proto` files anyone wrote by hand.
    static let fileSizeLimit = 8 << 20
    /// A folder with more files than this is probably not the one meant.
    static let fileCountLimit = 5000

    /// What the sources hold: the message types, what's wrong with the files, and how many files each source has.
    public struct Reading: Sendable {
        public var schema: ProtobufSchema
        /// Reqly's own problems with the files, in the order of the sources, then the files' own.
        public var problems: [ProtoFileProblem]
        /// How many `.proto` files each source held, by its path. A missing one has none.
        public var counts: [String: Int]
    }

    /// Every `.proto` file the sources hold, then their types. A folder's files are named by
    /// their paths in it, the way imports name them.
    public static func read(_ sources: [Source]) -> Reading {
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
        return Reading(schema: loaded.schema, problems: problems + loaded.problems, counts: counts)
    }
}
