import CGtk
import GtkBinding

/// The pieces the details' pages are built from: a section's title over its content, a card of
/// rows, each a name and its value, and the lines and buttons between them.
///
/// Each row is one Tab stop: its value, which you can select and copy, and which screen readers
/// name by the row's name, as GTK has the name's label say it; or for a secret, its Show button.
@MainActor
enum DetailsBlocks {
    /// The toast ``toast(_:from:button:isUrgent:onButton:)`` added last, held, and its words.
    private static var lastToast: (words: String, toast: OpaquePointer)?

    /// The words of the toast added last, for the self-check.
    static var lastToastWords: String? { lastToast?.words }

    /// A section: its title, how many it holds, and `end`, such as Copy Headers, beside them, over
    /// `content`, each piece under the one before.
    static func section(_ title: String, count: Int? = nil, end: [Widget] = [], content: [Widget]) -> Widget {
        let section = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        let top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let heading = label(title)
        gtk_widget_add_css_class(heading, "heading")
        gtk_box_append(cast(top), heading)
        if let count {
            let number = label(Format.count(count))
            gtk_widget_add_css_class(number, "dim-label")
            gtk_widget_add_css_class(number, "numeric")
            gtk_box_append(cast(top), number)
            // Said with the title, as "Headers, 12".
            setAccessibleLabel(heading, "\(title), \(Format.count(count))")
            setAccessibleHidden(number, true)
        }
        let room = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_set_hexpand(room, 1)
        gtk_box_append(cast(top), room)
        for widget in end {
            gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
            gtk_box_append(cast(top), widget)
        }
        gtk_box_append(cast(section), top)
        for widget in content {
            gtk_box_append(cast(section), widget)
        }
        return section
    }

    /// A card of `rows`, one under the other.
    static func card(_ rows: [Widget]) -> Widget {
        let card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_add_css_class(card, "card")
        gtk_widget_add_css_class(card, "details-rows")
        for row in rows {
            gtk_box_append(cast(card), row)
        }
        return card
    }

    /// A card of `rows`' names and values.
    static func card(_ rows: [DetailsRow]) -> Widget {
        card(rows.map { row($0.name, value: $0.value, isCode: $0.isCode) })
    }

    /// A row: its name, dim, and its value beside it, which you can select, both wrapping. A value
    /// that `isCode` is in a monospace font, and with `isHeader`, so is its name, as a header's.
    static func row(_ name: String, value: String, isCode: Bool = false, isHeader: Bool = false) -> Widget {
        let shown = label(value)
        gtk_label_set_selectable(cast(shown), 1)
        if isCode {
            gtk_widget_add_css_class(shown, "monospace")
        }
        return row(name, isHeader: isHeader, value: [shown], labelling: shown)
    }

    /// A row of `name`, with `value`'s widgets beside it, the first of which takes the room left,
    /// each on the name's first line. `labelling`, the widget that has the row's Tab stop, takes
    /// the name's words as its own. A grid rather than a box, which gives a long name beside a
    /// one-line value the width of its own one line, out of line with the others, where a grid
    /// wraps it in the 14 characters every name has.
    static func row(_ name: String, isHeader: Bool = false, value: [Widget], labelling: Widget?) -> Widget {
        let row = gtk_grid_new()!
        gtk_grid_set_column_spacing(cast(row), 12)
        gtk_widget_add_css_class(row, "details-row")
        let title = label(name)
        gtk_widget_add_css_class(title, "dim-label")
        gtk_widget_add_css_class(title, "details-name")
        if isHeader {
            gtk_widget_add_css_class(title, "monospace")
        }
        gtk_label_set_width_chars(cast(title), 14)
        gtk_label_set_max_width_chars(cast(title), 14)
        gtk_widget_set_valign(title, GTK_ALIGN_BASELINE_FILL)
        gtk_grid_attach(cast(row), title, 0, 0, 1, 1)
        for (index, widget) in value.enumerated() {
            gtk_widget_set_hexpand(widget, cBool(index == 0))
            gtk_widget_set_valign(widget, GTK_ALIGN_BASELINE_FILL)
            gtk_grid_attach(cast(row), widget, Int32(index + 1), 0, 1, 1)
        }
        if let labelling {
            setAccessibleRelation(labelling, GTK_ACCESSIBLE_RELATION_LABELLED_BY, [title])
        }
        return row
    }

