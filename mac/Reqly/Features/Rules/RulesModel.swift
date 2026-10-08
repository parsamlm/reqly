import Capture
import Foundation
import Observation
import ReqlyModel

/// The rules that change traffic, as the Rules window edits them. Each change is saved, and
/// applies to the requests that start from then on.
@Observable
final class RulesModel {
    private(set) var ruleSet = RuleSet()
    /// The section the Rules window shows.
    var section = RuleKind.breakpoint
    /// The rule open in the Rules window's editor, new or not.
    var editing: RuleDraft?
    /// Why the rules can't be read or saved, if they can't.
    private(set) var problem: String?

    private let session: CaptureSession
    private let url: URL
    /// The saved rules come from a newer Reqly, so they aren't written over.
    private var isReadOnly = false

    init(session: CaptureSession) {
        self.session = session
        url = Self.fileURL
        do {
            ruleSet = try RulesFile.load(from: url)
        } catch RulesFile.Problem.newerVersion {
            isReadOnly = true
            problem =
                "A newer version of Reqly saved the rules, so this one can't use them. Changes you make here aren't saved."
        } catch {
            // Kept, not lost: the file may have been edited by hand.
            let kept = url.deletingLastPathComponent().appending(path: "Rules (unreadable).json")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: url, to: kept)
            problem =
                "Reqly couldn't read its saved rules, so it moved them to “\(kept.lastPathComponent)” and started over."
        }
        session.setRules(ruleSet)
    }

    /// Where the rules are saved. A debug build takes another file from `-rulesFile path`, so
    /// trying things out leaves your own rules alone.
    private static var fileURL: URL {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: DefaultsKey.rulesFile) {
                return URL(filePath: path)
            }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Reqly/Rules.json")
    }

    func isOn(_ kind: RuleKind) -> Bool {
        ruleSet.kindsOn.contains(kind)
    }

    func setOn(_ isOn: Bool, for kind: RuleKind) {
        change { rules in
            if isOn {
                rules.kindsOn.insert(kind)
            } else {
                rules.kindsOn.remove(kind)
            }
        }
    }

    /// The rules of one kind, in the order they act.
    func rules(_ kind: RuleKind) -> [Rule] {
        ruleSet.rules.filter { $0.kind == kind }
    }

    /// How many rules of a kind act right now. None do while their kind is off.
    func activeCount(_ kind: RuleKind) -> Int {
        guard isOn(kind) else { return 0 }
        if kind == .slowNetwork { return 1 }
        return rules(kind).count { $0.isOn }
    }

    /// Adds a rule, or replaces the one with the same ID.
    /// The script's syntax error, with its line, or `nil` when it compiles.
    func checkScript(_ code: String) async -> String? {
        await session.checkScript(code)
    }

    /// What a script would do to a request captured earlier, and to its response.
    func tryScript(_ code: String, on exchange: ExchangeID) async -> [ScriptTrial] {
        await session.tryScript(code, on: exchange)
    }

    func save(_ rule: Rule) {
        change { rules in
            if let index = rules.rules.firstIndex(where: { $0.id == rule.id }) {
                rules.rules[index] = rule
            } else {
                rules.rules.append(rule)
            }
        }
    }

    func setRule(_ id: UUID, on isOn: Bool) {
        change { rules in
            if let index = rules.rules.firstIndex(where: { $0.id == id }) {
                rules.rules[index].isOn = isOn
            }
        }
    }

    func remove(_ ids: Set<UUID>) {
        change { $0.rules.removeAll { ids.contains($0.id) } }
    }

    /// Moves rules within their kind, as dragging them in the list does. The order matters:
    /// the first rule that matches a request is the one that acts.
    func move(_ kind: RuleKind, from source: IndexSet, to destination: Int) {
        var reordered = rules(kind)
        reordered.move(fromOffsets: source, toOffset: destination)
        var next = reordered.makeIterator()
        change { rules in
            rules.rules = rules.rules.map { $0.kind == kind ? (next.next() ?? $0) : $0 }
        }
    }

    /// Moves a rule one place up or down among the rules of its kind.
    func move(_ rule: Rule, by offset: Int) {
        let list = rules(rule.kind)
        guard let index = list.firstIndex(where: { $0.id == rule.id }), list.indices.contains(index + offset) else {
            return
        }
        move(rule.kind, from: [index], to: offset > 0 ? index + offset + 1 : index + offset)
    }

    var network: NetworkConditions {
        get { ruleSet.network }
        set { change { $0.network = newValue } }
    }

    /// Opens the editor on a new rule, filled in from a request when there is one.
    func newRule(_ kind: RuleKind, from summary: ExchangeSummary? = nil) {
        section = kind
        editing = RuleDraft(kind: kind, from: summary)
    }

    func edit(_ rule: Rule) {
        section = rule.kind
        editing = RuleDraft(rule: rule)
    }

    private func change(_ body: (inout RuleSet) -> Void) {
        var changed = ruleSet
        body(&changed)
        guard changed != ruleSet else { return }
        ruleSet = changed
        session.setRules(changed)
        guard !isReadOnly else { return }
        do {
            try RulesFile.save(changed, to: url)
            problem = nil
        } catch {
            problem = "Reqly couldn't save the rules. \(error.localizedDescription)"
        }
    }
}

