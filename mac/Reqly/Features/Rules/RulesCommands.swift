import ReqlyModel
import SwiftUI

/// The Rules menu: a switch for each kind of rule, with breakpoints' paused requests beside
/// them, then the Rules window.
struct RulesCommands: Commands {
    let rules: RulesModel
    let traffic: TrafficListModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Rules") {
            Toggle("Breakpoints", isOn: isOn(.breakpoint))
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Continue All Paused Requests") {
                traffic.continueAllPaused()
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(traffic.paused.isEmpty)

            Divider()

            Toggle("Map Local", isOn: isOn(.mapLocal))
            Toggle("Map Remote", isOn: isOn(.mapRemote))
            Toggle("Rewrite", isOn: isOn(.rewrite))
            Toggle("Block", isOn: isOn(.block))
            Toggle("Scripts", isOn: isOn(.script))

            Divider()

            Toggle("Slow Network", isOn: isOn(.slowNetwork))
                .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            Button("Show Rules") {
                openWindow(id: "rules")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }

    private func isOn(_ kind: RuleKind) -> Binding<Bool> {
        Binding(
            get: { rules.isOn(kind) },
            set: { RuleSwitching.set(kind, on: $0, rules: rules, openWindow: openWindow) }
        )
    }
}

/// Turns a kind of rule on or off from the toolbar.
struct RuleSwitch: View {
    @Environment(RulesModel.self) private var rules
    @Environment(\.openWindow) private var openWindow
    let kind: RuleKind

    var body: some View {
        let isOn = rules.isOn(kind)
        Toggle(
            isOn: Binding(
                get: { isOn },
                set: { RuleSwitching.set(kind, on: $0, rules: rules, openWindow: openWindow) }
            )
        ) {
            Label(kind.title, systemImage: isOn ? kind.onSymbol : kind.symbol)
        }
        .help(help(isOn: isOn))
    }

    private func help(isOn: Bool) -> String {
        switch (kind, isOn) {
        case (.breakpoint, true): "Breakpoints are on (⇧⌘B)"
        case (.breakpoint, false): "Turn On Breakpoints (⇧⌘B)"
        case (.slowNetwork, true): "Slow network is on: \(rules.network.profile.name) (⇧⌘T)"
        case (.slowNetwork, false): "Turn On Slow Network (⇧⌘T)"
        case (_, true): "\(kind.title) is on"
        case (_, false): "Turn On \(kind.title)"
        }
    }
}

enum RuleSwitching {
    /// Turns a kind of rule on or off. A kind with no rules yet does nothing on its own, so
    /// turning it on opens the Rules window to add one.
    static func set(_ kind: RuleKind, on isOn: Bool, rules: RulesModel, openWindow: OpenWindowAction) {
        rules.setOn(isOn, for: kind)
        if isOn, kind != .slowNetwork, rules.rules(kind).isEmpty {
            rules.section = kind
            openWindow(id: "rules")
        }
    }
}
