import Capture
import Foundation
import Presentation
import ReqlyModel

/// The rules as the app's Rules window edits them. They're kept in the rules file, the same JSON
/// the Mac keeps, and each change is saved and goes to the session.
struct RulesBook {
    private(set) var set = RuleSet()
    /// Why the rules can't be read or saved, if they can't.
    private(set) var problem: String?
    private var file: URL?
    /// The file is a newer Reqly's, so it isn't written over.
    private var isReadOnly = false

    mutating func open(_ url: URL) {
        let opened = RulesFile.open(url)
        set = opened.rules
        isReadOnly = opened.isReadOnly
        problem = opened.problem
        file = url
    }

    /// Changes the rules, and saves them if they changed. Says whether they did.
    mutating func change(_ body: (inout RuleSet) -> Void) -> Bool {
        var changed = set
        body(&changed)
        guard changed != set else { return false }
        set = changed
        guard let file, !isReadOnly else { return true }
        do {
            try RulesFile.save(changed, to: file)
            problem = nil
        } catch {
            problem = RulesFile.saveProblem(error)
        }
        return true
    }

    var wire: WireRules {
        WireRules(
            kindsOn: RuleKind.allCases.filter(set.kindsOn.contains),
            rules: set.rules.map {
                WireRules.Row(
                    id: $0.id, kind: $0.kind, name: $0.name, isOn: $0.isOn, match: $0.match.description, tag: $0.tag)
            },
            network: set.network, problem: problem)
    }
}

extension RuleSet {
    /// Moves a rule to another place among the rules of its kind, as dragging it in the list
    /// does. The first rule that matches a request is the one that acts, so the order matters.
    mutating func move(_ id: UUID, to place: Int) {
        guard let rule = rules.first(where: { $0.id == id }) else { return }
        var list = rules.filter { $0.kind == rule.kind && $0.id != id }
        list.insert(rule, at: min(max(place, 0), list.count))
        var next = list.makeIterator()
        rules = rules.map { $0.kind == rule.kind ? (next.next() ?? $0) : $0 }
    }
}

/// The rules as the Rules window lists them.
struct WireRules: Encodable {
    struct Row: Encodable {
        var id: UUID
        var kind: RuleKind
        var name: String
        var isOn: Bool
        /// Such as `GET · api.weatherly.dev/v2/forecast*`.
        var match: String
        /// What the rule does, in a word or two, such as `Response` or `403`.
        var tag: String
    }

    /// The kinds that are on, in the order the Rules window lists them.
    var kindsOn: [RuleKind]
    var rules: [Row]
    /// What Slow Network slows down, and how much.
    var network: NetworkConditions
    var problem: String?
}

/// A rule as the app's editor edits it: a ``RuleDraft``, field for field.
public struct WireRuleDraft: Codable, Sendable, Equatable {
    public struct Change: Codable, Sendable, Equatable {
        public var change: RewriteDraft.Change
        public var part: MessagePart
        /// The header or parameter, or the text to find.
        public var name: String
        /// The value to set, or the text to replace with.
        public var value: String
        public var status: Int
    }

    public var id: UUID
    public var isNew: Bool
    public var kind: RuleKind
    public var isOn: Bool
    public var name: String
    public var host: String
    public var path: String
    /// Empty for any method.
    public var method: String
    public var phase: BreakpointPhase
    public var file: String
    public var status: Int
    /// Empty to take the type from the file's extension.
    public var contentType: String
    public var destination: String
    public var changes: [Change]
    public var closesConnection: Bool
    public var blockStatus: Int
    public var code: String
    /// The exchange the rule was made from, for saving its response as Map Local's file.
    public var exchange: UInt64?

    init(_ draft: RuleDraft) {
        id = draft.id
        isNew = draft.isNew
        kind = draft.kind
        isOn = draft.isOn
        name = draft.name
        host = draft.host
        path = draft.path
        method = draft.method
        phase = draft.phase
        file = draft.file
        status = draft.status
        contentType = draft.contentType
        destination = draft.destination
        changes = draft.changes.map {
            Change(change: $0.change, part: $0.part, name: $0.name, value: $0.value, status: $0.status)
        }
        closesConnection = draft.closesConnection
        blockStatus = draft.blockStatus
        code = draft.code
        exchange = draft.exchange?.rawValue
    }

    var draft: RuleDraft {
        var draft = RuleDraft(id: id, isNew: isNew, kind: kind)
        draft.isOn = isOn
        draft.name = name
        draft.host = host
        draft.path = path
        draft.method = method
        draft.phase = phase
        draft.file = file
        draft.status = status
        draft.contentType = contentType
        draft.destination = destination
        draft.changes = changes.map {
            var change = RewriteDraft()
            change.change = $0.change
            change.part = $0.part
            change.name = $0.name
            change.value = $0.value
            change.status = $0.status
            return change
        }
        draft.closesConnection = closesConnection
        draft.blockStatus = blockStatus
        draft.code = code
        draft.exchange = exchange.map(ExchangeID.init(rawValue:))
        return draft
    }
}

/// What the editor shows under a draft as you edit it.
struct WireRuleCheck: Encodable {
    struct Request: Encodable {
        var id: UInt64
        /// Such as `GET api.weatherly.dev/v2/forecast · 200`.
        var description: String
    }

    /// What to fix before the rule can be saved, if anything.
    var problem: String?
    /// The name the rule gets when you don't give it one.
    var defaultName: String
    /// How many requests captured so far the rule would act on.
    var matchCount: Int
    /// For a script: the requests captured so far to try it on, newest first.
    var matching: [Request]?
}
