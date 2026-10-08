import Foundation
import ReqlyModel

/// A rule as you edit it, before it's saved.
struct RuleDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    let kind: RuleKind
    var isOn = true
    var name = ""
    var host = ""
    var path = ""
    /// Empty for any method.
    var method = ""

    var phase = BreakpointPhase.both
    var file = ""
    var status = 200
    /// Empty to take the type from the file's extension.
    var contentType = ""
    var destination = ""
    var changes: [RewriteDraft] = []
    var closesConnection = false
    var blockStatus = 403
    var code = ScriptExamples.starter
    /// The request the rule was made from, for saving its response as Map Local's file.
    var exchange: ExchangeID?

    init(rule: Rule) {
        id = rule.id
        isNew = false
        kind = rule.kind
        isOn = rule.isOn
        name = rule.name
        host = rule.match.host == "*" ? "" : rule.match.host
        path = rule.match.path == "*" ? "" : rule.match.path
        method = rule.match.method ?? ""
        switch rule.action {
        case .breakpoint(let phase):
            self.phase = phase
        case .mapLocal(let local):
            file = local.path
            status = local.status
            contentType = local.contentType ?? ""
        case .mapRemote(let remote):
            destination = remote.destination
        case .rewrite(let rewrites):
            changes = rewrites.map(RewriteDraft.init)
        case .block(.status(let code)):
            blockStatus = code
        case .block(.closeConnection):
            closesConnection = true
        case .script(let script):
            code = script.code
        }
    }

    /// A new rule, for the request when there is one: its host, path and method.
    init(kind: RuleKind, from summary: ExchangeSummary?) {
        id = UUID()
        isNew = true
        self.kind = kind
        if kind == .rewrite {
            changes = [RewriteDraft()]
        }
        guard let summary else { return }
        exchange = summary.id
        let isDefaultPort =
            (summary.scheme == "http" && summary.port == 80) || (summary.scheme == "https" && summary.port == 443)
        host = isDefaultPort ? summary.host : "\(summary.host):\(summary.port)"
        // A tunnel has no path to see: its rule is for the whole host.
        if summary.kind == .http {
            path = summary.path
            method = summary.method
        }
        destination = "\(summary.scheme)://\(host)"
    }

    var match: RequestMatch {
        let host = host.trimmingCharacters(in: .whitespaces)
        let path = path.trimmingCharacters(in: .whitespaces)
        return RequestMatch(
            host: host.isEmpty ? "*" : host, path: path.isEmpty ? "*" : path, method: method.isEmpty ? nil : method)
    }

    /// What to fix before the rule can be saved, if anything.
    var problem: String? {
        switch kind {
        case .mapLocal where file.trimmingCharacters(in: .whitespaces).isEmpty:
            "Choose a file to answer with."
        case .mapLocal where !(100...599).contains(status),
            .block where !closesConnection && !(100...599).contains(blockStatus):
            "Enter a status from 100 to 599."
        case .mapRemote where !Self.isWebURL(destination):
            "Enter a URL that starts with http:// or https://."
        case .rewrite where changes.isEmpty:
            "Add a change."
        case .rewrite where changes.contains { $0.rewrite == nil }:
            changes.lazy.compactMap(\.problem).first
        case .script where !Script(code: code).runsOnRequest && !Script(code: code).runsOnResponse:
            "Write an onRequest or onResponse function."
        default:
            nil
        }
    }

    /// The rule to save, once there's nothing to fix.
    var rule: Rule? {
        guard problem == nil else { return nil }
        let action: RuleAction
        switch kind {
        case .breakpoint:
            action = .breakpoint(phase)
        case .mapLocal:
            let type = contentType.trimmingCharacters(in: .whitespaces)
            action = .mapLocal(
                MapLocal(
                    path: file.trimmingCharacters(in: .whitespaces), status: status,
                    contentType: type.isEmpty ? nil : type))
        case .mapRemote:
            action = .mapRemote(MapRemote(destination: destination.trimmingCharacters(in: .whitespaces)))
        case .rewrite:
            action = .rewrite(changes.compactMap(\.rewrite))
        case .block:
            action = .block(closesConnection ? .closeConnection : .status(blockStatus))
        case .script:
            action = .script(Script(code: code))
        case .slowNetwork:
            return nil
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        return Rule(id: id, name: name.isEmpty ? defaultName : name, isOn: isOn, match: match, action: action)
    }

    /// The name a rule gets when you don't give it one: its host and path.
    var defaultName: String {
        let host = match.host == "*" ? "Any host" : match.host
        return match.path == "*" ? host : host + (match.path.hasPrefix("/") ? "" : "/") + match.path
    }

    private static func isWebURL(_ text: String) -> Bool {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        return !(url.host ?? "").isEmpty
    }
}

/// One change of a Rewrite rule, as you edit it.
struct RewriteDraft: Identifiable, Hashable {
    enum Change: String, CaseIterable, Identifiable {
        case setHeader, removeHeader, setQueryParameter, removeQueryParameter, replaceBody, setStatus

        var id: Self { self }

        var title: String {
            switch self {
            case .setHeader: "Set Header"
            case .removeHeader: "Remove Header"
            case .setQueryParameter: "Set Query Parameter"
            case .removeQueryParameter: "Remove Query Parameter"
            case .replaceBody: "Replace Body Text"
            case .setStatus: "Set Status"
            }
        }

        /// Whether it can change the request or the response, rather than just one of them.
        var hasPart: Bool { self == .setHeader || self == .removeHeader || self == .replaceBody }
        var hasValue: Bool { self == .setHeader || self == .setQueryParameter || self == .replaceBody }
    }

    let id = UUID()
    var change = Change.setHeader
    var part = MessagePart.request
    /// The header or parameter, or the text to find.
    var name = ""
    /// The value to set, or the text to replace with.
    var value = ""
    var status = 200

    init() {}

    init(_ rewrite: Rewrite) {
        switch rewrite {
        case .setHeader(let part, let name, let value):
            (change, self.part, self.name, self.value) = (.setHeader, part, name, value)
        case .removeHeader(let part, let name):
            (change, self.part, self.name) = (.removeHeader, part, name)
        case .setQueryParameter(let name, let value):
            (change, self.name, self.value) = (.setQueryParameter, name, value)
        case .removeQueryParameter(let name):
            (change, self.name) = (.removeQueryParameter, name)
        case .replaceBody(let part, let find, let replace):
            (change, self.part, name, value) = (.replaceBody, part, find, replace)
        case .setStatus(let status):
            (change, part, self.status) = (.setStatus, .response, status)
        }
    }

    var problem: String? {
        switch change {
        case .setStatus: (100...599).contains(status) ? nil : "Enter a status from 100 to 599."
        case .replaceBody: name.isEmpty ? "Enter the body text to replace." : nil
        case .setHeader, .removeHeader:
            name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter the header's name." : nil
        case .setQueryParameter, .removeQueryParameter:
            name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter the query parameter's name." : nil
        }
    }

    var rewrite: Rewrite? {
        guard problem == nil else { return nil }
        let name = name.trimmingCharacters(in: .whitespaces)
        return switch change {
        case .setHeader: .setHeader(part, name: name, value: value)
        case .removeHeader: .removeHeader(part, name: name)
        case .setQueryParameter: .setQueryParameter(name: name, value: value)
        case .removeQueryParameter: .removeQueryParameter(name: name)
        // Body text is replaced exactly as written, spaces included.
        case .replaceBody: .replaceBody(part, find: self.name, replace: value)
        case .setStatus: .setStatus(status)
        }
    }
}
