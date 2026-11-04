import BodyKit
import CGtk
import GtkBinding

/// A JSON or protobuf body as a tree, as the Mac's: each node's key, its value in code's colors,
/// and its type, a row each, which a screen reader reads as one. The rows are GTK's tree list,
/// whose nodes' children are made as they open; the root and its children start open, as
/// ``TreeRows`` has it. "Filter keys and values" keeps the nodes it matches and those above them,
/// open. Choosing a row shows its path, such as `days[0].high`, with Copy Path and Copy Value,
/// which the session works out.
@MainActor
final class TreeView {
    /// The filter, the tree in its scroller, and the path bar.
    let widget: Widget
    let filter: Widget
    let list: Widget
    let scroller: Widget
    /// The path of the row chosen, and its buttons, while there's one.
    let pathBar: Widget
    let pathLabel: Widget
    /// What the filter keeps, or `nil` while it's empty.
    private(set) var kept: Set<Int>?
    /// The chosen row's path and value, once the session has said them.
    private(set) var chosen: (node: Int, path: String, value: String)?
    /// Runs when Copy Path or Copy Value has copied, so the page can say so.
    var onCopy: ((String) -> Void)?

    private let tree: any ValueOutline
    private let locate: @MainActor (Int) async -> (path: String, copyText: String)?
    private let selection: OpaquePointer
    private var rows: OpaquePointer
    private let noMatches: Widget
    /// Counts the filter's changes, so only the latest one's nodes show.
    private var filtering = 0
    /// GTK_INVALID_LIST_POSITION: no row.
    private static let none = UInt32.max

    /// Shows `tree`; `node` gives a node's path and value to copy, from the session.
    init(_ tree: any ValueOutline, node: @escaping @MainActor (Int) async -> (path: String, copyText: String)?) {
        self.tree = tree
        locate = node
        BodyStyles.install()
        rows = Self.rows(of: tree, kept: nil)
        // The selection takes the rows, and the list the selection and its factory; this keeps the
        // rows and the selection too.
        g_object_ref(raw(rows))
        selection = cast(gtk_single_selection_new(cast(rows)))
        g_object_ref(raw(selection))
        gtk_single_selection_set_autoselect(selection, 0)
        gtk_single_selection_set_can_unselect(selection, 1)
        gtk_single_selection_set_selected(selection, Self.none)

        filter = gtk_search_entry_new()
        gtk_search_entry_set_placeholder_text(cast(filter), "Filter keys and values")
        setAccessibleLabel(filter, "Filter keys and values")
        noMatches = gtk_label_new(nil)
        gtk_label_set_xalign(cast(noMatches), 0)
        gtk_label_set_wrap(cast(noMatches), 1)
        gtk_widget_add_css_class(noMatches, "dim-label")
        gtk_widget_set_visible(noMatches, 0)

        let factory = gtk_signal_list_item_factory_new()!
        list = gtk_list_view_new(cast(selection), factory)
        gtk_list_view_set_tab_behavior(cast(list), GTK_LIST_TAB_ITEM)
        setAccessibleLabel(list, "Tree")
        scroller = namedScroller("Tree")
        gtk_scrolled_window_set_child(cast(scroller), list)
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
        gtk_scrolled_window_set_max_content_height(cast(scroller), 480)
        gtk_widget_add_css_class(scroller, "card")
        gtk_widget_set_overflow(scroller, GTK_OVERFLOW_HIDDEN)

        pathLabel = gtk_label_new(nil)
        gtk_label_set_xalign(cast(pathLabel), 0)
        gtk_label_set_selectable(cast(pathLabel), 1)
        gtk_label_set_ellipsize(cast(pathLabel), PANGO_ELLIPSIZE_MIDDLE)
        gtk_widget_set_hexpand(pathLabel, 1)
        gtk_widget_add_css_class(pathLabel, "monospace")
        let copyPath = gtk_button_new_with_label("Copy Path")!
        let copyValue = gtk_button_new_with_label("Copy Value")!
        pathBar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_widget_add_css_class(pathBar, "card")
        gtk_widget_add_css_class(pathBar, "path-bar")
        for child in [pathLabel, copyPath, copyValue] {
            if child != pathLabel {
                gtk_widget_add_css_class(child, "flat")
                gtk_widget_set_valign(child, GTK_ALIGN_CENTER)
            }
            gtk_box_append(cast(pathBar), child)
        }
        gtk_widget_set_visible(pathBar, 0)

        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)
        g_object_ref_sink(raw(widget))
        for child in [filter, noMatches, scroller, pathBar] {
            gtk_box_append(cast(widget), child)
        }

