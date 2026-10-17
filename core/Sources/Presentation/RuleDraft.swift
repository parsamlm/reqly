import Foundation
import ReqlyModel

/// A rule as you edit it, before it's saved. The Mac's rule editors and the Windows app's work the
/// same: they fill in a new rule from a request alike, and say what to fix in the same words.
public struct RuleDraft: Identifiable, Sendable {
    public let id: UUID
    public let isNew: Bool
    public let kind: RuleKind
    public var isOn = true
    public var name = ""
    public var host = ""
    public var path = ""
    /// Empty for any method.
    public var method = ""

    public var phase = BreakpointPhase.both
    public var file = ""
    public var status = 200
    /// Empty to take the type from the file's extension.
    public var contentType = ""
    public var destination = ""
    public var changes: [RewriteDraft] = []
    public var closesConnection = false
    public var blockStatus = 403
    public var code = ScriptExamples.starter
    /// The request the rule was made from, for saving its response as Map Local's file.
    public var exchange: ExchangeID?

    /// A draft with nothing filled in yet, for an editor that fills it in itself.
    public init(id: UUID, isNew: Bool, kind: RuleKind) {
        self.id = id
        self.isNew = isNew
        self.kind = kind
    }

    public init(rule: Rule) {
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
    public init(kind: RuleKind, from summary: ExchangeSummary?) {
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

    public var match: RequestMatch {
        let host = host.trimmingCharacters(in: .whitespaces)
        let path = path.trimmingCharacters(in: .whitespaces)
        return RequestMatch(
            host: host.isEmpty ? "*" : host, path: path.isEmpty ? "*" : path, method: method.isEmpty ? nil : method)
    }

    /// What to fix before the rule can be saved, if anything.
    public var problem: String? {
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
    public var rule: Rule? {
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
    public var defaultName: String {
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

// MARK: The requests it matches

extension RuleDraft {
    /// How many of the requests captured so far the rule would act on. An encrypted connection
    /// has no path or method to match, only its host, so it counts only for a Block rule for the
    /// whole host.
    public func matchCount(in summaries: some Sequence<ExchangeSummary>) -> Int {
        let match = match
        let matchesTunnels = kind == .block && match.path == "*" && match.method == nil
        return summaries.count { summary in
            (summary.kind == .http || matchesTunnels) && match.matches(summary)
        }
    }

    /// The requests captured so far that the rule matches, newest first, to try a script on.
    public func matchingRequests(in summaries: some BidirectionalCollection<ExchangeSummary>, limit: Int = 50)
        -> [ExchangeSummary]
    {
        let match = match
        return Array(summaries.reversed().lazy.filter { $0.kind == .http && match.matches($0) }.prefix(limit))
    }

    /// A request as the script editor offers it to try the script on, such as
    /// `GET api.weatherly.dev/v2/forecast?days=3 · 200`.
    public static func describe(_ summary: ExchangeSummary) -> String {
        let isDefaultPort =
            (summary.scheme == "http" && summary.port == 80) || (summary.scheme == "https" && summary.port == 443)
        let status = summary.status.map { " · \($0)" } ?? ""
        var address = (isDefaultPort ? summary.host : "\(summary.host):\(summary.port)") + summary.target
        if address.count > 72 {
            address = address.prefix(71) + "…"
        }
        return "\(summary.method) \(address)\(status)"
    }
}

// MARK: In the list

extension Rule {
    /// What the rule does, in a word or two, as the Rules window's list says it: `Response`,
    /// `forecast.json`, `staging.weatherly.dev`, `2 changes`, `403`.
    public var tag: String {
        switch action {
        case .breakpoint(.request): "Request"
        case .breakpoint(.response): "Response"
        case .breakpoint(.both): "Both"
        // A path from either system: `~/Responses/forecast.json` or `C:\Responses\forecast.json`.
        case .mapLocal(let local):
            local.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? local.path
        case .mapRemote(let remote): URLComponents(string: remote.destination)?.host ?? remote.destination
        case .rewrite(let changes): changes.count == 1 ? "1 change" : "\(changes.count) changes"
        case .block(.status(let code)): String(code)
        case .block(.closeConnection): "Close"
        case .script(let script):
            switch (script.runsOnRequest, script.runsOnResponse) {
            case (true, true): "Both"
            case (true, false): "Request"
            case (false, true): "Response"
            case (false, false): "Nothing"
            }
        }
    }
}

/// One change of a Rewrite rule, as you edit it.
public struct RewriteDraft: Identifiable, Hashable, Sendable {
    /// Each app titles these in its own style, as its menus are.
    public enum Change: String, CaseIterable, Identifiable, Codable, Sendable {
        case setHeader, removeHeader, setQueryParameter, removeQueryParameter, replaceBody, setStatus

        public var id: Self { self }

        /// Whether it can change the request or the response, rather than just one of them.
        public var hasPart: Bool { self == .setHeader || self == .removeHeader || self == .replaceBody }
        public var hasValue: Bool { self == .setHeader || self == .setQueryParameter || self == .replaceBody }
    }

    public let id = UUID()
    public var change = Change.setHeader
    public var part = MessagePart.request
    /// The header or parameter, or the text to find.
    public var name = ""
    /// The value to set, or the text to replace with.
    public var value = ""
    public var status = 200

    public init() {}

    public init(_ rewrite: Rewrite) {
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

    public var problem: String? {
        switch change {
        case .setStatus: (100...599).contains(status) ? nil : "Enter a status from 100 to 599."
        case .replaceBody: name.isEmpty ? "Enter the body text to replace." : nil
        case .setHeader, .removeHeader:
            name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter the header's name." : nil
        case .setQueryParameter, .removeQueryParameter:
            name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter the query parameter's name." : nil
        }
    }

    public var rewrite: Rewrite? {
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
