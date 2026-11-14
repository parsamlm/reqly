import CGtk
import GtkBinding
import ReqlyModel

/// The details' heading, under their header bar, as the Mac's: the method and the path, which you
/// can select, beside the Pin, Color and Comment buttons; where the request went, what sent it
/// and from which device; and the status line, such as "● 200 OK · 161 ms · 292 B · 11:05:59".
/// Its widgets stay as the request changes, so the focus stays on them.
@MainActor
final class DetailsHeadingView {
    let box: Widget
    let method: Widget
    let path: Widget
    let pinButton: Widget
    let colorButton: Widget
    let commentButton: Widget
    let subtitle: Widget
    /// The status's dot, or the icon in its place: a warning, a pause or a lock.
    let dot: Widget
    let icon: Widget
    /// The status code, in bold, then the rest of the line.
    let code: Widget
    let line: Widget
    /// The color's dot in its button, or a ring for none.
    private let mark: Widget

    /// Fills `box`, the pane's heading. `colors` is the Color button's menu.
    init(_ box: Widget, colors: OpaquePointer) {
        self.box = box
        gtk_widget_add_css_class(box, "details-heading")
        let top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        method = gtk_label_new(nil)
        gtk_widget_add_css_class(method, "details-method")
        gtk_widget_add_css_class(method, "dim-label")
        gtk_widget_set_valign(method, GTK_ALIGN_BASELINE_FILL)
        path = gtk_label_new(nil)
        gtk_label_set_xalign(cast(path), 0)
        gtk_label_set_ellipsize(cast(path), PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_single_line_mode(cast(path), 1)
        gtk_label_set_selectable(cast(path), 1)
        gtk_widget_add_css_class(path, "title-4")
        gtk_widget_set_hexpand(path, 1)
        gtk_widget_set_valign(path, GTK_ALIGN_BASELINE_FILL)
        // Said as one, such as "GET /v2/forecast".
        setAccessibleRelation(path, GTK_ACCESSIBLE_RELATION_LABELLED_BY, [method, path])

        pinButton = DetailsBlocks.iconButton(Icons.pin, "Pin Request")
        gtk_actionable_set_action_name(cast(pinButton), "details.pin")
        mark = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(mark, "details-mark")
        gtk_widget_set_halign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        colorButton = gtk_menu_button_new()
        gtk_menu_button_set_child(cast(colorButton), mark)
        gtk_menu_button_set_menu_model(cast(colorButton), cast(colors))
        gtk_widget_add_css_class(colorButton, "flat")
        gtk_widget_set_tooltip_text(colorButton, "Mark with a Color")
        setAccessibleLabel(colorButton, "Color")
        commentButton = DetailsBlocks.iconButton(Icons.comment, "Add Comment")
        gtk_actionable_set_action_name(cast(commentButton), "details.comment")
        for widget in [method, path, pinButton, colorButton, commentButton] {
            gtk_box_append(cast(top), widget)
        }
        for button in [pinButton, colorButton, commentButton] {
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        }

        subtitle = gtk_label_new(nil)
        gtk_label_set_xalign(cast(subtitle), 0)
        gtk_label_set_ellipsize(cast(subtitle), PANGO_ELLIPSIZE_END)
        gtk_widget_add_css_class(subtitle, "dim-label")

        let status = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        // In the list's color for the status class.
        ListStyles.install()
        dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(dot, "details-dot")
        gtk_widget_add_css_class(dot, "request-dot")
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        icon = gtk_image_new()
        // The words beside them say what they mean, and the line says the code too.
        setAccessibleHidden(dot, true)
        setAccessibleHidden(icon, true)
        code = gtk_label_new(nil)
        gtk_widget_add_css_class(code, "heading")
        gtk_widget_add_css_class(code, "numeric")
        setAccessibleHidden(code, true)
        line = gtk_label_new(nil)
        gtk_label_set_xalign(cast(line), 0)
        gtk_label_set_ellipsize(cast(line), PANGO_ELLIPSIZE_END)
        gtk_widget_add_css_class(line, "dim-label")
        gtk_widget_add_css_class(line, "numeric")
        gtk_widget_set_hexpand(line, 1)
        for widget in [dot, icon, code, line] {
            gtk_box_append(cast(status), widget)
        }
        gtk_widget_set_margin_top(status, 2)

        for widget in [top, subtitle, status] {
            gtk_box_append(cast(box), widget)
        }
    }

    /// Shows `heading`, with `annotation`'s pin, color and comment on the buttons.
    func show(_ heading: DetailsHeading, annotation: Annotation) {
        gtk_label_set_text(cast(method), heading.method)
        gtk_label_set_text(cast(path), heading.title)
        gtk_widget_set_tooltip_text(path, heading.title)
        gtk_label_set_text(cast(subtitle), heading.subtitle)
        gtk_widget_set_tooltip_text(subtitle, heading.subtitle)

        for name in Self.statusClasses {
            gtk_widget_remove_css_class(dot, name)
        }
        gtk_widget_remove_css_class(icon, "error")
        gtk_widget_remove_css_class(icon, "accent")
        switch heading.mark {
        case .dot(let statusClass):
            if let statusClass {
                gtk_widget_add_css_class(dot, statusClass.styleClass)
            }
        case .failed:
            gtk_image_set_from_icon_name(cast(icon), Icons.warning)
            gtk_widget_add_css_class(icon, "error")
        case .paused:
            gtk_image_set_from_icon_name(cast(icon), Icons.pause)
            gtk_widget_add_css_class(icon, "accent")
        case .lock:
            gtk_image_set_from_icon_name(cast(icon), Icons.lock)
        case .none:
            break
        }
        let hasDot = if case .dot = heading.mark { true } else { false }
        gtk_widget_set_visible(dot, cBool(hasDot))
        gtk_widget_set_visible(icon, cBool(!hasDot && heading.mark != .none))
        gtk_label_set_text(cast(code), heading.code ?? "")
        gtk_widget_set_visible(code, cBool(heading.code != nil))
        gtk_label_set_text(cast(line), heading.afterCode)
        gtk_widget_set_tooltip_text(line, heading.line)
        // Read as the whole line, the code and all.
        setAccessibleLabel(line, heading.line)
        show(annotation)
    }

    /// The pin, the color and the comment on the buttons: the pin in the accent color while the
    /// request is pinned, the color's dot, and whether there's a comment to edit.
    func show(_ annotation: Annotation) {
        let pin = annotation.isPinned ? "Unpin Request" : "Pin Request"
        setAccessibleLabel(pinButton, pin)
        gtk_widget_set_tooltip_text(
            pinButton, annotation.isPinned ? pin : "Pin Request. Pinned requests stay when you clear traffic.")
        if annotation.isPinned {
            gtk_widget_add_css_class(pinButton, "accent")
        } else {
            gtk_widget_remove_css_class(pinButton, "accent")
        }
        for color in MarkColor.allCases {
            gtk_widget_remove_css_class(mark, color.rawValue)
        }
        if let color = annotation.color {
            gtk_widget_add_css_class(mark, color.rawValue)
        }
        setAccessibleDescription(colorButton, annotation.color?.title ?? "None")
        let comment = annotation.comment == nil ? "Add Comment" : "Edit Comment"
        setAccessibleLabel(commentButton, comment)
        gtk_widget_set_tooltip_text(commentButton, comment)
    }

    private static let statusClasses = StatusClass.allCases.map(\.styleClass)
}
