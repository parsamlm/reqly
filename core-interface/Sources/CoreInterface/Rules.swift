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

    var state: RulesState {
        RulesState(set: set, problem: problem)
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

/// The rules as the Rules window lists them, and why they can't be read or saved, if they can't.
public struct RulesState: Sendable, Equatable {
    /// The rules, in order, the kinds that are on, and what Slow Network slows down.
    public var set: RuleSet
    public var problem: String?

    public init(set: RuleSet, problem: String? = nil) {
        self.set = set
        self.problem = problem
    }
}

/// What the editor shows under a draft as you edit it.
public struct RuleCheck: Sendable, Equatable {
    /// What to fix before the rule can be saved, if anything.
    public var problem: String?
    /// The name the rule gets when you don't give it one.
    public var defaultName: String
    /// How many requests captured so far the rule would act on.
    public var matchCount: Int
    /// For a script: the requests captured so far to try it on, newest first.
    public var matching: [ExchangeSummary]?

    public init(problem: String? = nil, defaultName: String, matchCount: Int, matching: [ExchangeSummary]? = nil) {
        self.problem = problem
        self.defaultName = defaultName
        self.matchCount = matchCount
        self.matching = matching
    }
}
