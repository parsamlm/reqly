import AppSetup
import CGtk
import CoreInterface
import Foundation
import GtkBinding
import LinuxTrust

extension SelfCheck {
    /// HTTPS decryption's parts: setting it up with the stand-in certificate, the places it's
    /// trusted, the hosts to decrypt, and removing it.
    static let httpsParts: [Part] = [
        Part(name: "https-setup") { try await $0.checkHTTPSSetup() },
        Part(name: "dialog-focus") { try await $0.checkDialogFocus() },
        Part(name: "https-page") { try await $0.checkHTTPSPage() },
        Part(name: "https-whats-left") { try await $0.checkWhatsLeft() },
        Part(name: "https-remove") { try await $0.checkHTTPSRemove() },
    ]

    /// Set Up HTTPS… shows the test run's stand-in in place of the places, makes the certificate,
    /// and Reqly decrypts. Opened again, it's the same dialog, from the start. A second setup
    /// while one is under way doesn't start.
    func checkHTTPSSetup() async throws {
        let https = try await standInHTTPS()
        note("before: \(https.statusName)")
        let setUp = try await openSetUp()
        let places = setUp.placeRows.map { "\(title($0)): \(subtitle($0))" }
        note("places: \(places.joined(separator: " | "))")
        try require(
            setUp.placeRows.count == 1 && title(setUp.placeRows[0]) == "Test Run's Certificate",
            "a test run's Set Up HTTPS shows \(places)")
        note("key: \(subtitle(setUp.keyRow))")

        // libadwaita 1.5 ignores what's done to a dialog that's still opening.
        await settle()
        gtk_widget_activate(setUp.continueButton)
        try await until("HTTPS to be set up") { setUp.isDone }
        let status = setUp.statusRow.map(title) ?? ""
        note("results: \(status). \(setUp.statusRow.map(subtitle) ?? "")")
        try require(status == "Decrypting" && https.statusName == "Decrypting", "after setting up, it says \(status)")
        try require(https.state?.certificate?.isEmpty == false, "the session has no certificate to decrypt with")
        await settle()
        gtk_widget_activate(setUp.continueButton)
        try await until("Set Up HTTPS to close") { !setUp.isShowing }

        let again = try await openSetUp()
        let label = string(gtk_button_get_label(cast(again.continueButton))) ?? ""
        try require(again === setUp, "Set Up HTTPS made its dialog again")
        try require(
            !again.isDone && again.statusRow == nil && label == "Continue"
                && gtk_widget_get_sensitive(again.continueButton) != 0,
            "opened again, it shows \(label), not the start")
        note("opened again: the same dialog, from the start, with \(label)")
        await settle()
        gtk_widget_activate(again.cancelButton)
        try await until("Set Up HTTPS to close") { !again.isShowing }

        // The one asked for here runs before the task's, which finds it under way.
        let other = Task { await https.setUp(trusting: [], cancellation: Cancellation()) }
        let first = await https.setUp(trusting: [], cancellation: Cancellation())
        let second = await other.value
        note("two setups at once: the second says \(second.failure ?? "nothing")")
        try require(first.failure == nil, first.failure ?? "")
        try require(second.failure?.hasPrefix("Reqly is still busy") == true, "the second setup ran too")
    }