        connect(factory, "setup") { (arguments: Arguments) in
            let expander = gtk_tree_expander_new()!
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            gtk_widget_add_css_class(row, "tree-row")
            let key = gtk_inscription_new(nil)!
            gtk_widget_add_css_class(key, "key")
            gtk_widget_set_size_request(key, 150, -1)
            let value = gtk_inscription_new(nil)!
            gtk_widget_add_css_class(value, "monospace")
            gtk_widget_set_hexpand(value, 1)
            let type = gtk_inscription_new(nil)!
            gtk_widget_add_css_class(type, "dim-label")
            gtk_widget_add_css_class(type, "caption")
            gtk_widget_set_size_request(type, 84, -1)
            gtk_inscription_set_xalign(cast(type), 1)
            for inscription in [key, value, type] {
                gtk_inscription_set_text_overflow(cast(inscription), GTK_INSCRIPTION_OVERFLOW_ELLIPSIZE_END)
                gtk_box_append(cast(row), inscription)
            }
            gtk_tree_expander_set_child(cast(expander), row)
            gtk_widget_set_margin_end(expander, 10)
            gtk_list_item_set_child(cast(arguments.object(1)), expander)
        }
        connect(factory, "bind") { [weak self] (arguments: Arguments) in
            self?.bind(cast(arguments.object(1)))
        }
        connect(raw(selection), "notify::selected") { [weak self] in self?.choose() }
        connect(filter, "search-changed") { [weak self] in self?.filterChanged() }
        connect(filter, "stop-search") { [weak self] in
            guard let self else { return }
            gtk_editable_set_text(cast(filter), "")
        }
        // The arrow keys open and close the row chosen, as in GNOME's other trees, and + and - too.
        let keys = gtk_event_controller_key_new()!
        connect(keys, "key-pressed") { [weak self] (arguments: Arguments) in
            let modifiers = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
            guard let self, arguments.flags(3) & modifiers == 0 else { return }
            switch Int32(arguments.uint(1)) {
            case GDK_KEY_Right, GDK_KEY_plus, GDK_KEY_KP_Add: arguments.returns(open(true))
            case GDK_KEY_Left, GDK_KEY_minus, GDK_KEY_KP_Subtract: arguments.returns(open(false))
            default: break
            }
        }
        gtk_widget_add_controller(list, keys)
        connect(copyPath, "clicked") { [weak self] in self?.copy(\.path) }
        connect(copyValue, "clicked") { [weak self] in self?.copy(\.value) }
        openAtFirst()
    }

    isolated deinit {
        g_object_unref(raw(widget))
        g_object_unref(raw(selection))
        g_object_unref(raw(rows))
    }

    /// How many rows show now.
    var rowCount: Int { Int(g_list_model_get_n_items(cast(rows))) }

    /// The node a row shows, by its place.
    func node(at position: Int) -> Int? {
        guard let row = g_list_model_get_item(cast(rows), UInt32(position)) else { return nil }
        defer { g_object_unref(row) }
        return Self.id(of: cast(row))
    }

    /// The first rows, as the self-check reads them: each one's words, indented by its depth.
    func firstRows(_ count: Int) -> [String] {
        (0..<min(count, rowCount)).compactMap { node(at: $0) }.map {
            let node = tree.node($0)
            return String(repeating: "  ", count: node.depth) + TreeRows.words(node)
        }
    }

    /// Chooses the row at `position`, as a click does.
    func choose(at position: Int) {
        gtk_single_selection_set_selected(selection, UInt32(position))
    }

    /// Filters the rows as the field does, as the self-check does.
    func setFilter(_ text: String) {
        gtk_editable_set_text(cast(filter), text)
    }

    // MARK: - Rows

    /// The tree's rows: the root's, with each node's children made as it opens, from those
    /// `kept`. With a filter, every node kept opens at once.
    private static func rows(of tree: any ValueOutline, kept: Set<Int>?) -> OpaquePointer {
        let root = withCStrings(tree.count > 0 && kept?.isEmpty != true ? ["0"] : []) { gtk_string_list_new($0) }!
        return treeListModel(root, autoexpand: kept != nil) { item in
            let children = TreeRows.children(
                of: Int(strtol(gtk_string_object_get_string(cast(item)), nil, 10)), in: tree, kept: kept)
            guard !children.isEmpty else { return nil }
            return withCStrings(children.map(String.init)) { gtk_string_list_new($0) }
        }
    }

    /// Opens the root and its children, as ``TreeRows/opened(_:most:)`` says, without the filter.
    private func openAtFirst() {
        guard kept == nil, let root = gtk_tree_list_model_get_row(rows, 0) else { return }
        defer { g_object_unref(raw(root)) }
        gtk_tree_list_row_set_expanded(root, 1)
        let opened = Set(TreeRows.opened(tree))
        let children = tree.count > 0 ? tree.node(0).children : []
        for (position, child) in children.enumerated() where opened.contains(child) {
            if let row = gtk_tree_list_row_get_child_row(root, UInt32(position)) {
                gtk_tree_list_row_set_expanded(row, 1)
                g_object_unref(raw(row))
            }
        }
    }

    /// Opens the row chosen, or closes it; a row that's closed, or holds nothing, chooses the row
    /// above it in the tree instead. Gives whether it did either.
    @discardableResult
    func open(_ isOpening: Bool) -> Bool {
        let position = gtk_single_selection_get_selected(selection)
        guard position != Self.none, let row = gtk_tree_list_model_get_row(rows, position) else { return false }
        defer { g_object_unref(raw(row)) }
        let isOpen = gtk_tree_list_row_get_expanded(row) != 0
        if gtk_tree_list_row_is_expandable(row) != 0, isOpen != isOpening {
            gtk_tree_list_row_set_expanded(row, cBool(isOpening))
            return true
        }
        guard !isOpening, let parent = gtk_tree_list_row_get_parent(row) else { return false }
        defer { g_object_unref(raw(parent)) }
        let above = gtk_tree_list_row_get_position(parent)
        let flags = GtkListScrollFlags(rawValue: GTK_LIST_SCROLL_FOCUS.rawValue | GTK_LIST_SCROLL_SELECT.rawValue)
        gtk_list_view_scroll_to(cast(list), above, flags, nil)
        return true
    }

    /// The node of a tree row, a GtkTreeListRow.
    private static func id(of row: OpaquePointer) -> Int? {
        guard let item = gtk_tree_list_row_get_item(row) else { return nil }
        defer { g_object_unref(item) }
        return Int(strtol(gtk_string_object_get_string(cast(item)), nil, 10))
    }

    private func bind(_ item: OpaquePointer) {
        guard let row: OpaquePointer = gtk_list_item_get_item(item).map({ cast($0) }), let id = Self.id(of: row),
            let expander = gtk_list_item_get_child(item), let box = gtk_tree_expander_get_child(cast(expander)),
            let key = gtk_widget_get_first_child(box), let value = gtk_widget_get_next_sibling(key),
            let type = gtk_widget_get_next_sibling(value)
        else { return }
        gtk_tree_expander_set_list_row(cast(expander), row)
        let node = tree.node(id)
        gtk_inscription_set_text(cast(key), node.label)
        gtk_inscription_set_text(cast(value), node.summary)
        gtk_inscription_set_text(cast(type), node.typeName)
        for style in ["string", "number", "literal", "dim-label"] {
            gtk_widget_remove_css_class(value, style)
        }
        let style =
            switch node.style {
            case .string, .bytes: "string"
            case .number: "number"
            case .literal: "literal"
            case .container: "dim-label"
            }
        gtk_widget_add_css_class(value, style)
        gtk_widget_set_tooltip_text(type, node.typeName)
        gtk_list_item_set_accessible_label(item, TreeRows.words(node))
    }

    // MARK: - Filtering

    /// Works out what the filter keeps away from the window, since it looks at every node, then
    /// shows it, unless the filter changed meanwhile.
    private func filterChanged() {
        let query = string(gtk_editable_get_text(cast(filter))) ?? ""
        filtering += 1
        let filtering = filtering
        let tree = tree
        Task { [weak self] in
            let kept = await Task.detached(priority: .userInitiated) { TreeRows.kept(tree, by: query) }.value
            guard let self, self.filtering == filtering else { return }
            show(kept: kept, query: query)
        }
    }

    private func show(kept: Set<Int>?, query: String) {
        self.kept = kept
        let old = rows
        rows = Self.rows(of: tree, kept: kept)
        gtk_single_selection_set_model(selection, cast(rows))
        g_object_unref(raw(old))
        gtk_single_selection_set_selected(selection, Self.none)
        openAtFirst()
        let none = kept?.isEmpty == true
        let words = none ? "No keys or values match “\(query.trimmingCharacters(in: .whitespaces))”." : ""
        gtk_label_set_text(cast(noMatches), words)
        gtk_widget_set_visible(noMatches, cBool(none))
        gtk_widget_set_visible(scroller, cBool(!none))
    }

    // MARK: - The path

    /// Shows the chosen row's path, once the session says it, or hides the bar.
    private func choose() {
        let position = gtk_single_selection_get_selected(selection)
        guard position != Self.none, let id = node(at: Int(position)) else {
            chosen = nil
            gtk_widget_set_visible(pathBar, 0)
            return
        }
        Task { [weak self, locate] in
            let found = await locate(id)
            guard let self, let found, self.node(at: Int(gtk_single_selection_get_selected(selection))) == id else {
                return
            }
            chosen = (id, found.path, found.copyText)
            gtk_label_set_text(cast(pathLabel), found.path.isEmpty ? tree.node(id).label : found.path)
            gtk_widget_set_visible(pathBar, 1)
        }
    }

    private func copy(_ part: KeyPath<(node: Int, path: String, value: String), String>) {
        guard let chosen else { return }
        let text = chosen[keyPath: part]
        gdk_clipboard_set_text(gtk_widget_get_clipboard(widget), text)
        onCopy?(text)
    }
}
