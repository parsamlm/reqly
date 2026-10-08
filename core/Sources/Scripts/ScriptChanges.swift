import Foundation
import ReqlyModel

/// What a script changed, in words.
public enum ScriptChanges {
    public static func describe(from before: ScriptRequest, to after: ScriptRequest) -> String {
        var changes: [String] = []
        if before.method != after.method {
            changes.append("the method to \(after.method)")
        }
        if before.url != after.url {
            changes.append("the URL")
        }
        changes += headers(before.headers, after.headers)
        if before.body != after.body {
            changes.append("the body")
        }
        return sentence(changes)
    }

    public static func describe(from before: ScriptResponse, to after: ScriptResponse) -> String {
        var changes: [String] = []
        if before.status != after.status {
            changes.append("the status to \(after.status)")
        }
        changes += headers(before.headers, after.headers)
        if before.body != after.body {
            changes.append("the body")
        }
        return sentence(changes)
    }

    /// "1 header" or "3 headers": the names added, removed or given other values.
    private static func headers(_ before: Headers, _ after: Headers) -> [String] {
        let names = Set(before.map { $0.name.lowercased() }).union(after.map { $0.name.lowercased() })
        let changed = names.filter { before.values(named: $0) != after.values(named: $0) }.count
        switch changed {
        case 0: return []
        case 1: return ["1 header"]
        default: return ["\(changed) headers"]
        }
    }

    private static func sentence(_ changes: [String]) -> String {
        switch changes.count {
        case 0: "Ran, and changed nothing."
        case 1: "Changed \(changes[0])."
        default: "Changed \(changes.dropLast().joined(separator: ", ")) and \(changes.last!)."
        }
    }
}
