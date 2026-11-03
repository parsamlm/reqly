import CGtk
import GtkBinding
import ReqlyModel

/// The request list's cells: what each column's cell is made of, made once and used for row after
/// row, and how it shows a row's words. Text is in GtkInscriptions, which cost less than labels
/// for cells made and filled as fast as rows scroll by. Icons are hidden from screen readers,
/// since the row's label says what they mean.
///
/// - Status: a symbol, for a request that failed, paused, or an encrypted connection, or a dot in
///   the status class's color, or a dotted circle while there's no response, then the code.
/// - Method, Time, Duration and Size: their words, Duration and Size at the end.
/// - Request: the host, then the path dimmed, and a pin and a speech bubble for a request that's
///   pinned or has a comment, the comment as the cell's tooltip.
/// - App: the app's icon and its name, dimmed.
///
/// A color mark is the row's own: a stripe at its leading edge and a tint, which the Status cell
/// gives the row it's in.
@MainActor
enum RequestCells {
    /// A column's cell's widgets.
    static func make(_ column: RequestList.Column) -> Widget {
        switch column {
        case .status:
            let cell = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
            let symbol = unreadWidget(gtk_image_get_type())
            gtk_widget_add_css_class(symbol, "request-symbol")
            gtk_widget_set_visible(symbol, 0)
            let dot = unreadWidget(gtk_box_get_type())
            gtk_widget_add_css_class(dot, "request-dot")
            gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
            gtk_box_append(cast(cell), symbol)
            gtk_box_append(cast(cell), dot)
            gtk_box_append(cast(cell), words(column))
            return cell
        case .request:
            let cell = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
            let text = words(column)
            gtk_widget_set_hexpand(text, 1)
            gtk_box_append(cast(cell), text)
            for name in [Icons.pin, Icons.comment] {
                let icon = unreadWidget(gtk_image_get_type())
                gtk_image_set_from_icon_name(cast(icon), name)
                gtk_widget_add_css_class(icon, "dim-label")
                gtk_widget_set_visible(icon, 0)
                gtk_box_append(cast(cell), icon)
            }
            return cell
        case .app:
            let cell = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
            let icon = unreadWidget(gtk_image_get_type())
            gtk_widget_set_visible(icon, 0)
            gtk_box_append(cast(cell), icon)
            gtk_box_append(cast(cell), words(column))
            return cell
        case .method, .time, .duration, .size:
            return words(column)
        }
    }

    /// Shows `text` in a cell `make` made, or nothing while the row's contents are on their way.
    /// The App column's `icon` is the app's, once it's found.
    static func fill(_ cell: Widget, _ column: RequestList.Column, _ text: RowText?, icon: OpaquePointer? = nil) {
        switch column {
        case .status:
            let symbol = gtk_widget_get_first_child(cell)!
            let dot = gtk_widget_get_next_sibling(symbol)!
            show(text?.look, symbol: symbol, dot: dot)
            set(gtk_widget_get_next_sibling(dot), text?.status)
            setTooltip(cell, text?.statusHelp)
            mark(rowOf: cell, text?.color)
        case .request:
            let words = gtk_widget_get_first_child(cell)!
            let pin = gtk_widget_get_next_sibling(words)!
            let comment = gtk_widget_get_next_sibling(pin)!
            if let request = text?.request {
                let markup =
                    escaped(request.host)
                    + (request.rest.isEmpty ? "" : "<span fgalpha=\"55%\">\(escaped(request.rest))</span>")
                gtk_inscription_set_markup(cast(words), markup)
            } else {
                gtk_inscription_set_text(cast(words), nil)
            }
            gtk_widget_set_visible(pin, cBool(text?.isPinned == true))
            gtk_widget_set_visible(comment, cBool(text?.comment != nil))
            setTooltip(cell, text?.comment)
        case .app:
            let image = gtk_widget_get_first_child(cell)!
            if let icon {
                gtk_image_set_from_gicon(cast(image), icon)
            }
            gtk_widget_set_visible(image, cBool(icon != nil))
            set(gtk_widget_get_next_sibling(image), text?.app)
            setTooltip(cell, text?.appHelp)
        case .method: set(cell, text?.method)
        case .time: set(cell, text?.time)
        case .duration: set(cell, text?.duration)
        case .size: set(cell, text?.size)
        }
    }

