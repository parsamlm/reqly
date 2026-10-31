import CGtk
import Foundation
import GtkBinding
import LinuxTrust

/// The few pieces Set Up HTTPS and Settings › HTTPS build their rows from.
@MainActor
enum HTTPSWidgets {
    /// An AdwActionRow whose title and subtitle are plain text, not Pango markup, since they hold
    /// paths, commands and messages.
    static func row(_ title: String, _ subtitle: String? = nil) -> Widget {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(cast(row), 0)
        adw_preferences_row_set_title(cast(row), title)
        if let subtitle {
            adw_action_row_set_subtitle(cast(row), subtitle)
        }
        return row
    }

    /// A dim label at the end of a row, such as a place's status.
    static func suffixLabel() -> Widget {
        let label = gtk_label_new(nil)!
        gtk_widget_add_css_class(label, "dim-label")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        return label
    }

    /// A button at the end of a row.
    static func suffixButton(_ label: String) -> Widget {
        let button = gtk_button_new_with_label(label)!
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        return button
    }

    /// A flat button that copies `text`, as it is when you click, then runs `copied`, such as to
    /// say so. `label` is what screen readers say, such as "Copy the commands".
    static func copyButton(
        _ text: @escaping @autoclosure @MainActor () -> String, label: String,
        copied: @escaping @MainActor () -> Void
    ) -> Widget {
        let button = gtk_button_new_from_icon_name("edit-copy-symbolic")!
        gtk_widget_add_css_class(button, "flat")
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(button, "Copy")
        setAccessibleLabel(button, label)
        connect(button, "clicked") {
            gdk_clipboard_set_text(gtk_widget_get_clipboard(button), text())
            copied()
        }
        return button
    }

    /// A spinner: libadwaita's from 1.6, GTK's before.
    static func spinner() -> Widget {
        typealias New = @convention(c) () -> Widget?
        if LibraryVersion.adwaita(atLeast: 6), let new = Newer.lookup("adw_spinner_new", as: New.self),
            let spinner = new()
        {
            return spinner
        }
        let spinner = gtk_spinner_new()!
        gtk_spinner_start(cast(spinner))
        return spinner
    }

    /// A spinner and what Reqly waits for, hidden until ``show(_:_:)`` shows it.
    static func progress() -> (box: Widget, label: Widget) {
        let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let label = gtk_label_new(nil)!
        gtk_label_set_wrap(cast(label), 1)
        gtk_label_set_xalign(cast(label), 0)
        gtk_widget_add_css_class(label, "dim-label")
        gtk_box_append(cast(box), spinner())
        gtk_box_append(cast(box), label)
        gtk_widget_set_visible(box, 0)
        return (box, label)
    }

    /// Shows `progress` saying `text`, or hides it when `text` is nil.
    static func show(_ progress: (box: Widget, label: Widget), _ text: String?) {
        gtk_label_set_text(cast(progress.label), text ?? "")
        gtk_widget_set_visible(progress.box, cBool(text != nil))
    }

    /// A label that wraps, for a message below a list, hidden while it says nothing.
    static func message(_ cssClass: String) -> Widget {
        let label = gtk_label_new(nil)!
        gtk_label_set_wrap(cast(label), 1)
        gtk_label_set_xalign(cast(label), 0)
        gtk_label_set_selectable(cast(label), 1)
        gtk_widget_add_css_class(label, cssClass)
        gtk_widget_set_visible(label, 0)
        return label
    }

    /// Shows `text` in a message label, or hides it when `text` is nil.
    static func say(_ label: Widget, _ text: String?) {
        gtk_label_set_text(cast(label), text ?? "")
        gtk_widget_set_visible(label, cBool(text != nil))
    }

    /// What a place's row says under its name: the place's own sentence, for the browsers'
    /// databases which folders they are, and the commands that do it `byHand`, if there are any.
    static func detail(of place: TrustPlace, byHand: String? = nil) -> String {
        if let byHand {
            return place.detail + " To do it yourself, run these in a terminal:\n" + byHand
        }
        guard place.kind == .browsers, !place.locations.isEmpty, place.status != .notFound else {
            return place.detail
        }
        if case .unavailable = place.status {
            return place.detail
        }
        return place.detail + "\n" + place.locations.map(shortPath).joined(separator: ", ")
    }

    /// A path with your home folder as ~, as rows show it.
    static func shortPath(_ url: URL) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let path = url.path
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
