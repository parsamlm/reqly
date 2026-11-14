import CGtk
import CoreInterface
import GtkBinding
import ReqlyModel

extension App {
    /// The app's actions, `app.<name>`, each in one place, calling the feature that owns it, with
    /// their keyboard shortcuts, which work in every Reqly window. The live session's commands
    /// show the live window first, made if it never was, and act there: New Request, Devices,
    /// Set Up HTTPS…, Settings, Welcome and Show Rules. The rule kinds' switches and Continue All
    /// Paused Requests change only the live session, so they work from any window, as the Mac's
    /// menu bar lets them. Dialogs open once the menu has closed: see ``afterMenu(_:)``. While a
    /// dialog shows, the shortcuts wait, as the windows' own do; Quit, Settings, About and the
    /// three that Settings › HTTPS has too don't, as before.
    func addActions() {
        add("new-request", accelerator: "<Control>n") { [weak self] in self?.forLive { $0.newRequest() } }
        add("open", accelerator: "<Control>o") { [weak self] in self?.inFront { $0.openFiles() } }
        add("show-live-traffic") { [weak self] in self?.presentLive() }
        add("devices", accelerator: "<Shift><Control>d") { [weak self] in self?.forLive { $0.showDevices() } }
        // Settings › HTTPS has these three too, so they don't wait for it.
        add("set-up-https", waitsForDialogs: false) { [weak self] in self?.forLive { $0.setUpHTTPS() } }
        add("open-terminal", waitsForDialogs: false) { [weak self] in self?.windowInFront?.openTerminal() }
        add("copy-terminal-setup", waitsForDialogs: false) { [weak self] in
            self?.windowInFront?.copyTerminalSetup()
        }
        add("settings", accelerator: "<Control>comma", waitsForDialogs: false) { [weak self] in
            self?.forLive { $0.showSettings() }
        }
        add("shortcuts", accelerator: "<Control>question") { [weak self] in self?.inFront { $0.showShortcuts() } }
        add("welcome") { [weak self] in self?.forLive { $0.showWelcome() } }
        add("about", waitsForDialogs: false) { [weak self] in self?.inFront { $0.showAbout() } }
        add("quit", accelerator: "<Control>q", waitsForDialogs: false) { [weak self] in self?.quit() }

        for kind in RuleKind.allCases {
            let action = g_simple_action_new_stateful(kind.actionName, nil, g_variant_new_boolean(0))!
            connect(action, "activate") { [weak self] in
                guard let self, !dialogShows else { return }
                switchRuleKind(kind)
            }
            g_action_map_add_action(cast(application), cast(action))
            g_object_unref(raw(action))
            if let keys = kind.accelerator {
                withCStrings([keys]) {
                    gtk_application_set_accels_for_action(cast(application), "app.\(kind.actionName)", $0)
                }
            }
        }
        add("continue-all", accelerator: "<Control><Alt>Return") { [weak self] in self?.continueAllPaused() }
        add("show-rules", accelerator: "<Control><Alt>r") { [weak self] in self?.forLive { $0.showRules() } }
        model.observe { [weak self] in self?.showRuleActions() }
        showRuleActions()
    }

    /// Runs `body` with the live window, shown first, once the main menu, whose entry may have
    /// run the action, has closed: see ``afterMenu(_:)``.
    private func forLive(_ body: @escaping @MainActor (MainWindow) -> Void) {
        afterMenu { [weak self] in
            guard let self else { return }
            body(presentLive())
        }
    }

    /// Runs `body` with the Reqly window in front, once the main menu has closed.
    private func inFront(_ body: @escaping @MainActor (MainWindow) -> Void) {
        afterMenu { [weak self] in
            if let window = self?.windowInFront {
                body(window)
            }
        }
    }

    /// Runs `body` once the main menu, whose entry may have run the action, has closed and given
    /// the keyboard's focus back to its button. A dialog opened from the entry itself would give
    /// the focus back to the entry as it closes, in the hidden menu, as libadwaita 1.5 does, which
    /// leaves the window's shortcuts and Tab doing nothing.
    private func afterMenu(_ body: @escaping @MainActor () -> Void) {
        idle {
            body()
            return false
        }
    }

    /// Adds the action `app.<name>`, which runs `body`, with its keyboard shortcut, unless a
    /// dialog shows over the window in front and it `waitsForDialogs`.
    private func add(
        _ name: String, accelerator: String? = nil, waitsForDialogs: Bool = true,
        _ body: @escaping @MainActor () -> Void
    ) {
        let action = g_simple_action_new(name, nil)!
        connect(action, "activate") { [weak self] in
            guard let self, !waitsForDialogs || !dialogShows else { return }
            body()
        }
        g_action_map_add_action(cast(application), cast(action))
        g_object_unref(raw(action))
        if let accelerator {
            withCStrings([accelerator]) { gtk_application_set_accels_for_action(cast(application), "app.\(name)", $0) }
        }
    }

    private func action(_ name: String) -> OpaquePointer? {
        g_action_map_lookup_action(cast(application), name)
    }

    /// The rule kinds' switches as the live session's rules are, and Continue All Paused Requests
    /// on while a breakpoint holds something. All wait for the session's rules.
    private func showRuleActions() {
        let kindsOn = model.rules?.set.kindsOn ?? []
        for kind in RuleKind.allCases {
            let action = action(kind.actionName)
            g_simple_action_set_enabled(action, cBool(model.rules != nil))
            let isOn = kindsOn.contains(kind)
            if let state = g_action_get_state(cast(action)) {
                let wasOn = g_variant_get_boolean(state) != 0
                g_variant_unref(state)
                if wasOn == isOn {
                    continue
                }
            }
            g_simple_action_set_state(action, g_variant_new_boolean(cBool(isOn)))
        }
        g_simple_action_set_enabled(action("continue-all"), cBool(!model.paused.isEmpty))
        liveWindow?.showRulesButton()
    }

    /// Turns a rule kind on or off in the live session, as its switch in the Rules menu does, or
    /// Shift+Ctrl+B and Shift+Ctrl+T.
    private func switchRuleKind(_ kind: RuleKind) {
        guard let session = model.session, let rules = model.rules else { return }
        let isOn = !rules.set.kindsOn.contains(kind)
        Task {
            model.rules = await session.setRuleKindOn(kind, isOn: isOn)
            ruleKindSwitched(kind, isOn: isOn)
        }
    }

    /// Continue All Paused Requests: every request and response breakpoints hold goes on as it
    /// is, in the live session, the only one that pauses.
    private func continueAllPaused() {
        guard let session = model.session, !model.paused.isEmpty else { return }
        Task { await session.continueAllPaused() }
    }
}

extension RuleKind {
    /// The action of the kind's switch, `app.<name>`, as the Rules menu has them.
    var actionName: String {
        switch self {
        case .breakpoint: "breakpoints"
        case .mapLocal: "map-local"
        case .mapRemote: "map-remote"
        case .rewrite: "rewrite"
        case .block: "block"
        case .script: "scripts"
        case .slowNetwork: "slow-network"
        }
    }

    /// The kind's keyboard shortcut, as the Mac's Shift+Command+B and Shift+Command+T.
    var accelerator: String? {
        switch self {
        case .breakpoint: "<Shift><Control>b"
        case .slowNetwork: "<Shift><Control>t"
        default: nil
        }
    }
}
