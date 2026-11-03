import BodyKit
import CGtk
import GtkBinding

/// A form's fields, for a body sent as `application/x-www-form-urlencoded` or as
/// `multipart/form-data`, as the Mac shows them: each field's name over its value, and for a
/// file, its name, type and size. A row each, which Tab stops on once, as a screen reader reads
/// its name and value.
@MainActor
final class FormView {
    let widget: Widget
    /// The rows' names and values, as they show.
    private(set) var rows: [(name: String, value: String)] = []

    /// A form shows at most this many fields, so a huge one doesn't make a row for each.
    static let most = 1_000

    init(fields: [FormField]?, parts: [MultipartPart]?) {
        var rows = (fields ?? []).map { (name: $0.name, value: $0.value, isText: true) }
        rows += (parts ?? []).map {
            (name: BodyWords.name(of: $0), value: BodyWords.describe($0), isText: $0.filename == nil)
        }
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
        g_object_ref_sink(raw(widget))
        guard !rows.isEmpty else {
            let none = gtk_label_new(BodyWords.noFields)!
            gtk_label_set_xalign(cast(none), 0)
            gtk_widget_add_css_class(none, "dim-label")
            gtk_box_append(cast(widget), none)
            return
        }
        let list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(list, "boxed-list")
        setAccessibleLabel(list, "Form")
        for row in rows.prefix(Self.most) {
            let shown = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(shown), 0)
            adw_preferences_row_set_title(cast(shown), row.name)
            adw_action_row_set_subtitle(cast(shown), row.value)
            // The value is what you read, the name over it, as GNOME's property rows have it.
            gtk_widget_add_css_class(shown, "property")
            if row.isText {
                gtk_widget_add_css_class(shown, "monospace")
            }
            gtk_list_box_append(cast(list), shown)
            self.rows.append((row.name, row.value))
        }
        gtk_box_append(cast(widget), list)
        if rows.count > Self.most {
            let more = gtk_label_new("Showing the first \(Self.most.formatted()) fields of \(rows.count.formatted()).")!
            gtk_label_set_xalign(cast(more), 0)
            gtk_widget_add_css_class(more, "dim-label")
            gtk_widget_add_css_class(more, "caption")
            gtk_box_append(cast(widget), more)
        }
    }

    isolated deinit {
        g_object_unref(raw(widget))
    }
}
