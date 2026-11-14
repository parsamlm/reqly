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

    /// A real notification, in a copy of Reqly the frame part starts: see ``probeNotifications()``.
    static let notificationProbeParts: [Part] = [
        Part(name: "notification-probe", seconds: 20) { try await $0.probeNotifications() }
    ]

    /// The shortcuts have their actions; the Rules button and Shift+Ctrl+B turn Breakpoints on and
    /// off, and the button says so; Keyboard Shortcuts opens; the new actions wait behind a dialog;
    /// Shift+Ctrl+D runs Devices, not GTK's Inspector; a file's window has no capture switch or
    /// Rules button, the Request menu's entries in its rows' menu, and Show Live Traffic; Ctrl+W
    /// closes it, but not the live window; the new events reach the app's model. GTK warns of
    /// nothing meanwhile.
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
            ("the new events", { try await self.checkNewEvents() }),
            ("getting your attention", { try await self.checkAttention(window) }),
            ("a window of the live window's", { try await self.checkSecondaryWindow(window) }),
            ("the banners", { try await self.checkBanners(window) }),
            ("the Messages page", { try await self.checkMessagesPage() }),
            ("a closed file window", { try await self.checkClosedWindowGoes() }),
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

    /// The events Step 5 adds reach the app's model, made up here: a device that waits, until the
    /// devices read again say it doesn't; a request resumed that the model didn't hold; and how far
    /// a file window's export got, which its session keeps, though its window listens later.
    private func checkNewEvents() async throws {
        let devices = try present(model.devices, "the live session has no devices")
        model.handle(.deviceWaiting(id: "made-up", address: "192.0.2.1", waiting: 1))
        try require(
            model.waitingDevice == AppModel.WaitingDevice(id: "made-up", address: "192.0.2.1", waiting: 1),
            "the waiting device is \(String(describing: model.waitingDevice))")
        var answered = devices
        answered.waiting = []
        model.devicesChanged(answered)
        try require(model.waitingDevice == nil, "the device still waits once the devices say none does")
        model.handle(.resumed(id: ExchangeID(rawValue: 999_999)))
        try require(model.paused.isEmpty, "\(model.paused.count) requests are held")
        let file = SessionModel(app: model, file: try Self.macSession())
        var heard: [Int] = []
        file.listen { event in
            if case .exportProgress(let done, _) = event {
                heard.append(done)
            }
        }
        file.receive(.exportProgress(done: 25, total: 40))
        try require(
            file.exportProgress?.done == 25 && heard.isEmpty, "the export's progress didn't wait for its window")
        file.startEvents()
        try require(heard == [25], "once its window listened, it heard \(heard)")
        note("a device waited, then didn't; an unknown request resumed; an export's progress waited for its window")
    }

    /// Getting your attention, as a breakpoint holds a request: with no Reqly window active, a
    /// notification, which a test run writes to its log, as GLib warns of a real one with no
    /// notification server, as a copy of Reqly finds; with the live window active, nothing more, as
    /// it shows the request itself; with a file's window active, a toast there, with Show.
    private func checkAttention(_ window: MainWindow) async throws {
        let probe = try await runInCopy(["notification-probe"], options: [], seconds: 45)
        for line in probe where !line.hasSuffix("parts passed") {
            note("in a copy: \(line.trimmingCharacters(in: .whitespaces))")
        }
        let attention = Attention(
            .paused(ExchangeID(rawValue: 999_998), breakpoint: "API", message: "GET http://127.0.0.1/ok"))
        defer { app.notified.removeAll { $0 == attention } }
        let (way, lines) = try await standardError { app.getAttention(attention, activeWindow: nil) }
        try require(way == .notification, "with no Reqly window active, the way was \(way)")
        let logged = "Reqly: notification: \(attention.title). \(attention.body)"
        try require(lines.contains(logged), "with no Reqly window active, Reqly wrote \(lines), not “\(logged)”")
        try require(app.notified.contains(attention), "the notification isn't kept to go once it's answered")
        let live = app.getAttention(attention, activeWindow: window.window)
        try require(live == .nothing, "with the live window active, the way was \(live)")
        app.open([try Self.macSession()])
        try await until("Mac 1.0.reqly's window") { app.fileWindows.first?.list.total ?? 0 > 0 }
        let file = try present(app.fileWindows.first, "there's no file window")
        let inFile = app.getAttention(attention, activeWindow: file.window)
        try require(inFile == .toast, "with a file's window active, the way was \(inFile)")
        try require(
            DetailsBlocks.lastToastWords == attention.title,
            "the toast says \(DetailsBlocks.lastToastWords ?? "nothing"), not \(attention.title)")
        note("attention: no window active, the log's “\(logged)”; the live window, nothing; a file's, a toast")
        await settle()
        app.closeWindow(file)
        try await until("the file's window to close") { app.fileWindows.isEmpty }
        await settle()
    }

    /// A window that belongs to the live window, as Rules, Devices and composers do: over it, found
    /// by its type, closed by Ctrl+W, but not while a dialog shows over it, and closed as the live
    /// window hides.
    private func checkSecondaryWindow(_ window: MainWindow) async throws {
        func open() async throws -> FrameTestWindow {
            let made = FrameTestWindow(app: app)
            app.addSecondary(made)
            gtk_window_present(cast(made.window))
            try await until("the window to show") { gtk_widget_get_mapped(made.window) != 0 }
            await settle(made.window)
            return made
        }
        let first = try await open()
        try require(secondaries(FrameTestWindow.self).count == 1, "the live window's windows don't have it")
        try require(
            gtk_window_get_transient_for(cast(first.window)) == window.window, "the window isn't over the live window")
        let dialog = adw_alert_dialog_new("A Question", nil)!
        adw_alert_dialog_add_response(cast(dialog), "close", "Close")
        adw_dialog_present(cast(dialog), first.window)
        await settle(first.window)
        try FakeInput.press("Control_L", "w", in: first.window)
        await settle(first.window)
        try require(secondaries(FrameTestWindow.self).count == 1, "Ctrl+W closed the window behind its dialog")
        adw_dialog_close(cast(dialog))
        await settle(first.window)
        try FakeInput.press("Control_L", "w", in: first.window)
        try await until("Ctrl+W to close the window") { self.secondaries(FrameTestWindow.self).isEmpty }
        note("a window of the live window's: over it, Ctrl+W waits behind its dialog, then closes it")
        // A file's window shows meanwhile, so hiding the live window doesn't quit.
        app.open([try Self.macSession()])
        try await until("Mac 1.0.reqly's window") { app.fileWindows.first?.list.total ?? 0 > 0 }
        let file = try present(app.fileWindows.first, "there's no file window")
        _ = try await open()
        app.closeWindow(window)
        try await until("the live window to hide, and its window with it") {
            !window.isShowing && self.secondaries(FrameTestWindow.self).isEmpty
        }
        try require(!app.isQuitting, "hiding the live window quit Reqly")
        app.presentLive()
        try await until("the live window to show again") { window.isShowing }
        app.closeWindow(file)
        try await until("the file's window to close") { app.fileWindows.isEmpty }
        await settle()
        note("hiding the live window closes its windows")
    }

    /// The live window's banners say their words to screen readers once, as they show, and again
    /// only once they change, or show again.
    private func checkBanners(_ window: MainWindow) async throws {
        let banner = window.pausedBanner
        let heard = try await AccessibilityTree.events(["object:announcement"], seconds: 4) {
            // The reader takes a moment to start listening.
            try? await Task.sleep(for: .milliseconds(1500))
            banner.show("Request paused by breakpoint “API”", button: "Show")
            banner.show("Request paused by breakpoint “API”", button: "Show")
            banner.show("Request paused by breakpoint “Forecast”", button: "Show")
            banner.hide()
            banner.show("Request paused by breakpoint “Forecast”")
            try? await Task.sleep(for: .milliseconds(1000))
        }
        banner.hide()
        let said = heard.compactMap(\.detail)
        let expected = [
            "Request paused by breakpoint “API”", "Request paused by breakpoint “Forecast”",
            "Request paused by breakpoint “Forecast”",
        ]
        try require(said == expected, "the banner was heard saying \(said)")
        note("a banner: heard once as it shows, again as its words change, and as it shows again")
        await settle()
    }

    /// The details' Messages page, in Mac 1.0.reqly's window: its tab shows for the WebSocket only,
    /// Ctrl+6 chooses it, and for another request Overview shows, while Messages stays chosen.
    private func checkMessagesPage() async throws {
        app.open([try Self.macSession()])
        try await until("Mac 1.0.reqly's window") { app.fileWindows.first?.list.total ?? 0 > 0 }
        let file = try present(app.fileWindows.first, "there's no file window")
        defer {
            app.closeWindow(file)
        }
        let session = try present(file.model.session, "the file's session isn't open")
        let summaries = await session.rows(await session.rowIDs().ids)
        let webSocket = try present(summaries.first { $0.isWebSocket }, "Mac 1.0.reqly has no WebSocket")
        let other = try present(summaries.first { !$0.isWebSocket }, "Mac 1.0.reqly has only a WebSocket")
        let details = file.details
        file.list.select(id: webSocket.id)
        try await until("the WebSocket's details") { details.summary?.id == webSocket.id }
        try require(details.has(.messages), "the WebSocket has no Messages page")
        try FakeInput.press("Control_L", "6", in: file.window)
        try await until("Ctrl+6 to show Messages") {
            string(adw_view_stack_get_visible_child_name(details.stack)) == "messages"
        }
        file.list.select(id: other.id)
        try await until("the other request's details") { details.summary?.id == other.id }
        let shown = string(adw_view_stack_get_visible_child_name(details.stack)) ?? ""
        try require(
            !details.has(.messages) && shown == "overview" && details.page == .messages,
            "for a request with no messages, \(shown) shows, with \(details.page.title) chosen")
        file.list.select(id: webSocket.id)
        try await until("Messages again, for the WebSocket") {
            details.summary?.id == webSocket.id
                && string(adw_view_stack_get_visible_child_name(details.stack)) == "messages"
        }
        details.show(page: .overview)
        note(
            "Messages: a tab for \(webSocket.path) only, Ctrl+6 chooses it; for \(other.path), Overview shows, "
                + "Messages still chosen")
        await settle()
    }

    /// A file's window, once closed, goes, with its list, its details and the rest: nothing keeps it.
    private func checkClosedWindowGoes() async throws {
        let closed = WeakWindow()
        app.open([try Self.macSession()])
        try await until("Mac 1.0.reqly's window") { app.fileWindows.first?.list.total ?? 0 > 0 }
        closed.window = app.fileWindows.first
        await settle()
        if let window = closed.window {
            app.closeWindow(window)
        }
        try await until("the closed window to go", seconds: 10) { closed.window == nil }
        note("a file's window, closed, goes")
    }

    /// A real GNotification, sent as a release sends one, with no notification server, as in the
    /// self-check's container, and what GLib said about it, if anything: run in a copy of Reqly,
    /// whose log keeps what GLib says away from the self-check's own output. Run by name on a
    /// desktop, it shows one there.
    func probeNotifications() async throws {
        let (_, lines) = try await standardError {
            let notification = g_notification_new("Reqly's self-check")!
            g_application_send_notification(cast(app.application), "self-check", notification)
            g_object_unref(raw(notification))
            // Long enough for the notification server's answer, or GLib's word that there's none.
            // The notification stays, so on a desktop it can be seen in its list too.
            try? await Task.sleep(for: .milliseconds(2000))
        }
        // What GLib said, without its level and time, so the report's lines don't read as a
        // warning of the self-check's own.
        let glib = lines.filter { $0.contains("GLib") }.map { line in
            line.range(of: #"\*\*: [0-9:.]+: "#, options: .regularExpression).map { String(line[$0.upperBound...]) }
                ?? line
        }
        note(
            "a GNotification with no notification server: GLib "
                + (glib.isEmpty ? "said nothing" : "warned: " + glib.joined(separator: " | ")))
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

/// A window, held weakly, to see it go.
@MainActor
private final class WeakWindow {
    weak var window: MainWindow?
}

/// A window the frame part makes, as Rules, Devices or a composer is: an AdwApplicationWindow,
/// in a toast overlay, that belongs to the live window.
@MainActor
private final class FrameTestWindow: SecondaryWindow {
    let window: Widget

    init(app: App) {
        window = adw_application_window_new(cast(app.application))
        gtk_window_set_title(cast(window), "A Window of the Live Window's")
        gtk_window_set_default_size(cast(window), 480, 320)
        let overlay = adw_toast_overlay_new()!
        adw_toast_overlay_set_child(cast(overlay), adw_status_page_new())
        adw_application_window_set_content(cast(window), overlay)
    }
}