    /// The keyboard's focus is in Set Up HTTPS… and in Settings each time they open, however they
    /// closed before, and stays in Set Up while it sets up, then goes to Done; and it's back in
    /// Settings once Set Up, opened from it, closes. libadwaita 1.7 and later don't focus a
    /// dialog Reqly closed itself as it opens again, and GTK gives the focus to nothing when the
    /// button that has it turns insensitive, as Continue does. Escape wouldn't close the dialog.
    /// libadwaita 1.5, as Ubuntu 24.04 and the build image have, focuses a dialog that opens again
    /// by itself, so the steps that open one again check presentKept(_:over:) only where this runs
    /// with libadwaita 1.7 or later, as on Debian 13 and Ubuntu 26.04.
    func checkDialogFocus() async throws {
        let https = try await standInHTTPS()
        // Set Up HTTPS… shows in Settings only until HTTPS is set up.
        if https.hasCertificate {
            let left = await https.remove()
            try require(left == nil && !https.hasCertificate, left ?? "the certificate stayed")
        }
        let page = try await openHTTPSPage()
        let settings = try present(window.settings?.dialog, "Settings didn't open")
        await settle()
        try requireFocus(in: settings, "Settings, open")
        try require(gtk_widget_get_visible(page.setUpButton) != 0, "Settings › HTTPS has no Set Up HTTPS…")
        gtk_widget_grab_focus(page.setUpButton)
        gtk_widget_activate(page.setUpButton)
        let setUp = try await waitForSetUp()
        await settle()
        try requireFocus(in: setUp.dialog, "Set Up HTTPS, over Settings")
        // Continue from the keyboard, then Done.
        gtk_widget_grab_focus(setUp.continueButton)
        gtk_widget_activate(setUp.continueButton)
        // A button pressed from the keyboard says it's clicked a moment later.
        try await until("Continue to start") { gtk_widget_get_sensitive(setUp.continueButton) == 0 || setUp.isDone }
        if !setUp.isDone {
            try requireFocus(in: setUp.dialog, "Set Up HTTPS, while it sets up")
        }
        try await until("HTTPS to be set up") { setUp.isDone }
        await settle()
        let done = gtk_root_get_focus(cast(window.window))
        note("Set Up HTTPS, once set up: the focus is on \(focusName(done))")
        try require(done == setUp.continueButton, "once set up, the focus is on \(focusName(done)), not Done")
        gtk_widget_activate(setUp.continueButton)
        try await until("Set Up HTTPS to close") { !setUp.isShowing && gtk_widget_get_parent(setUp.dialog) == nil }
        await settle()
        try requireFocus(in: settings, "Settings, once Set Up HTTPS has closed")

        // Closed as the window's close closes it, then opened again.
        adw_dialog_close(cast(settings))
        try await until("Settings to close") {
            window.settings?.isShowing == false && gtk_widget_get_parent(settings) == nil
        }
        activate("settings")
        try await until("Settings to open again") { window.settings?.isShowing == true }
        await settle()
        try requireFocus(in: settings, "Settings, opened again after it was closed")
        try await closeSettings()

        // From the menu, after Done, then after Cancel.
        for after in ["Done", "Cancel"] {
            let again = try await openSetUp()
            await settle()
            try requireFocus(in: again.dialog, "Set Up HTTPS, opened again after \(after)")
            gtk_widget_activate(again.cancelButton)
            try await until("Set Up HTTPS to close") { !again.isShowing && gtk_widget_get_parent(again.dialog) == nil }
            await settle()
        }
    }

    /// Fails unless the keyboard's focus is on a widget in `dialog`, and notes where it is.
    private func requireFocus(in dialog: Widget, _ when: String) throws {
        let focus = gtk_root_get_focus(cast(window.window))
        note("\(when): the focus is on \(focusName(focus))")
        try require(hasFocus(inside: dialog), "\(when), the focus is on \(focusName(focus))")
    }

    /// A widget with the focus, by its type, and a button by its label or tooltip, and whether it
    /// shows.
    private func focusName(_ focus: Widget?) -> String {
        guard let focus else { return "nothing" }
        let label =
            typeName(raw(focus)) == "GtkButton"
            ? string(gtk_button_get_label(cast(focus))) ?? string(gtk_widget_get_tooltip_text(focus)) : nil
        return typeName(raw(focus)) + (label.map { " '\($0)'" } ?? "")
            + (gtk_widget_get_mapped(focus) == 0 ? ", which doesn't show" : "")
    }

    /// Opens Set Up HTTPS…, once it has read the places.
    private func openSetUp() async throws -> SetUpDialog {
        activate("set-up-https")
        return try await waitForSetUp()
    }

