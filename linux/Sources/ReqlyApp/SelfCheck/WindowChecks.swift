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
        Part(name: "symbolic-icons") { try await $0.checkSymbolicIcons() },
        Part(name: "menu-dialogs") { try await $0.checkMenuDialogs() },
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

    /// Settings opens from its action, with General and HTTPS, and closes. Opened again, it's
    /// the same dialog, with the same pages: libadwaita keeps every page a dialog had, so new ones
    /// each time would pile up, each following the model.
    func checkSettings() async throws {
        let window = window
        var opened: [(dialog: Widget, https: HTTPSPage?)] = []
        for _ in 1...2 {
            activate("settings")
            try await until("Settings to open") {
                window.settings.map { $0.isShowing && gtk_widget_get_mapped($0.dialog) != 0 } ?? false
            }
            let settings = try present(window.settings, "Settings didn't open")
            opened.append((settings.dialog, settings.httpsPage))
            // libadwaita 1.5 doesn't close a dialog that's still opening.
            await settle()
            adw_dialog_close(cast(settings.dialog))
            try await until("Settings to close") { window.settings?.isShowing == false }
        }
        let titles = window.settings?.pageTitles ?? []
        note("pages: \(titles.joined(separator: ", "))")
        try require(titles.contains("General") && titles.contains("HTTPS"), "Settings has no General or HTTPS page")
        try require(
            opened[0].dialog == opened[1].dialog && opened[0].https != nil && opened[0].https === opened[1].https,
            "Settings made its dialog or its HTTPS page again")
        note("opened twice: the same dialog and pages")
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

    /// Reqly's own symbolic icons stand in where the icon theme has none, as Debian Cinnamon's
    /// `gnome` theme hasn't: with only hicolor, every one is found, not drawn as a broken image.
    func checkSymbolicIcons() async throws {
        let theme = try present(gtk_icon_theme_get_for_display(gdk_display_get_default()), "there's no icon theme")
        let settings = try present(gtk_settings_get_default(), "there are no GTK settings")
        let before = stringProperty(raw(settings), "gtk-icon-theme-name") ?? ""
        set(raw(settings), "gtk-icon-theme-name", .string("hicolor"))
        defer { gtk_settings_reset_property(settings, "gtk-icon-theme-name") }
        let missing = Icons.symbolic.map(\.name).filter { gtk_icon_theme_has_icon(theme, $0) == 0 }
        note("icon theme: hicolor, instead of \(before.isEmpty ? "the default" : before)")
        note("found: \(Icons.symbolic.map(\.name).filter { !missing.contains($0) }.joined(separator: ", "))")
        try require(missing.isEmpty, "with only hicolor, there's no \(missing.joined(separator: ", "))")
    }

    /// A dialog opened from the main menu's entry, from the keyboard, leaves the window's focus
    /// on a widget that shows once it closes, so its shortcuts and Tab still work: libadwaita 1.5
    /// gave it back to the entry, in the closed menu. The Method column has room for CONNECT.
    func checkMenuDialogs() async throws {
        let window = window
        let menuButton: OpaquePointer = cast(window.menuButton)
        let popover = try present(gtk_menu_button_get_popover(menuButton), "the menu has no popover")
        for entry in ["Settings", "About Reqly", "Settings"] {
            gtk_menu_button_popup(menuButton)
            try await until("the menu to open") { gtk_widget_get_mapped(cast(popover)) != 0 }
            let item = try present(
                descendants(of: cast(popover)).first {
                    typeName(raw($0)) == "GtkModelButton" && stringProperty(raw($0), "text") == entry
                }, "the menu has no \(entry)")
            gtk_widget_grab_focus(item)
            gtk_widget_activate(item)
            let dialog: () -> Widget? = { entry == "Settings" ? window.settings?.dialog : window.about }
            try await until("\(entry) to open") { dialog().map { gtk_widget_get_mapped($0) != 0 } ?? false }
            await settle()
            adw_dialog_close(cast(dialog()))
            try await until("\(entry) to close") {
                entry == "Settings" ? window.settings?.isShowing == false : window.about == nil
            }
            await settle()
            let focus = gtk_root_get_focus(cast(window.window))
            note("after \(entry): the focus is on \(focus.map { typeName(raw($0)) } ?? "nothing")")
            try require(focus.map { gtk_widget_get_mapped($0) != 0 } ?? false, "the focus isn't on a widget that shows")
        }

        let columns = gtk_column_view_get_columns(cast(window.list.view))
        let method: OpaquePointer? = cast(g_list_model_get_item(columns, 1))
        defer { g_object_unref(raw(method)) }
        let width = gtk_column_view_column_get_fixed_width(method)
        let layout = gtk_widget_create_pango_layout(window.list.view, "CONNECT")
        var needed: Int32 = 0
        pango_layout_get_pixel_size(layout, &needed, nil)
        g_object_unref(raw(layout))
        note("Method column: \(width) px, CONNECT \(needed) px")
        try require(width >= needed + 12, "the Method column, \(width) px, cuts CONNECT, \(needed) px")
    }

    /// Every widget under `root`, depth first.
    private func descendants(of root: Widget) -> [Widget] {
        var found: [Widget] = []
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            found.append(widget)
            found += descendants(of: widget)
            child = gtk_widget_get_next_sibling(widget)
        }
        return found
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
