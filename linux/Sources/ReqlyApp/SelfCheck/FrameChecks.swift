import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

extension SelfCheck {
    /// The app's frame: its windows, menus and shortcuts.
    static let frameParts: [Part] = [
        Part(name: "frame", seconds: 90) { try await $0.checkFrame() }
    ]

    /// The shortcuts have their actions; the Rules button and Shift+Ctrl+B turn Breakpoints on and
    /// off, and the button says so; Keyboard Shortcuts opens; the new actions wait behind a dialog;
    /// Shift+Ctrl+D runs Devices, not GTK's Inspector; a file's window has no capture switch or
    /// Rules button, the Request menu's entries in its rows' menu, and Show Live Traffic; Ctrl+W
    /// closes it, but not the live window. GTK warns of nothing meanwhile.
    func checkFrame() async throws {
        let window = window
        _ = try await session()
        try checkShortcutActions()
        let steps: [(String, () async throws -> Void)] = [
            ("the Rules button", { try await self.checkRulesButton(window) }),
            ("Keyboard Shortcuts", { try await self.checkShortcutsDialog(window) }),
            ("behind a dialog", { try await self.checkBehindADialog(window) }),
            ("Shift+Ctrl+D", { try await self.checkDevicesKey(window) }),
            ("a file's window", { try await self.checkFileWindow(window) }),
        ]
        for (name, step) in steps {
            let (_, lines) = try await standardError { try await step() }
            let complaints = lines.filter { $0.contains("-WARNING **") || $0.contains("-CRITICAL **") }
            try require(complaints.isEmpty, "with \(name), GTK said \(complaints.joined(separator: " | "))")
        }
    }

    /// Each shortcut Keyboard Shortcuts lists that's an action's has exactly its keys.
    private func checkShortcutActions() throws {
        let actions: [(String, String)] = [
            ("app.new-request", "<Control>n"), ("app.open", "<Control>o"), ("win.save-session", "<Control>s"),
            ("win.export-har", "<Shift><Control>e"), ("win.close", "<Control>w"), ("win.copy-url", "<Shift><Control>c"),
            ("win.copy-curl", "<Control><Alt>c"), ("app.breakpoints", "<Shift><Control>b"),
            ("app.slow-network", "<Shift><Control>t"), ("app.continue-all", "<Control><Alt>Return"),
            ("app.show-rules", "<Control><Alt>r"), ("app.devices", "<Shift><Control>d"),
            ("app.shortcuts", "<Control>question"), ("app.settings", "<Control>comma"), ("app.quit", "<Control>q"),
        ]
        let listed = Set(
            ShortcutList.sections.flatMap(\.items).flatMap { $0.keys.split(separator: " ") }.map(String.init))
        for (action, keys) in actions {
            var given: [String] = []
            if let accels = gtk_application_get_accels_for_action(cast(app.application), action) {
                var index = 0
                while let accel = accels[index] {
                    given.append(String(cString: accel))
                    index += 1
                }
                g_strfreev(accels)
            }
            try require(given == [keys], "\(action)'s shortcut is \(given), not \(keys)")
            try require(listed.contains(keys), "Keyboard Shortcuts doesn't list \(keys)")
        }
        note("shortcuts: \(actions.map { "\($0.1) \($0.0)" }.joined(separator: ", "))")
    }

    /// The Rules button, in the list's header bar, opens the Rules menu; Breakpoints' switch and
    /// Shift+Ctrl+B turn the kind on and off in the live session, and the button's name and icon
    /// follow.
    private func checkRulesButton(_ window: MainWindow) async throws {
        try await until("the live session's rules") { model.rules != nil }
        try require(
            gtk_widget_is_ancestor(window.rulesButton, window.listHeader) != 0,
            "the Rules button isn't in the list's header bar")
        try require(gtk_widget_get_visible(window.rulesButton) != 0, "the Rules button is hidden")
        let name = { gtk_widget_get_tooltip_text(window.rulesButton).map { String(cString: $0) } ?? "" }
        try require(name() == "Rules", "the Rules button is named \(name())")
        let breakpointsOn = { self.model.rules?.set.kindsOn.contains(.breakpoint) == true }
        try require(!breakpointsOn(), "Breakpoints are on as the check starts")
        activate("breakpoints")
        try await until("Breakpoints to turn on") { breakpointsOn() }
        try await until("the Rules button to say so") { name() == "Rules, Breakpoints on" }
        let icon = string(gtk_menu_button_get_icon_name(cast(window.rulesButton))) ?? ""
        try require(icon == RulesMenu.onIcon, "the Rules button's icon is \(icon)")
        note("Breakpoints' switch: on, the button named \(name()), with \(icon)")
        try FakeInput.press("Shift_L", "Control_L", "b", in: window.window)
        try await until("Shift+Ctrl+B to turn Breakpoints off") { !breakpointsOn() }
        try await until("the Rules button to say so") { name() == "Rules" }
        note("Shift+Ctrl+B: off again, the button named \(name())")
    }