    /// Set Up HTTPS…, once it shows and has read the places.
    private func waitForSetUp() async throws -> SetUpDialog {
        let window = window
        try await until("Set Up HTTPS to open") {
            window.setUp.map { $0.isShowing && gtk_widget_get_mapped($0.dialog) != 0 } ?? false
        }
        let setUp = try present(window.setUp, "Set Up HTTPS didn't open")
        try await until("the places") { setUp.isReady }
        return setUp
    }

    /// Settings › HTTPS shows the status, where the key is, and the fixes for what no place reaches,
    /// each of which copies; a host joins the list, one that isn't a host gets the session's
    /// message, and every host can be decrypted, which your settings keep.
    func checkHTTPSPage() async throws {
        let https = try await standInHTTPS()
        try await setUpIfNeeded(https)
        let page = try await openHTTPSPage()
        let status = subtitle(page.statusRow)
        note("status: \(status)")
        try require(status.hasPrefix("Decrypting."), "Settings › HTTPS says \(status)")
        let key = subtitle(page.keyRow)
        note("key: \(key)")
        try require(
            gtk_widget_get_visible(page.keyRow) != 0 && key.hasPrefix("In this test run's file: "),
            "the key's line says \(key)")
        note("places: \(page.placeRows.map { "\(title($0.row)): \(subtitle($0.row))" }.joined(separator: " | "))")

        try require(page.uncovered.count == 5, "Not Covered lists \(page.uncovered.count) apps")
        for (app, copy) in page.uncovered {
            gtk_widget_activate(copy)
            try await until("the fix for \(app.name) on the clipboard") { clipboardText() == app.fix }
        }
        note("not covered: \(page.uncovered.map(\.app.name).joined(separator: ", ")), each fix copied")
        note("such as: \(page.uncovered[0].app.fix)")

        let session = try await session()
        gtk_editable_set_text(cast(page.newHostRow), "api.weatherly.dev")
        enter(page.newHostRow)
        try await until("the host on the list") {
            https.state?.hosts.entries.contains { $0.pattern.rawValue == "api.weatherly.dev" } == true
        }
        let saved = AppSettings.load(from: model.folders.settingsFile).decryptedHosts
        try require(
            saved.entries.contains { $0.pattern.rawValue == "api.weatherly.dev" && $0.isOn },
            "your settings don't keep the host")
        try require(try await session.decryptsHost("api.weatherly.dev"), "the session doesn't decrypt the host")

        var expected = ""
        do {
            _ = try await session.addDecryptedHost("not a host")
        } catch {
            expected = error.message
        }
        gtk_editable_set_text(cast(page.newHostRow), "not a host")
        enter(page.newHostRow)
        try await until("the session's message") { gtk_widget_get_visible(page.addProblem) != 0 }
        let said = string(gtk_label_get_text(cast(page.addProblem))) ?? ""
        note("not a host: \(said)")
        try require(said == expected && !said.isEmpty, "it says \(said), not the session's \(expected)")

        adw_switch_row_set_active(cast(page.everyHostRow), 1)
        try await until("every host to be decrypted") { https.state?.hosts.includesEveryHost == true }
        try require(
            AppSettings.load(from: model.folders.settingsFile).decryptedHosts.includesEveryHost,
            "your settings don't keep Decrypt All Hosts")
        try require(try await session.decryptsHost("example.com"), "the session doesn't decrypt every host")
        note("decrypt all hosts: on, and kept in your settings")
        try await closeSettings()
    }