    /// A label for text that wraps, from the leading edge, with no markup.
    static func label(_ text: String) -> Widget {
        let label = gtk_label_new(text)!
        gtk_label_set_xalign(cast(label), 0)
        gtk_label_set_wrap(cast(label), 1)
        gtk_label_set_wrap_mode(cast(label), PANGO_WRAP_WORD_CHAR)
        return label
    }

    /// A dim line, such as "No response yet."
    static func note(_ text: String) -> Widget {
        let note = label(text)
        gtk_widget_add_css_class(note, "dim-label")
        return note
    }

    /// An icon on its own, which screen readers skip, since the words beside it say what it means.
    static func icon(_ name: String) -> Widget {
        let icon = gtk_image_new_from_icon_name(name)!
        gtk_widget_set_valign(icon, GTK_ALIGN_START)
        setAccessibleHidden(icon, true)
        return icon
    }

    /// A flat button with an icon, named `label` for screen readers and its tooltip.
    static func iconButton(_ icon: String, _ label: String, tooltip: String? = nil) -> Widget {
        let button = gtk_button_new_from_icon_name(icon)!
        gtk_widget_add_css_class(button, "flat")
        gtk_widget_set_tooltip_text(button, tooltip ?? label)
        setAccessibleLabel(button, label)
        return button
    }

    /// A flat button with words, such as Show.
    static func textButton(_ label: String) -> Widget {
        let button = gtk_button_new_with_label(label)!
        gtk_widget_add_css_class(button, "flat")
        gtk_widget_set_valign(button, GTK_ALIGN_START)
        return button
    }

    /// A button that copies what `text` gives when you click it, and says so in a toast.
    static func copyButton(_ label: String, _ text: @escaping @MainActor () -> String) -> Widget {
        let button = iconButton("edit-copy-symbolic", label)
        connect(button, "clicked") {
            gdk_clipboard_set_text(gtk_widget_get_clipboard(button), text())
            toast("Copied", from: button)
        }
        return button
    }

    /// Says `words` at the bottom of `widget`'s window, as a toast, such as "Copied": plain text,
    /// not Pango markup, since they may hold a path or a message. Every Reqly window has a toast
    /// overlay around its content, and `widget` is in it, or is it; Settings, an
    /// AdwPreferencesDialog, has its own. libadwaita says a toast to screen readers itself from
    /// 1.7, as the self-check hears, but 1.5 doesn't, so there they hear it from here, as they do
    /// when no toast can show. A toast with the same words as the one before takes its place, so
    /// quick copies show one "Copied", said once, rather than one after another. With `button`,
    /// such as Undo or Show, the toast has a button that runs `onButton`; an urgent one shows at
    /// once, before toasts that wait.
    static func toast(
        _ words: String, from widget: Widget, button: String? = nil, isUrgent: Bool = false,
        onButton: (@MainActor () -> Void)? = nil
    ) {
        let isSettings = g_type_check_instance_is_a(cast(widget), adw_preferences_dialog_get_type()) != 0
        let overlay = isSettings ? nil : gtk_widget_get_ancestor(widget, adw_toast_overlay_get_type())
        if isSettings || overlay != nil, let toast = adw_toast_new(words) {
            adw_toast_set_use_markup(toast, 0)
            if let button {
                adw_toast_set_button_label(toast, button)
                if let onButton {
                    connect(raw(toast), "button-clicked") { onButton() }
                }
            }
            if isUrgent {
                adw_toast_set_priority(toast, ADW_TOAST_PRIORITY_HIGH)
            }
            if let last = lastToast {
                // Gone already, it changes nothing.
                if last.words == words {
                    adw_toast_dismiss(last.toast)
                }
                g_object_unref(raw(last.toast))
            }
            g_object_ref(raw(toast))
            lastToast = (words, toast)
            if isSettings {
                adw_preferences_dialog_add_toast(cast(widget), toast)
            } else {
                adw_toast_overlay_add_toast(cast(overlay), toast)
            }
        }
        if !(isSettings || overlay != nil) || !LibraryVersion.adwaita(atLeast: 7) {
            announce(widget, words)
        }
    }

    /// A page's scroller, which screen readers call by its name. It scrolls up and down, and
    /// sideways only when what the page holds can't be narrower than the pane, such as a body's
    /// modes in the narrowest, so the page never makes the details wider than their pane.
    static func scroller(named name: String) -> Widget {
        let scroller = namedScroller(name)
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        return scroller
    }

    /// Takes every child out of `box`, which lets go of each.
    static func empty(_ box: Widget) {
        while let child = gtk_widget_get_first_child(box) {
            gtk_box_remove(cast(box), child)
        }
    }
}
