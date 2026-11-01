import CGtk
import CoreInterface
import GtkBinding
import ReqlyModel

/// The request list: a GtkColumnView over a GtkStringList of exchange IDs, kept in step with the
/// session's rows by its `rows` events, through ``RowMirror``, with each row's contents asked for
/// with ``SessionHost/rows(_:)`` as it comes or changes, as the Windows app's list does. Its
/// columns are the app that sent the request, with its icon, the method, the host, the path, the
/// status and the size. Until there's traffic, a status page says how to start. A list that shows
/// its last row follows new traffic, as on the Mac.
@MainActor
final class RequestList {
    enum Column: CaseIterable {
        case app, method, host, path, status, size

        var title: String {
            switch self {
            case .app: "App"
            case .method: "Method"
            case .host: "Host"
            case .path: "Path"
            case .status: "Status"
            case .size: "Size"
            }
        }

        /// Its width at first, or `nil` for the one that takes the rest.
        var width: Int32? {
            switch self {
            case .app: 180
            case .method: 80
            case .host: 220
            case .path: nil
            case .status: 72
            case .size: 88
            }
        }
    }

    /// The list, or the status page in its place.
    let widget: Widget
    let view: Widget
    let icons = AppIcons()
    /// How many requests the session has.
    private(set) var total = 0
    private let model: AppModel
    private let scroller: Widget
    private let empty: Widget
    /// The rows' exchange IDs, as text, which the view shows.
    private let items: OpaquePointer
    private var mirror = RowMirror()
    private var isReadingRows = false
    /// The rows' contents, as the session last gave them.
    private var summaries: [ExchangeID: ExchangeSummary] = [:]
    private var wanted: Set<ExchangeID> = []
    private var isFetching = false
    /// The cells GTK has bound, by list item, and the list items showing each exchange, so a
    /// changed exchange's cells are filled in again where they are.
    private var bound: [UnsafeMutableRawPointer: (id: ExchangeID, column: Column)] = [:]
    private var itemsByID: [ExchangeID: [UnsafeMutableRawPointer]] = [:]

    init(model: AppModel) {
        self.model = model
        items = gtk_string_list_new(nil)
        let selection = gtk_single_selection_new(cast(items))!
        gtk_single_selection_set_autoselect(selection, 0)
        gtk_single_selection_set_can_unselect(selection, 1)
        view = gtk_column_view_new(cast(selection))
        gtk_widget_add_css_class(view, "data-table")
        gtk_column_view_set_reorderable(cast(view), 0)
        setAccessibleLabel(view, "Requests")
        scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_child(cast(scroller), view)
        empty = adw_status_page_new()
        adw_status_page_set_icon_name(cast(empty), "network-transmit-receive-symbolic")
        widget = gtk_stack_new()
        gtk_stack_add_named(cast(widget), empty, "empty")
        gtk_stack_add_named(cast(widget), scroller, "list")
        for column in Column.allCases {
            add(column)
        }
        icons.onFound = { [weak self] key in self?.iconFound(key) }
        model.listen { [weak self] event in
            guard let self, case .rows(let version, let total, _, let steps) = event else { return }
            self.total = total
            if let change = mirror.receive(version: version, steps: steps) {
                apply(change)
            }
            if mirror.isWaitingForRows {
                readEveryRow()
            }
        }
        model.observe { [weak self] in self?.showState() }
        showState()
    }

    /// How many rows the list shows.
    var count: Int { mirror.ids.count }

    /// The exchange a row shows, and its contents once they're in.
    func summary(at row: Int) -> ExchangeSummary? {
        mirror.ids.indices.contains(row) ? summaries[mirror.ids[row]] : nil
    }

    /// The widget a column's cell shows an exchange with, while GTK has one bound.
    func cell(_ column: Column, of id: ExchangeID) -> Widget? {
        let item = itemsByID[id]?.first { bound[$0]?.column == column }
        return item.flatMap { gtk_list_item_get_child(cast($0)) }
    }

    // MARK: - The rows