    /// Remove Certificate… asks first, then the certificate goes, and Settings › HTTPS says HTTPS
    /// isn't set up.
    func checkHTTPSRemove() async throws {
        let https = try await standInHTTPS()
        try await setUpIfNeeded(https)
        let page = try await openHTTPSPage()
        try require(gtk_widget_get_visible(page.removeButton) != 0, "there's no Remove Certificate…")
        await settle()
        // From the keyboard, as the removal takes the focus from the button.
        gtk_widget_grab_focus(page.removeButton)
        gtk_widget_activate(page.removeButton)
        try await until("Remove Certificate… to ask") {
            page.removeConfirmation.map { gtk_widget_get_mapped($0) != 0 } ?? false
        }
        guard let question = page.removeConfirmation else { throw Failure("Remove Certificate… didn't ask") }
        let heading = string(adw_alert_dialog_get_heading(cast(question))) ?? ""
        note("asks: \(heading) \(string(adw_alert_dialog_get_body(cast(question))) ?? "")")
        await settle()
        guard let remove = button(labelled: "Remove Certificate", in: question) else {
            throw Failure("the question has no Remove Certificate button")
        }
        gtk_widget_activate(remove)
        try await until("the certificate to go") { https.state?.status == .notSetUp }
        try await until("Settings › HTTPS to say so") { subtitle(page.statusRow).hasPrefix("Not set up.") }
        note("status: \(subtitle(page.statusRow))")
        try require(gtk_widget_get_visible(page.removeButton) == 0, "Remove Certificate… stays")
        try require(gtk_widget_get_visible(page.keyRow) == 0, "the key's line stays")
        if let standIn = model.options.rootStandIn {
            try require(!FileManager.default.fileExists(atPath: standIn), "the stand-in certificate's file stays")
        }
        let settings = try present(window.settings?.dialog, "Settings has gone")
        try await until("the focus back in Settings", seconds: 2) { hasFocus(inside: settings) }
        note("then the focus is on \(focusName(gtk_root_get_focus(cast(window.window))))")
        try await closeSettings()
    }

    /// What a removal leaves shows whole, at the page's end, below Remove Certificate…, however far
    /// up the page was, with the focus on its copy button, or on Remove Certificate… when there are
    /// no commands. GTK lays the line out in the frame after it shows, so a scroll before then
    /// stopped short. It shows as a frame ends, the furthest from the next layout, as a removal's
    /// spinner can have it. Once the certificate has gone, Chromium's own list may still trust it,
    /// which shows the same way, with the focus on the note itself, since Remove Certificate… has
    /// gone, and Set Up HTTPS…, at the page's top, would be out of sight.
    func checkWhatsLeft() async throws {
        let https = try await standInHTTPS()
        try await setUpIfNeeded(https)
        let page = try await openHTTPSPage()
        let viewport = try present(
            gtk_widget_get_ancestor(page.removeLeft, gtk_viewport_get_type()), "Settings › HTTPS doesn't scroll")
        let adjustment = gtk_scrollable_get_vadjustment(cast(viewport))
        let left =
            "You closed the password dialog, so these still trust Reqly's certificate: your browsers' shared "
            + "certificate database; Firefox's profile; this computer's list of certificates."
        let snap = ChromiumStore(browser: .chromiumSnap, file: URL(filePath: "/home/ana/ServerCertificate"))
        let chromium = try present(
            ChromiumCopies(trusting: [snap]).note(certificate: "Reqly CA 2026-11-01 16:37"), "Chromium has no note")
        for withCommands in [true, false, nil] {
            // The certificate gone, and only Chromium's note left.
            if withCommands == nil {
                _ = await https.remove()
                try require(https.state?.status == .notSetUp, "the certificate stays")
            }
            gtk_adjustment_set_value(adjustment, 0)
            await settle()
            atFrameEnd { page.showLeft(withCommands == nil ? chromium : left, withCommands: withCommands ?? false) }
            try await until("the line to show") { gtk_widget_get_visible(page.removeLeft) != 0 }
            await settle()
            var bounds = graphene_rect_t()
            try require(gtk_widget_compute_bounds(page.removeLeft, viewport, &bounds) != 0, "the line has no place")
            let top = Int(bounds.origin.y.rounded())
            let bottom = Int((bounds.origin.y + bounds.size.height).rounded())
            let visible = Int(gtk_widget_get_height(viewport))
            let focus = gtk_root_get_focus(cast(window.window))
            let which = withCommands.map { $0 ? "with commands" : "without commands" } ?? "Chromium's note, removed"
            note(
                "\(which): the line at \(top) to \(bottom) of \(visible) px shown, scrolled to "
                    + "\(Int(gtk_adjustment_get_value(adjustment))) px, the focus on \(focusName(focus))")
            try require(top >= 0 && bottom <= visible, "the line is at \(top) to \(bottom), outside 0 to \(visible)")
            let expected =
                withCommands.map { $0 ? page.removeCommandsButton : page.removeButton } ?? page.removeNote
            try require(focus == expected, "the focus is on \(focusName(focus)), not \(focusName(expected))")
        }
        try await closeSettings()
    }

