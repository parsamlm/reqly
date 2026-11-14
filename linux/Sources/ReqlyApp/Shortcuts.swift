import CGtk
import GtkBinding

/// Reqly's keyboard shortcuts, in sections, as Keyboard Shortcuts lists them, each with its keys
/// as GTK writes them. A range of keys, such as the details' pages', is a key each, and each item
/// has one key: GTK 4.14's shortcuts window warns of the label between two.
enum ShortcutList {
    struct Item: Equatable, Sendable {
        var title: String
        var keys: String
    }

    struct Section: Equatable, Sendable {
        var title: String
        var items: [Item]
    }

    /// The sections, in order, in pages as GTK's shortcuts window lays them out: in columns of at
    /// most `lines`, a section's title and its items, a section staying whole in its column, and
    /// two columns a page.
    static func pages(lines: Int) -> [[Section]] {
        var pages: [[Section]] = []
        var columns = 0
        var used = 0
        for section in sections {
            let needs = section.items.count + 1
            if pages.isEmpty || used + needs > lines {
                columns += 1
                used = 0
                if pages.isEmpty || columns > 2 {
                    pages.append([])
                    columns = 1
                }
            }
            pages[pages.count - 1].append(section)
            used += needs
        }
        return pages
    }

    static let sections: [Section] = [
        Section(
            title: "General",
            items: [
                Item(title: "Main Menu", keys: "F10"), Item(title: "Keyboard Shortcuts", keys: "<Control>question"),
                Item(title: "Settings", keys: "<Control>comma"), Item(title: "Close Window", keys: "<Control>w"),
                Item(title: "Quit", keys: "<Control>q"),
            ]),
        Section(
            title: "Sessions",
            items: [
                Item(title: "New Request", keys: "<Control>n"), Item(title: "Open", keys: "<Control>o"),
                Item(title: "Save Session", keys: "<Control>s"),
                Item(title: "Export as HAR", keys: "<Shift><Control>e"),
            ]),
        Section(
            title: "Traffic",
            items: [
                Item(title: "Start or Stop Capturing", keys: "<Control>r"), Item(title: "Search", keys: "<Control>f"),
                Item(title: "Clear Traffic", keys: "<Control>k"),
                Item(title: "Show or Hide the Sidebar", keys: "F9"),
                Item(title: "Close the Search, or Go Back", keys: "Escape"), Item(title: "Back", keys: "<Alt>Left"),
                Item(title: "Request's Menu", keys: "<Shift>F10"),
            ]),
        Section(
            title: "Requests",
            items: [
                Item(title: "Copy URL", keys: "<Shift><Control>c"),
                Item(title: "Copy as cURL", keys: "<Control><Alt>c"),
            ] + DetailsPane.Page.allCases.enumerated().map { Item(title: $1.title, keys: "<Control>\($0 + 1)") }),
        Section(
            title: "Rules and Devices",
            items: [
                Item(title: "Breakpoints", keys: "<Shift><Control>b"),
                Item(title: "Slow Network", keys: "<Shift><Control>t"),
                Item(title: "Continue All Paused Requests", keys: "<Control><Alt>Return"),
                Item(title: "Show Rules", keys: "<Control><Alt>r"), Item(title: "Devices", keys: "<Shift><Control>d"),
            ]),
    ]
}

/// Keyboard Shortcuts, Ctrl+?: libadwaita's shortcuts dialog from 1.8, over the window in front,
/// and before that, GTK's shortcuts window, which GTK 4.18 deprecates but still has, transient
/// for it. Made once and kept, and shown again.
@MainActor
enum ShortcutsDialog {
    /// The dialog or the window, once it has been made.
    private(set) static var kept: Widget?

    /// Whether it's libadwaita's dialog, rather than GTK's window.
    private(set) static var isDialog = false

    /// Shows it over `window`.
    static func present(over window: Widget) {
        if let kept {
            show(kept, over: window)
            return
        }
        let made = dialog() ?? shortcutsWindow()
        g_object_ref_sink(raw(made))
        kept = made
        show(made, over: window)
    }

    /// Whether it shows.
    static var isShowing: Bool {
        kept.map { gtk_widget_get_mapped($0) != 0 } ?? false
    }

    private static func show(_ shortcuts: Widget, over window: Widget) {
        if isDialog {
            adw_dialog_present(cast(shortcuts), window)
        } else {
            gtk_window_set_transient_for(cast(shortcuts), cast(window))
            gtk_window_present(cast(shortcuts))
        }
    }

    /// libadwaita's shortcuts dialog, from 1.8, through its functions, which libadwaita 1.5's
    /// headers don't have.
    private static func dialog() -> Widget? {
        typealias NewDialog = @convention(c) () -> Widget?
        typealias NewSection = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
        typealias NewItem = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
        typealias Add = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        guard LibraryVersion.adwaita(atLeast: 8),
            let newDialog = Newer.lookup("adw_shortcuts_dialog_new", as: NewDialog.self),
            let newSection = Newer.lookup("adw_shortcuts_section_new", as: NewSection.self),
            let newItem = Newer.lookup("adw_shortcuts_item_new", as: NewItem.self),
            let addSection = Newer.lookup("adw_shortcuts_dialog_add", as: Add.self),
            let addItem = Newer.lookup("adw_shortcuts_section_add", as: Add.self),
            let dialog = newDialog()
        else { return nil }
        for section in ShortcutList.sections {
            let made = newSection(section.title)
            for item in section.items {
                // The section keeps the item, and the dialog the section, which live as long as
                // the dialog does, which is kept.
                addItem(made, newItem(item.title, item.keys))
            }
            addSection(raw(dialog), made)
        }
        isDialog = true
        return dialog
    }

    /// GTK's shortcuts window, with a group for each section, which hides as it closes. Its
    /// sections fill a page each, of two columns of 15 lines at most, the window's own: a section
    /// with more would turn pages with buttons that GTK 4.14 warns of as they're measured.
    private static func shortcutsWindow() -> Widget {
        let window: Widget = cast(g_object_new_with_properties(gtk_shortcuts_window_get_type(), 0, nil, nil))
        set(raw(window), "hide-on-close", .bool(true))
        set(raw(window), "modal", .bool(true))
        for (number, page) in ShortcutList.pages(lines: 15).enumerated() {
            let section: Widget = cast(g_object_new_with_properties(gtk_shortcuts_section_get_type(), 0, nil, nil))
            set(raw(section), "section-name", .string("shortcuts-\(number + 1)"))
            set(raw(section), "title", .string(page.map(\.title).joined(separator: ", ")))
            for list in page {
                let group: Widget = cast(g_object_new_with_properties(gtk_shortcuts_group_get_type(), 0, nil, nil))
                set(raw(group), "title", .string(list.title))
                for item in list.items {
                    let shortcut: Widget = cast(
                        g_object_new_with_properties(gtk_shortcuts_shortcut_get_type(), 0, nil, nil))
                    set(raw(shortcut), "title", .string(item.title))
                    set(raw(shortcut), "accelerator", .string(item.keys))
                    gtk_shortcuts_group_add_shortcut(cast(group), cast(shortcut))
                }
                gtk_shortcuts_section_add_group(cast(section), cast(group))
            }
            gtk_shortcuts_window_add_section(cast(window), cast(section))
        }
        isDialog = false
        return window
    }
}

extension MainWindow {
    /// Keyboard Shortcuts, over this window.
    func showShortcuts() {
        guard !ShortcutsDialog.isShowing else { return }
        ShortcutsDialog.present(over: window)
    }
}
