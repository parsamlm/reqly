import CGtk
import GtkBinding
import ReqlyModel

/// The menu on a row, as the Mac's row menu has it: Pin or Unpin Request; Color, with None and
/// the seven colors, the row's own checked; Add or Edit Comment…; and for HTTPS, Decrypt or Stop
/// Decrypting its host, while the session can decrypt. It's for the row it opened on, which may
/// not be the selected one: a click with the right button, or Shift+F10 or the Menu key on the
/// row with the keyboard's focus. Its entries are the `row` actions on the list's view.
@MainActor
final class RowMenu {
    let popover: Widget
    /// The entries, in two sections, which change as the menu opens, for its row.
    let menu: OpaquePointer
    private let marks: OpaquePointer
    private let decrypting: OpaquePointer
    /// `row.pin`, `row.color` with the color's name or `none`, `row.comment` and `row.decrypt`.
    let actions: OpaquePointer
    /// The row it's open on, or was last.
    private(set) var target: ExchangeSummary?
    var onPin: ((ExchangeSummary) -> Void)?
    var onColor: ((ExchangeSummary, MarkColor?) -> Void)?
    var onComment: ((ExchangeSummary) -> Void)?
    /// Decrypts a host, or stops, as its entry says.
    var onDecrypt: ((_ host: String, _ isOn: Bool) -> Void)?
    /// Whether Reqly decrypts a host, or `nil` while it can't decrypt at all, as for a saved
    /// session.
    var decrypts: ((String) -> Bool?)?
    private let color: OpaquePointer

    /// A menu that opens on `view`'s rows.
    init(on view: Widget) {
        menu = g_menu_new()
        marks = g_menu_new()
        decrypting = g_menu_new()
        g_menu_append(marks, "Pin Request", "row.pin")
        let colors = g_menu_new()!
        let none = g_menu_new()!
        Self.append(none, "None", color: "none")
        g_menu_append_section(colors, nil, cast(none))
        g_object_unref(raw(none))
        let named = g_menu_new()!
        for mark in MarkColor.allCases {
            Self.append(named, mark.title, color: mark.rawValue)
        }
        g_menu_append_section(colors, nil, cast(named))
        g_object_unref(raw(named))
        g_menu_append_submenu(marks, "Color", cast(colors))
        g_object_unref(raw(colors))
        g_menu_append(marks, "Add Comment…", "row.comment")
        g_menu_append_section(menu, nil, cast(marks))
        g_menu_append_section(menu, nil, cast(decrypting))
        popover = gtk_popover_menu_new_from_model(cast(menu))
        gtk_popover_set_has_arrow(cast(popover), 0)
        gtk_widget_set_halign(popover, GTK_ALIGN_START)
        gtk_widget_set_parent(popover, view)
        // The view doesn't know of it, so it goes with the view.
        let popover = popover
        connect(raw(view), "destroy") { gtk_widget_unparent(popover) }

        actions = cast(g_simple_action_group_new())
        let pin = g_simple_action_new("pin", nil)!
        let comment = g_simple_action_new("comment", nil)!
        let decrypt = g_simple_action_new("decrypt", nil)!
        let type = g_variant_type_new("s")
        color = g_simple_action_new_stateful("color", type, g_variant_new_string("none"))
        g_variant_type_free(type)
        connect(pin, "activate") { [weak self] in
            guard let self, let target else { return }
            onPin?(target)
        }
        connect(comment, "activate") { [weak self] in
            guard let self, let target else { return }
            onComment?(target)
        }
        connect(decrypt, "activate") { [weak self] in
            guard let self, let target, let isOn = decrypts?(target.host) else { return }
            onDecrypt?(target.host, !isOn)
        }
        connect(color, "activate") { [weak self] (arguments: Arguments) in
            guard let self, let target,
                let name = arguments.variant(1).flatMap({ string(g_variant_get_string($0, nil)) })
            else { return }
            onColor?(target, MarkColor(rawValue: name))
        }
        for action in [pin, comment, decrypt, color] {
            g_action_map_add_action(cast(actions), cast(action))
            g_object_unref(raw(action))
        }
        gtk_widget_insert_action_group(view, "row", cast(actions))
    }

    /// Opens the menu for `summary`'s row, pointing at `rect`, in the view's coordinates.
    func open(for summary: ExchangeSummary, at rect: GdkRectangle) {
        target = summary
        fill(for: summary)
        var rect = rect
        gtk_popover_set_pointing_to(cast(popover), &rect)
        gtk_popover_popup(cast(popover))
    }

    var isOpen: Bool {
        gtk_widget_get_visible(popover) != 0
    }

    func close() {
        gtk_popover_popdown(cast(popover))
    }

    /// The entries for `summary`, in the Mac's order: pinning, then decrypting. Only the ones
    /// whose words change are made again: GTK 4.14's menu keeps a submenu's page when the entry
    /// that has it goes.
    private func fill(for summary: ExchangeSummary) {
        let annotation = summary.annotation
        g_simple_action_set_state(color, g_variant_new_string(annotation.color?.rawValue ?? "none"))
        replace(0, of: marks, with: annotation.isPinned ? "Unpin Request" : "Pin Request", "row.pin")
        replace(2, of: marks, with: annotation.comment == nil ? "Add Comment…" : "Edit Comment…", "row.comment")
        g_menu_remove_all(decrypting)
        // HTTPS is all there is to decrypt, from an encrypted connection or a request decrypted.
        if summary.scheme == "https", let isOn = decrypts?(summary.host) {
            // The menu reads an underscore as the next letter's shortcut.
            let host = summary.host.replacingOccurrences(of: "_", with: "__")
            g_menu_append(decrypting, isOn ? "Stop Decrypting \(host)" : "Decrypt \(host)", "row.decrypt")
        }
    }

    private func replace(_ index: Int32, of section: OpaquePointer, with title: String, _ action: String) {
        g_menu_remove(section, index)
        g_menu_insert(section, index, title, action)
    }

    private static func append(_ section: OpaquePointer, _ title: String, color name: String) {
        let item = g_menu_item_new(title, nil)!
        g_menu_item_set_action_and_target_value(item, "row.color", g_variant_new_string(name))
        g_menu_append_item(section, item)
        g_object_unref(raw(item))
    }
}