    /// What a cell's words say, for the self-check: its inscription's text.
    static func words(of cell: Widget, _ column: RequestList.Column) -> String {
        let words: Widget? =
            switch column {
            case .status: gtk_widget_get_last_child(cell)
            case .request: gtk_widget_get_first_child(cell)
            case .app: gtk_widget_get_last_child(cell)
            case .method, .time, .duration, .size: cell
            }
        return words.flatMap { string(gtk_inscription_get_text(cast($0))) } ?? ""
    }

    /// The row's widget a cell's child is in: the child's parent is the cell's widget, and its
    /// parent the row's. `nil` while GTK hasn't put the cell in a row.
    static func row(of cell: Widget) -> Widget? {
        guard let row = gtk_widget_get_parent(cell).flatMap({ gtk_widget_get_parent($0) }),
            typeName(raw(row)) == "GtkColumnViewRowWidget"
        else { return nil }
        return row
    }

    // MARK: - The parts

    /// A cell's words: an inscription, one line, cut short at its end, in the Mac's colors and
    /// with figures of one width for numbers.
    private static func words(_ column: RequestList.Column) -> Widget {
        let words = gtk_inscription_new(nil)!
        gtk_inscription_set_text_overflow(cast(words), GTK_INSCRIPTION_OVERFLOW_ELLIPSIZE_END)
        gtk_inscription_set_xalign(cast(words), column == .duration || column == .size ? 1 : 0)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(words, 1)
        if [.status, .time, .duration, .size].contains(column) {
            gtk_widget_add_css_class(words, "numeric")
        }
        if column == .method || column == .app {
            gtk_widget_add_css_class(words, "dim-label")
        }
        return words
    }

    private static func set(_ words: Widget?, _ text: String?) {
        gtk_inscription_set_text(cast(words), text)
    }

    /// A cell's tooltip, when it's another: setting one has GTK look for the tooltip under the
    /// pointer, which costs a lot for every cell a frame binds.
    private static func setTooltip(_ cell: Widget, _ text: String?) {
        if string(gtk_widget_get_tooltip_text(cell)) != text {
            gtk_widget_set_tooltip_text(cell, text)
        }
    }

    /// The Status cell's symbol or dot, as `look` has it.
    private static func show(_ look: RowText.Look?, symbol: Widget, dot: Widget) {
        let name: String? =
            switch look {
            case .failed: Icons.warning
            case .paused: Icons.pause
            case .encrypted: "channel-secure-symbolic"
            case .status, .waiting, nil: nil
            }
        if let name {
            gtk_image_set_from_icon_name(cast(symbol), name)
            for kind in ["failed", "paused", "dim-label"] {
                gtk_widget_remove_css_class(symbol, kind)
            }
            gtk_widget_add_css_class(symbol, look == .failed ? "failed" : look == .paused ? "paused" : "dim-label")
        }
        gtk_widget_set_visible(symbol, cBool(name != nil))
        for status in StatusClass.allCases {
            gtk_widget_remove_css_class(dot, status.styleClass)
        }
        gtk_widget_remove_css_class(dot, "waiting")
        switch look {
        case .status(let status): gtk_widget_add_css_class(dot, status.styleClass)
        case .waiting: gtk_widget_add_css_class(dot, "waiting")
        default: break
        }
        gtk_widget_set_visible(dot, cBool(name == nil && look != nil))
    }

    /// Marks the row a cell is in with `color`, or with none.
    private static func mark(rowOf cell: Widget, _ color: MarkColor?) {
        guard let row = row(of: cell) else { return }
        for other in MarkColor.allCases where other != color {
            gtk_widget_remove_css_class(row, ListStyles.markClass(other))
        }
        if let color {
            gtk_widget_add_css_class(row, "marked")
            gtk_widget_add_css_class(row, ListStyles.markClass(color))
        } else {
            gtk_widget_remove_css_class(row, "marked")
        }
    }

    private static func escaped(_ text: String) -> String {
        takeString(g_markup_escape_text(text, -1)) ?? ""
    }

    /// A widget of `type` that screen readers skip, as an icon whose meaning the row's words say:
    /// its role is none, which GTK takes only as it's made.
    private static func unreadWidget(_ type: GType) -> Widget {
        var role = GValue()
        g_value_init(&role, gtk_accessible_role_get_type())
        g_value_set_enum(&role, Int32(GTK_ACCESSIBLE_ROLE_NONE.rawValue))
        defer { g_value_unset(&role) }
        var name: UnsafePointer<CChar>? = UnsafePointer(strdup("accessible-role"))
        defer { free(UnsafeMutableRawPointer(mutating: name)) }
        return cast(g_object_new_with_properties(type, 1, &name, &role))
    }
}
