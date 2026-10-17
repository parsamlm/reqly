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

    /// The saved rules as Reqly opens them, and what went wrong, if anything.
    public struct Opened: Sendable {
        public var rules: RuleSet
        /// The file is a newer Reqly's, so changes aren't saved over it.
        public var isReadOnly: Bool
        public var problem: String?
    }

    /// Opens the saved rules. A file Reqly can't read is moved aside, so it's kept rather than
    /// lost, and Reqly starts over; one from a newer Reqly is left as it is.
    public static func open(_ url: URL) -> Opened {
        do {
            return Opened(rules: try load(from: url), isReadOnly: false, problem: nil)
        } catch Problem.newerVersion {
            return Opened(
                rules: RuleSet(), isReadOnly: true,
                problem:
                    "A newer version of Reqly saved the rules, so this one can't use them. Changes you make here aren't saved."
            )
        } catch {
            // Kept, not lost: the file may have been edited by hand.
            let kept = url.deletingLastPathComponent().appending(path: "Rules (unreadable).json")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: url, to: kept)
            return Opened(
                rules: RuleSet(), isReadOnly: false,
                problem:
                    "Reqly couldn't read its saved rules, so it moved them to “\(kept.lastPathComponent)” and started over."
            )
        }
    }

    /// What to say when the rules couldn't be saved.
    public static func saveProblem(_ error: any Error) -> String {
        "Reqly couldn't save the rules. \(error.localizedDescription)"
    }

    public static func save(_ rules: RuleSet, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Contents(version: version, ruleSet: rules))
        try FileReplacement.write(data, to: url)
    }

    private struct Version: Decodable {
        var version: Int
    }
}
