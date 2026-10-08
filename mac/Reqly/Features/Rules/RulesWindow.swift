import ReqlyModel
import SwiftUI

/// The Rules window: every kind of rule, each with a switch and its list of rules.
struct RulesWindow: View {
    @Environment(RulesModel.self) private var rules

    var body: some View {
        @Bindable var rules = rules
        NavigationSplitView {
            List(selection: section) {
                ForEach(RuleKind.allCases, id: \.self) { kind in
                    HStack {
                        Label(kind.title, systemImage: kind.symbol)
                        Spacer()
                        if rules.isOn(kind) {
                            Circle()
                                .fill(Color("StatusSuccess"))
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("On")
                        }
                    }
                    .tag(kind)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                if rules.section == .slowNetwork {
                    SlowNetworkPane()
                } else {
                    RuleListPane(kind: rules.section)
                        .id(rules.section)
                }
            }
            .navigationSplitViewColumnWidth(min: 520, ideal: 600)
        }
        .navigationTitle(rules.section.title)
        .sheet(item: $rules.editing) { draft in
            if draft.kind == .script {
                ScriptEditor(draft: draft)
            } else {
                RuleEditor(draft: draft)
            }
        }
    }

    /// The sidebar always has a section selected.
    private var section: Binding<RuleKind?> {
        Binding(
            get: { rules.section },
            set: { if let kind = $0 { rules.section = kind } }
        )
    }
}

/// One kind's rules: its switch, the list, and how the rules act.
private struct RuleListPane: View {
    @Environment(RulesModel.self) private var rules
    let kind: RuleKind
    @State private var selection: UUID?

    var body: some View {
        let list = rules.rules(kind)
        Form {
            if let problem = rules.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Section {
                KindSwitch(kind: kind)
            }
            Section {
                if list.isEmpty {
                    Text("No rules yet. Add one with the + button, or right-click a request in the list.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(list) { rule in
                        RuleRow(rule: rule, isSelected: selection == rule.id)
                            .contentShape(.rect)
                            .gesture(TapGesture(count: 2).onEnded { rules.edit(rule) })
                            .simultaneousGesture(TapGesture().onEnded { selection = rule.id })
                            .contextMenu { menu(for: rule, in: list) }
                            .selectedRow(selection == rule.id)
                    }
                    .onMove { rules.move(kind, from: $0, to: $1) }
                }
                // The list's own buttons, in its last row, as in a table of rules.
                HStack(spacing: 0) {
                    ListBarButton("Add Rule", systemImage: "plus") {
                        rules.newRule(kind)
                    }
                    ListBarButton("Remove Rule", systemImage: "minus") {
                        removeSelected()
                    }
                    .disabled(selected == nil)
                    Spacer()
                    Button("Edit…") {
                        if let selected { rules.edit(selected) }
                    }
                    .controlSize(.small)
                    .disabled(selected == nil)
                }
            } header: {
                Text("Rules")
            } footer: {
                Text(
                    "Rules match a host, a path and a method. Use * to match anything. \(kind.orderNote) You can also add a rule by right-clicking a request."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDeleteCommand(perform: removeSelected)
    }

    private var selected: Rule? {
        rules.rules(kind).first { $0.id == selection }
    }

    private func removeSelected() {
        guard let selection else { return }
        rules.remove([selection])
        self.selection = nil
    }

    @ViewBuilder
    private func menu(for rule: Rule, in list: [Rule]) -> some View {
        Button("Edit…") { rules.edit(rule) }
        Button("Duplicate") {
            var copy = rule
            copy.id = UUID()
            copy.name = "\(rule.name) copy"
            rules.save(copy)
        }
        Divider()
        Button("Move Up") { rules.move(rule, by: -1) }
            .disabled(list.first?.id == rule.id)
        Button("Move Down") { rules.move(rule, by: 1) }
            .disabled(list.last?.id == rule.id)
        Divider()
        Button("Delete") {
            rules.remove([rule.id])
            if selection == rule.id {
                selection = nil
            }
        }
    }
}

/// The switch for a whole kind of rule, with what the kind does.
struct KindSwitch: View {
    @Environment(RulesModel.self) private var rules
    let kind: RuleKind

    var body: some View {
        Toggle(isOn: Binding(get: { rules.isOn(kind) }, set: { rules.setOn($0, for: kind) })) {
            Text(kind.title)
            Text(kind.explanation)
        }
        .toggleStyle(.switch)
    }
}

/// A rule in the list: its switch, its name and what it matches, and a word on what it does.
private struct RuleRow: View {
    @Environment(RulesModel.self) private var rules
    let rule: Rule
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Use This Rule", isOn: Binding(get: { rule.isOn }, set: { rules.setRule(rule.id, on: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .lineLimit(1)
                Text(rule.match.description)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(tag)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.fill.tertiary, in: .capsule)
        }
        .padding(.vertical, 2)
        .opacity(rule.isOn ? 1 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// What the rule does, in a word or two.
    private var tag: String {
        switch rule.action {
        case .breakpoint(let phase): phase.title
        case .mapLocal(let local): (local.path as NSString).lastPathComponent
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

extension BreakpointPhase {
    var title: String {
        switch self {
        case .request: "Request"
        case .response: "Response"
        case .both: "Both"
        }
    }
}