extension RuleKind {
    var title: String {
        switch self {
        case .breakpoint: "Breakpoints"
        case .mapLocal: "Map Local"
        case .mapRemote: "Map Remote"
        case .rewrite: "Rewrite"
        case .block: "Block"
        case .script: "Scripts"
        case .slowNetwork: "Slow Network"
        }
    }

    /// One rule of the kind, as an editor's title names it: "New Breakpoint".
    var ruleTitle: String {
        switch self {
        case .breakpoint: "Breakpoint"
        case .mapLocal: "Map Local Rule"
        case .mapRemote: "Map Remote Rule"
        case .rewrite: "Rewrite Rule"
        case .block: "Block Rule"
        case .script: "Script"
        case .slowNetwork: "Slow Network"
        }
    }

    /// The kind as the Add Rule menu lists it.
    var menuTitle: String {
        switch self {
        case .breakpoint: "Breakpoint…"
        case .mapLocal: "Map Local…"
        case .mapRemote: "Map Remote…"
        case .rewrite: "Rewrite…"
        case .block: "Block…"
        case .script: "Script…"
        case .slowNetwork: "Slow Network…"
        }
    }

    var symbol: String {
        switch self {
        case .breakpoint: "pause.circle"
        case .mapLocal: "doc"
        case .mapRemote: "arrow.triangle.branch"
        case .rewrite: "pencil"
        case .block: "nosign"
        case .script: "chevron.left.forwardslash.chevron.right"
        case .slowNetwork: "tortoise"
        }
    }

    /// The symbol for a toolbar switch that's on.
    var onSymbol: String {
        switch self {
        case .breakpoint: "pause.circle.fill"
        case .mapLocal: "doc.fill"
        case .slowNetwork: "tortoise.fill"
        default: symbol
        }
    }

    var explanation: String {
        switch self {
        case .breakpoint:
            "Pause matching traffic so you can edit it before it continues. You can also turn this on from the toolbar."
        case .mapLocal: "Answer matching requests with a file on your Mac. The server never sees them."
        case .mapRemote: "Send matching requests to another server, such as staging instead of production."
        case .rewrite: "Change the headers, query, body text or status of matching traffic as it passes."
        case .block: "Stop matching requests, with a status of your choice or by closing the connection."
        case .script:
            "Run JavaScript on matching traffic, to change requests and responses as they pass, or to answer requests yourself."
        case .slowNetwork: "Slow traffic down to the speed of a slower network, to see how apps cope."
        }
    }

    /// What the list's note says about the order of the rules.
    var orderNote: String {
        switch self {
        case .rewrite: "Every rule that matches makes its changes, in the order of the list."
        case .script:
            "Every script that matches runs, in the order of the list, after Rewrite rules and before breakpoints."
        case .mapLocal:
            "When several rules match a request, the first one in the list acts. Block rules act before Map Local."
        default: "When several rules match a request, the first one in the list acts."
        }
    }

    /// The kinds that are rules of their own, as the Add Rule menu offers them.
    static let rules: [RuleKind] = [.breakpoint, .mapLocal, .mapRemote, .rewrite, .block, .script]
}
