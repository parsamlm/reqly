import BodyKit
import CGtk
import GtkBinding

/// A form's fields, for a body sent as `application/x-www-form-urlencoded` or as
/// `multipart/form-data`, as the Mac shows them: each field's name beside its value, which you can
/// select and copy, and for a file, its name, type and size. A row each, which Tab stops on once,
/// at its value, which screen readers name by the field's name.
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
        // The details' rows, as the Mac's: each name beside its value, which you can select, a text
        // field's in a monospace font.
        let shown = rows.prefix(Self.most)
        let card = DetailsBlocks.card(shown.map { DetailsBlocks.row($0.name, value: $0.value, isCode: $0.isText) })
        self.rows = shown.map { ($0.name, $0.value) }
        gtk_box_append(cast(widget), card)
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