    /// Keyboard Shortcuts opens over the window, and closes.
    private func checkShortcutsDialog(_ window: MainWindow) async throws {
        activate("shortcuts")
        try await until("Keyboard Shortcuts to open") { ShortcutsDialog.isShowing }
        await settle()
        let shortcuts = try present(ShortcutsDialog.kept, "there's no Keyboard Shortcuts")
        note("Keyboard Shortcuts: \(typeName(raw(shortcuts)))")
        if ShortcutsDialog.isDialog {
            adw_dialog_close(cast(shortcuts))
        } else {
            gtk_window_close(cast(shortcuts))
        }
        try await until("Keyboard Shortcuts to close") { !ShortcutsDialog.isShowing }
        await settle()
    }

    /// While About shows over the window, the new shortcuts' actions do nothing: Keyboard
    /// Shortcuts doesn't open, and Breakpoints stay off.
    private func checkBehindADialog(_ window: MainWindow) async throws {
        activate("about")
        try await until("About to open") { window.about.map { gtk_widget_get_mapped($0) != 0 } ?? false }
        await settle()
        for action in ["shortcuts", "breakpoints", "slow-network", "new-request", "devices", "show-rules", "open"] {
            activate(action)
        }
        for action in ["save-session", "export-har", "copy-url", "copy-curl"] {
            g_action_group_activate_action(cast(window.window), action, nil)
        }
        await settle()
        try require(!ShortcutsDialog.isShowing, "Keyboard Shortcuts opened over About")
        try require(model.rules?.set.kindsOn.isEmpty == true, "a rule kind turned on behind About")
        try require(window.about != nil, "About closed")
        adw_dialog_close(cast(window.about))
        try await until("About to close") { window.about == nil }
        await settle()
        note("behind About, the new actions did nothing")
    }

    /// Shift+Ctrl+D, GTK's own key for its Inspector too, runs Devices: GTK asks nothing about
    /// the Inspector, which would show a window of its own.
    private func checkDevicesKey(_ window: MainWindow) async throws {
        let devices = try present(
            g_action_map_lookup_action(cast(app.application), "devices"), "there's no app.devices")
        let runs = Counter()
        let handler = connect(devices, "activate") { runs.count += 1 }
        defer { g_signal_handler_disconnect(raw(devices), handler) }
        let before = toplevels()
        try FakeInput.press("Shift_L", "Control_L", "d", in: window.window)
        try await until("Shift+Ctrl+D to run Devices") { runs.count == 1 }
        await settle()
        let new = toplevels().filter { !before.contains($0) }
        try require(new.isEmpty, "Shift+Ctrl+D opened \(new.map { typeName(raw($0)) }.joined(separator: ", "))")
        try require(window.isShowing, "the live window doesn't show")
        note("Shift+Ctrl+D ran Devices, and no Inspector window opened")
    }

    /// A file's window, Mac 1.0.reqly's: its name as its title, no capture switch or Rules button,
    /// Show Live Traffic in its main menu, saving and exporting on, the Request menu's entries in
    /// its rows' menu, and Ctrl+W, pressed, closes it, but not the live window.
    private func checkFileWindow(_ window: MainWindow) async throws {
        app.open([try Self.macSession()])
        try await until("Mac 1.0.reqly's window") { app.fileWindows.first?.list.total ?? 0 > 0 }
        let file = try present(app.fileWindows.first, "there's no file window")
        try require(app.fileWindows.count == 1, "\(app.fileWindows.count) file windows show")
        let title = string(gtk_window_get_title(cast(file.window))) ?? ""
        try require(title == "Mac 1.0.reqly", "the file's window is titled \(title)")
        try require(gtk_widget_get_visible(file.captureBox) == 0, "the file's window shows the capture switch")
        try require(gtk_widget_get_visible(file.rulesButton) == 0, "the file's window shows the Rules button")
        let status = string(gtk_label_get_text(cast(file.statusLabel))) ?? ""
        try require(status == "Mac 1.0.reqly", "the file's status line says \(status)")
        for action in ["save-session", "export-har"] {
            try require(
                g_action_group_get_action_enabled(cast(file.window), action) != 0, "the file's \(action) is off")
        }
        let rowActions = file.list.menu.actions
        for command in RequestCommand.rowCommands {
            try require(
                g_action_group_has_action(cast(rowActions), command.actionName) != 0,
                "the rows' menu has no \(command.actionName)")
        }
        note("Mac 1.0.reqly's window: \(file.list.total) requests, \(status) in its status line")
        await settle()

        try FakeInput.press("Control_L", "w", in: window.window)
        await settle()
        try require(window.isShowing, "Ctrl+W hid the live window")
        try require(app.fileWindows.count == 1, "Ctrl+W in the live window closed the file's window")
        try FakeInput.press("Control_L", "w", in: file.window)
        try await until("Ctrl+W to close the file's window") { app.fileWindows.isEmpty }
        try require(window.isShowing && !app.isQuitting, "closing the file's window closed the live one")
        note("Ctrl+W: the live window stays; the file's window closes")
        await settle()
    }

    /// Every toplevel window GTK has, shown or not.
    private func toplevels() -> [Widget] {
        guard let list = gtk_window_get_toplevels() else { return [] }
        return (0..<g_list_model_get_n_items(list)).compactMap { index in
            guard let item = g_list_model_get_item(list, index) else { return nil }
            g_object_unref(item)
            return cast(item) as Widget
        }
    }
}

/// How many times something ran.
@MainActor
private final class Counter {
    var count = 0
}
