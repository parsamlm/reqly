import Foundation
import ReqlyModel

/// The rules, saved as JSON in Application Support so they're there the next time Reqly opens.
public enum RulesFile {
    /// The version this Reqly writes. A file from a newer Reqly isn't read, or written over.
    /// Version 2 added scripts.
    public static let version = 2

    public enum Problem: Error, Equatable {
        case newerVersion(Int)
    }

    private struct Contents: Codable {
        var version: Int
        var ruleSet: RuleSet
    }

    /// The saved rules, or none if nothing was saved yet.
    public static func load(from url: URL) throws -> RuleSet {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return RuleSet()
        }
        let version = try JSONDecoder().decode(Version.self, from: data).version
        guard version <= Self.version else { throw Problem.newerVersion(version) }
        return try JSONDecoder().decode(Contents.self, from: data).ruleSet
    }

    public static func save(_ rules: RuleSet, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Contents(version: version, ruleSet: rules))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private struct Version: Decodable {
        var version: Int
    }
}