    // MARK: - What the parts share

    /// The HTTPS model, once the session has said whether HTTPS is set up. Only a run with a
    /// stand-in certificate goes on, so these parts never touch your browsers, Firefox, the
    /// computer's list or pkexec.
    private func standInHTTPS() async throws -> HTTPSModel {
        _ = try await session()
        let https = model.https
        try require(https.isStandIn, "the run has no stand-in certificate, so the HTTPS parts don't run")
        try await until("HTTPS's state") { https.state != nil || https.problem != nil }
        try require(https.state != nil, https.problem ?? "HTTPS has no state")
        return https
    }

    private func setUpIfNeeded(_ https: HTTPSModel) async throws {
        guard https.state?.status != .trusted else { return }
        let result = await https.setUp(trusting: [], cancellation: Cancellation())
        try require(result.failure == nil && https.state?.status == .trusted, result.failure ?? "HTTPS isn't set up")
    }

    /// Opens Settings at its HTTPS page, once the page has read the places.
    private func openHTTPSPage() async throws -> HTTPSPage {
        let window = window
        activate("settings")
        try await until("Settings to open") {
            window.settings.map { $0.isShowing && gtk_widget_get_mapped($0.dialog) != 0 } ?? false
        }
        guard let settings = window.settings, let page = settings.httpsPage else {
            throw Failure("Settings didn't open")
        }
        adw_preferences_dialog_set_visible_page_name(cast(settings.dialog), "https")
        let visible = adw_preferences_dialog_get_visible_page(cast(settings.dialog)).map { cast($0) as Widget }
        try require(visible == page.page, "Settings shows another page than HTTPS")
        try await until("Settings › HTTPS to show") { gtk_widget_get_mapped(page.page) != 0 && page.isReady }
        return page
    }

    private func closeSettings() async throws {
        let window = window
        // libadwaita 1.5 doesn't close a dialog that's still opening.
        await settle()
        if let dialog = window.settings?.dialog {
            adw_dialog_close(cast(dialog))
        }
        try await until("Settings to close") { window.settings?.isShowing == false }
    }

    /// Presses Enter in an entry row, as you would after typing: its text's "activate" signal,
    /// which Enter's key binding sends, since gtk_widget_activate doesn't reach a GtkText.
    private func enter(_ row: Widget) {
        guard let text = gtk_editable_get_delegate(cast(row)) else { return }
        let type = g_type_from_name(typeName(raw(text)))
        var instance = GValue()
        g_value_init(&instance, type)
        defer { g_value_unset(&instance) }
        g_value_set_object(&instance, raw(text))
        g_signal_emitv(&instance, g_signal_lookup("activate", type), 0, nil)
    }

    /// The button with `label` inside `root`, such as one of a question's answers.
    private func button(labelled label: String, in root: Widget) -> Widget? {
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            if typeName(raw(widget)) == "GtkButton", string(gtk_button_get_label(cast(widget))) == label {
                return widget
            }
            if let found = button(labelled: label, in: widget) {
                return found
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return nil
    }

    /// The text Reqly last put on the clipboard.
    private func clipboardText() -> String? {
        guard let display = gdk_display_get_default(),
            let content = gdk_clipboard_get_content(gdk_display_get_clipboard(display))
        else { return nil }
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        defer { g_value_unset(&value) }
        guard gdk_content_provider_get_value(content, &value, nil) != 0 else { return nil }
        return string(g_value_get_string(&value))
    }

    private func title(_ row: Widget) -> String {
        string(adw_preferences_row_get_title(cast(row))) ?? ""
    }

    private func subtitle(_ row: Widget) -> String {
        string(adw_action_row_get_subtitle(cast(row))) ?? ""
    }
}
