import CGtk
import CoreInterface
import GtkBinding

extension SelfCheck {
    /// The window's own parts, which the features build on.
    static let windowParts: [Part] = [
        Part(name: "window") { try await $0.checkWindow() },
        Part(name: "settings") { try await $0.checkSettings() },
        Part(name: "about") { try await $0.checkAbout() },
        Part(name: "events") { try await $0.checkEvents() },
    ]

    /// The menu's actions, which App.swift registers.
    private static let menuActions = [
        "set-up-https", "open-terminal", "copy-terminal-setup", "settings", "about", "quit",
    ]

    /// The window shows its header bar, with the capture switch and the main menu, whose every
    /// entry has its action, and the status line.
    func checkWindow() async throws {
        let window = window
        try await until("the window to show") { gtk_widget_get_mapped(window.window) != 0 }
        try require(gtk_widget_get_mapped(window.headerBar) != 0, "the header bar doesn't show")
        note("header bar: \(typeName(raw(window.headerBar)))")

        let captureSwitch = window.captureSwitch
        try require(
            typeName(raw(captureSwitch)) == "GtkSwitch", "the capture switch is a \(typeName(raw(captureSwitch)))")
        try require(
            gtk_widget_is_ancestor(captureSwitch, window.headerBar) != 0, "the capture switch isn't in the header bar")
        try require(gtk_widget_get_mapped(captureSwitch) != 0, "the capture switch doesn't show")
        let isOn = gtk_switch_get_active(cast(captureSwitch)) != 0
        note("capture switch: in the header bar, \(isOn ? "on" : "off")")

        try require(
            gtk_widget_is_ancestor(window.menuButton, window.headerBar) != 0, "the main menu isn't in the header bar")
        let entries = menuEntries(window.menu)
        for entry in entries {
            let name = entry.action.hasPrefix("app.") ? String(entry.action.dropFirst(4)) : entry.action
            try require(
                g_action_group_has_action(cast(app.application), name) != 0,
                "the menu's \(entry.label) has no action \(entry.action)")
            try require(
                g_action_group_get_action_enabled(cast(app.application), name) != 0,
                "the menu's \(entry.label) is off")
        }
        let missing = Self.menuActions.filter { action in !entries.contains { $0.action == "app.\(action)" } }
        try require(missing.isEmpty, "the menu has no entry for app.\(missing.joined(separator: ", app."))")
        note("main menu: \(entries.map { "\($0.label) (\($0.action))" }.joined(separator: ", "))")

        let status = string(gtk_label_get_text(cast(window.statusLabel))) ?? ""
        try require(gtk_widget_get_mapped(window.statusLine) != 0, "the status line doesn't show")
        try require(!status.isEmpty, "the status line says nothing")
        note("status line: \(status)")
    }

    /// Settings opens from its action, with General and HTTPS, and closes.
    func checkSettings() async throws {
        let window = window
        activate("settings")
        try await until("Settings to open") {
            window.settings.map { gtk_widget_get_mapped($0.dialog) != 0 } ?? false
        }
        let titles = window.settings?.pageTitles ?? []
        note("pages: \(titles.joined(separator: ", "))")
        try require(titles.contains("General") && titles.contains("HTTPS"), "Settings has no General or HTTPS page")
        // libadwaita 1.5 doesn't close a dialog that's still opening.
        await settle()
        if let dialog = window.settings?.dialog {
            adw_dialog_close(cast(dialog))
        }
        try await until("Settings to close") { window.settings == nil }
    }

    /// About opens from its action, with Reqly's name, version, website and license, and closes.
    func checkAbout() async throws {
        let window = window
        activate("about")
        try await until("About to open") { window.about.map { gtk_widget_get_mapped($0) != 0 } ?? false }
        let about: OpaquePointer = cast(window.about)
        let name = string(adw_about_dialog_get_application_name(about)) ?? ""
        let version = string(adw_about_dialog_get_version(about)) ?? ""
        let website = string(adw_about_dialog_get_website(about)) ?? ""
        note("about: \(name) \(version), \(website)")
        try require(name == "Reqly" && version == App.version, "About says \(name) \(version)")
        try require(website == "https://reqly.net", "About's website is \(website)")
        try require(adw_about_dialog_get_license_type(about) == GTK_LICENSE_MIT_X11, "About's license isn't MIT")
        await settle()
        adw_dialog_close(cast(window.about))
        try await until("About to close") { window.about == nil }
    }

    /// Requests Reqly sends itself reach the list: their rows events arrive on the main thread,
    /// one version after another.
    func checkEvents() async throws {
        let session = try await session()
        let seen = SeenRows()
        model.listen { event in
            guard seen.isListening, case .rows(let version, _, _, _) = event else { return }
            seen.versions.append(version)
            if !MainLoop.isMainThread {
                seen.offMainThread += 1
            }
        }
        defer { seen.isListening = false }
        let before = window.list.total
        // Nothing listens on port 9, so each request fails at once, without leaving the computer.
        // A moment apart, so the session doesn't send them all in one rows event.
        for number in 1...5 {
            _ = try await session.send(RequestDraft(url: "http://127.0.0.1:9/\(number)"))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await until("the requests in the list") { window.list.total >= before + 5 }
        let inOrder = zip(seen.versions, seen.versions.dropFirst()).allSatisfy { $1 == $0 + 1 }
        let versions = seen.versions.map(String.init).joined(separator: ", ")
        note("rows events: versions \(versions), \(seen.offMainThread) off the main thread")
        note("list: \(window.list.total) requests")
        try require(inOrder, "the rows events came out of order")
        try require(seen.offMainThread == 0, "\(seen.offMainThread) rows events came off the main thread")
    }

    /// The label and action of each entry in a menu of sections.
    private func menuEntries(_ menu: OpaquePointer) -> [(label: String, action: String)] {
        func text(_ model: UnsafeMutablePointer<GMenuModel>, _ item: Int32, _ attribute: String) -> String {
            guard let value = g_menu_model_get_item_attribute_value(model, item, attribute, nil) else { return "" }
            defer { g_variant_unref(value) }
            return string(g_variant_get_string(value, nil)) ?? ""
        }
        let sections: UnsafeMutablePointer<GMenuModel> = cast(menu)
        var entries: [(label: String, action: String)] = []
        for index in 0..<g_menu_model_get_n_items(sections) {
            guard let section = g_menu_model_get_item_link(sections, index, "section") else { continue }
            defer { g_object_unref(raw(section)) }
            for item in 0..<g_menu_model_get_n_items(section) {
                entries.append((text(section, item, "label"), text(section, item, "action")))
            }
        }
        return entries
    }
}

/// The rows events the events part saw.
@MainActor
private final class SeenRows {
    var versions: [Int] = []
    var offMainThread = 0
    var isListening = true
}