    /// Makes the change to the view's rows, then asks for the contents of the new and changed
    /// ones.
    private func apply(_ change: RowMirror.Change) {
        let follows = showsEnd()
        for splice in change.splices {
            withCStrings(splice.inserting.map { String($0.rawValue) }) {
                gtk_string_list_splice(items, UInt32(splice.position), UInt32(splice.removing), $0)
            }
        }
        if change.splices.contains(where: { $0.removing > 0 }) {
            summaries = summaries.filter { mirror.members.contains($0.key) }
        }
        want(change.inserted.filter { summaries[$0] == nil } + change.changed)
        showState()
        if follows, count > 0, !change.inserted.isEmpty {
            gtk_column_view_scroll_to(cast(view), UInt32(count - 1), nil, GTK_LIST_SCROLL_NONE, nil)
        }
    }

    /// Asks the session for every row, when an event was missing, and goes on from there.
    private func readEveryRow() {
        guard !isReadingRows, let session = model.session else { return }
        isReadingRows = true
        Task {
            let rows = await session.rowIDs()
            isReadingRows = false
            apply(mirror.reset(version: rows.version, ids: rows.ids))
            if mirror.isWaitingForRows {
                readEveryRow()
            }
        }
    }

    /// Asks for the contents of rows, a batch at a time, then fills in their cells.
    private func want(_ ids: [ExchangeID]) {
        wanted.formUnion(ids)
        guard !isFetching, !wanted.isEmpty else { return }
        isFetching = true
        Task {
            // Changes that come together are asked for together.
            await Task.yield()
            while !wanted.isEmpty, let session = model.session {
                let batch = Array(wanted.prefix(500))
                wanted.subtract(batch)
                for summary in await session.rows(batch) where mirror.members.contains(summary.id) {
                    summaries[summary.id] = summary
                    refill(summary.id)
                }
            }
            isFetching = false
        }
    }

    /// The status page while there's no traffic, saying how to start, and the list after.
    private func showState() {
        guard count == 0 else {
            gtk_stack_set_visible_child(cast(widget), scroller)
            return
        }
        gtk_stack_set_visible_child(cast(widget), empty)
        let title: String
        let description: String
        switch (model.isCapturing, model.options.setsSystemProxy) {
        case (true, true):
            title = "Waiting for Traffic"
            description = "Use an app that goes online, such as Firefox. Its requests show up here."
        case (true, false):
            title = "Waiting for Traffic"
            description =
                "Reqly isn't setting your desktop's proxy, so point apps at 127.0.0.1, port \(model.port), or use "
                + "Open Terminal."
        case (false, true):
            title = "No Traffic Yet"
            description =
                "Turn on Capture to see what your apps send and receive. While capturing, Reqly is your desktop's "
                + "proxy, and your settings come back when you stop."
        case (false, false):
            title = "No Traffic Yet"
            description = "Turn on Capture to see what your apps send and receive."
        }
        adw_status_page_set_title(cast(empty), title)
        adw_status_page_set_description(cast(empty), description)
    }

    /// Whether the list shows its last row, or nearly: then it follows new traffic. GTK 4.18 and
    /// later leave the last row just below the edge when scrolling to it.
    private func showsEnd() -> Bool {
        guard let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroller)) else { return true }
        let value = gtk_adjustment_get_value(adjustment)
        let page = gtk_adjustment_get_page_size(adjustment)
        let upper = gtk_adjustment_get_upper(adjustment)
        return upper <= page || value + page >= upper - 48
    }

    // MARK: - Cells

    private func add(_ column: Column) {
        let factory = gtk_signal_list_item_factory_new()
        connect(factory, "setup") { [weak self] (arguments: Arguments) in
            self?.setUp(arguments.object(1)!, column)
        }
        connect(factory, "bind") { [weak self] (arguments: Arguments) in
            self?.bind(arguments.object(1)!, column)
        }
        connect(factory, "unbind") { [weak self] (arguments: Arguments) in
            self?.unbind(arguments.object(1)!)
        }
        let viewColumn = gtk_column_view_column_new(column.title, factory)
        if column == .method {
            gtk_column_view_column_set_fixed_width(viewColumn, methodWidth())
        } else if let width = column.width {
            gtk_column_view_column_set_fixed_width(viewColumn, width)
        } else {
            gtk_column_view_column_set_expand(viewColumn, 1)
        }
        gtk_column_view_column_set_resizable(viewColumn, 1)
        gtk_column_view_append_column(cast(view), viewColumn)
        g_object_unref(raw(viewColumn))
    }

    /// The Method column's width: room for the longest method, CONNECT, and the column's title,
    /// in the window's font, with the cell's padding, and at least the width it starts with
    /// elsewhere. GNOME 48's font, Adwaita Sans, is wider than the fonts before it.
    func methodWidth() -> Int32 {
        var widest: Int32 = 0
        for text in ["CONNECT", "OPTIONS", Column.method.title] {
            guard let layout = gtk_widget_create_pango_layout(view, text) else { continue }
            var width: Int32 = 0
            pango_layout_get_pixel_size(layout, &width, nil)
            g_object_unref(raw(layout))
            widest = max(widest, width)
        }
        return max(Column.method.width ?? 0, widest + 28)
    }

    /// A cell's widgets: a label, and before it an icon for the app, or a lock for the status.
    private func setUp(_ item: UnsafeMutableRawPointer, _ column: Column) {
        let label = gtk_label_new(nil)!
        gtk_label_set_xalign(cast(label), column == .size ? 1 : 0)
        gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(cast(label), 1)
        gtk_widget_set_hexpand(label, 1)
        if column == .status || column == .size {
            gtk_widget_add_css_class(label, "numeric")
        }
        guard column == .app || column == .status else {
            gtk_list_item_set_child(cast(item), label)
            return
        }
        let cell = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let icon = gtk_image_new()!
        gtk_widget_set_visible(icon, 0)
        gtk_box_append(cast(cell), icon)
        gtk_box_append(cast(cell), label)
        gtk_list_item_set_child(cast(item), cell)
    }

    private func bind(_ item: UnsafeMutableRawPointer, _ column: Column) {
        guard let object = gtk_list_item_get_item(cast(item)) else { return }
        let id = ExchangeID(rawValue: strtoull(gtk_string_object_get_string(cast(object)), nil, 10))
        bound[item] = (id, column)
        itemsByID[id, default: []].append(item)
        fill(item, column, id)
    }

    private func unbind(_ item: UnsafeMutableRawPointer) {
        guard let (id, _) = bound.removeValue(forKey: item) else { return }
        itemsByID[id]?.removeAll { $0 == item }
        if itemsByID[id]?.isEmpty == true {
            itemsByID[id] = nil
        }
    }

    /// Fills in the cells showing an exchange again, with its new contents.
    private func refill(_ id: ExchangeID) {
        for item in itemsByID[id] ?? [] {
            if let column = bound[item]?.column {
                fill(item, column, id)
            }
        }
    }

    /// Shows the icon of an app found since its rows were filled in.
    private func iconFound(_ key: String) {
        for (item, cell) in bound where cell.column == .app {
            if let source = summaries[cell.id]?.source, AppIcons.key(of: source) == key {
                fill(item, .app, cell.id)
            }
        }
    }

    private func fill(_ item: UnsafeMutableRawPointer, _ column: Column, _ id: ExchangeID) {
        guard let cell = gtk_list_item_get_child(cast(item)) else { return }
        let summary = summaries[id]
        let text = summary.map(RowText.init)
        let label: Widget
        switch column {
        case .app, .status:
            let icon = gtk_widget_get_first_child(cell)!
            label = gtk_widget_get_next_sibling(icon)!
            if column == .app {
                let found = summary?.source.flatMap { icons.icon(for: $0) }
                if let found {
                    gtk_image_set_from_gicon(cast(icon), found)
                }
                gtk_widget_set_visible(icon, cBool(found != nil))
            } else {
                let showsLock = text?.showsLock ?? false
                if showsLock {
                    gtk_image_set_from_icon_name(cast(icon), "channel-secure-symbolic")
                    setAccessibleLabel(icon, text?.statusDescription ?? "")
                    gtk_widget_set_tooltip_text(icon, text?.statusDescription)
                }
                gtk_widget_set_visible(icon, cBool(showsLock))
            }
        default:
            label = cell
        }
        let words: String =
            switch column {
            case .app: text?.app ?? ""
            case .method: text?.method ?? ""
            case .host: text?.host ?? ""
            case .path: text?.path ?? ""
            case .status: text?.status ?? ""
            case .size: text?.size ?? ""
            }
        gtk_label_set_text(cast(label), words)
        if column == .path, summary?.kind == .tunnel {
            gtk_widget_add_css_class(label, "dim-label")
        } else if column == .path {
            gtk_widget_remove_css_class(label, "dim-label")
        }
    }
}
