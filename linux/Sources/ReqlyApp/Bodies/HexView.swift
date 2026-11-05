import CGtk
import CGtkShim
import Foundation
import GtkBinding

/// A body's bytes as hex, a line a row, as ``HexLines`` lays them out: 16 bytes a line, or 8 when
/// 16 don't fit the view's width, and narrower still, the lines scroll sideways rather than lose
/// their text, as on the Mac. Each line is a row of text that Orca reads as it is, and Tab
/// stops once on the list, where the arrow keys move from line to line and Shift chooses more of
/// them, as in any list. The bytes come from the session a page at a time, as lines show, so a
/// body of any size costs no more than the lines in view. Under the list: what's chosen, the
/// body's size, and Copy as Hex, which copies the lines chosen, or the body's first megabyte.
@MainActor
final class HexView {
    /// The list in its scroller, and the line under it.
    let widget: Widget
    let list: Widget
    let scroller: Widget
    /// How many bytes each line shows now.
    private(set) var perLine = HexLines.wide
    /// The body's size, in bytes.
    let size: Int
    /// How many pages the session has been asked for, as the self-check counts them.
    private(set) var pagesRead = 0
    /// Runs once Copy as Hex has copied, with what it copied, so the page can say so.
    var onCopy: ((String) -> Void)?

    /// A page of bytes, as the session gives them.
    static let pageSize = 64 << 10
    /// At most this many pages stay, the ones nearest the lines in view.
    private static let pagesKept = 32

    private let numbers: OpaquePointer
    private let selection: OpaquePointer
    private let selected: Widget
    private let read: @MainActor (_ offset: Int, _ limit: Int) async -> Data?
    private var pages: [Int: Data] = [:]
    private var reading: Set<Int> = []
    /// Each row's list item that shows a line now, and its line.
    private var bound: [OpaquePointer: Int] = [:]
    /// Whether the lines will fit themselves to the list's new width.
    private var isFitting = false

    /// Shows `size` bytes, which `read` gives a page at a time: up to `limit` bytes from
    /// `offset`.
    init(size: Int, read: @escaping @MainActor (_ offset: Int, _ limit: Int) async -> Data?) {
        self.size = size
        self.read = read
        // The selection takes the numbers, and the list the selection and its factory; this keeps
        // the numbers and the selection too.
        numbers = cast(reqly_numbers_new(UInt32(HexLines.count(size: size, perLine: perLine))))
        g_object_ref(raw(numbers))
        selection = cast(gtk_multi_selection_new(cast(numbers)))
        g_object_ref(raw(selection))
        let factory = gtk_signal_list_item_factory_new()!
        list = gtk_list_view_new(cast(selection), factory)
        gtk_list_view_set_tab_behavior(cast(list), GTK_LIST_TAB_ITEM)
        setAccessibleLabel(list, "Hex, \(BodyWords.bytes(size))")
        scroller = namedScroller("Hex")
        gtk_scrolled_window_set_child(cast(scroller), list)
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
        gtk_scrolled_window_set_max_content_height(cast(scroller), 480)
        gtk_widget_add_css_class(scroller, "card")
        gtk_widget_set_overflow(scroller, GTK_OVERFLOW_HIDDEN)

        selected = gtk_label_new(nil)
        gtk_label_set_xalign(cast(selected), 0)
        gtk_widget_set_hexpand(selected, 1)
        gtk_label_set_ellipsize(cast(selected), PANGO_ELLIPSIZE_END)
        let total = gtk_label_new(BodyWords.bytes(size))!
        for label in [selected, total] {
            gtk_widget_add_css_class(label, "dim-label")
            gtk_widget_add_css_class(label, "caption")
            gtk_widget_add_css_class(label, "numeric")
        }
        let copy = gtk_button_new_with_label("Copy as Hex")!
        gtk_widget_add_css_class(copy, "flat")
        let line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        for child in [selected, total, copy] {
            gtk_box_append(cast(line), child)
        }
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
        g_object_ref_sink(raw(widget))
        gtk_box_append(cast(widget), scroller)
        gtk_box_append(cast(widget), line)

        connect(factory, "setup") { (arguments: Arguments) in
            let line = gtk_inscription_new(nil)!
            gtk_widget_add_css_class(line, "monospace")
            gtk_inscription_set_min_lines(cast(line), 1)
            gtk_widget_set_margin_start(line, 10)
            gtk_widget_set_margin_end(line, 10)
            gtk_list_item_set_child(cast(arguments.object(1)), line)
        }
        connect(factory, "bind") { [weak self] (arguments: Arguments) in
            self?.bind(cast(arguments.object(1)))
        }
        connect(factory, "unbind") { [weak self] (arguments: Arguments) in
            self?.bound[cast(arguments.object(1))] = nil
        }
        connect(raw(selection), "selection-changed") { [weak self] in self?.showSelection() }
        connect(copy, "clicked") { [weak self] in self?.copySelection() }
        // Ctrl+C in the list copies too.
        let shortcuts = gtk_shortcut_controller_new()!
        let trigger = gtk_shortcut_trigger_parse_string("<Control>c")
        let copyKeys: @MainActor () -> Void = { [weak self] in self?.copySelection() }
        let action = gtk_callback_action_new(Self.copyCall, Box(copyKeys).retained(), releaseContext)
        gtk_shortcut_controller_add_shortcut(cast(shortcuts), gtk_shortcut_new(trigger, action))
        gtk_widget_add_controller(list, shortcuts)
        // The width the lines have, which their bytes follow, once the list is laid out: rows made
        // while it's laid out would have no room yet.
        let adjustment = gtk_scrolled_window_get_hadjustment(cast(scroller))
        connect(raw(adjustment), "notify::page-size") { [weak self] in
            guard let self, !isFitting else { return }
            isFitting = true
            idle { [weak self] in
                self?.isFitting = false
                self?.fitLines()
                return false
            }
        }
    }

    isolated deinit {
        g_object_unref(raw(widget))
        g_object_unref(raw(selection))
        g_object_unref(raw(numbers))
    }

    private static let copyCall: GtkShortcutFunc = { _, _, context in
        let copy = Box<@MainActor () -> Void>.from(context)
        MainActor.assumeIsolated { copy() }
        return 1
    }

    /// Whether a page the lines need is on its way.
    var isReading: Bool { !reading.isEmpty }

    /// The lines that show now, as their rows say them.
    var shownLines: [String] {
        bound.sorted { $0.value < $1.value }.compactMap { item, _ in
            gtk_list_item_get_child(item).flatMap { string(gtk_inscription_get_text(cast($0))) }
        }
    }

    // MARK: - Lines

    private func bind(_ item: OpaquePointer) {
        guard let number = gtk_list_item_get_item(item) else { return }
        let index = Int(strtol(gtk_string_object_get_string(cast(number)), nil, 10))
        bound[item] = index
        fill(item, index)
    }

    /// A row's line, from its page, or its offset alone until the page comes.
    private func fill(_ item: OpaquePointer, _ index: Int) {
        guard let row = gtk_list_item_get_child(item) else { return }
        let start = index * perLine
        let page = start / Self.pageSize
        // As wide as a whole line, so a narrow list scrolls sideways.
        let characters = UInt32(HexLines.width(perLine: perLine, size: size))
        gtk_inscription_set_min_chars(cast(row), characters)
        gtk_inscription_set_nat_chars(cast(row), characters)
        let text: String
        if let bytes = pages[page] {
            let from = bytes.startIndex + min(start - page * Self.pageSize, bytes.count)
            let line = bytes[from..<min(from + perLine, bytes.endIndex)]
            text = HexLines.line(at: start, line, perLine: perLine, size: size)
        } else {
            text = HexLines.line(at: start, [UInt8](), perLine: perLine, size: size)
            fetch(page)
        }
        gtk_inscription_set_text(cast(row), text)
        gtk_list_item_set_accessible_label(item, text)
    }

    /// Asks the session for a page, once, and shows its lines as it comes.
    private func fetch(_ page: Int) {
        guard !reading.contains(page) else { return }
        reading.insert(page)
        pagesRead += 1
        Task { [weak self, read] in
            let bytes = await read(page * Self.pageSize, Self.pageSize)
            guard let self else { return }
            reading.remove(page)
            guard let bytes else { return }
            pages[page] = bytes
            forget()
            for (item, index) in bound where index * perLine / Self.pageSize == page {
                fill(item, index)
            }
        }
    }

    /// Lets go of the pages farthest from the lines in view.
    private func forget() {
        guard pages.count > Self.pagesKept, let shown = bound.values.min() else { return }
        let here = shown * perLine / Self.pageSize
        for page in pages.keys.sorted(by: { abs($0 - here) > abs($1 - here) }).prefix(pages.count - Self.pagesKept) {
            pages[page] = nil
        }
    }

    /// 16 bytes a line while they fit, and 8 when they don't, keeping the first line in view,
    /// every byte that was chosen in a line that's chosen, and the keyboard's focus on the line
    /// with the first byte of the line that had it, as every line is made again.
    private func fitLines() {
        let width = Int32(gtk_adjustment_get_page_size(gtk_scrolled_window_get_hadjustment(cast(scroller))))
        guard width > 0 else { return }
        let wanted = width >= lineWidth(HexLines.wide) ? HexLines.wide : HexLines.narrow
        guard wanted != perLine else { return }
        let first = bound.values.min() ?? 0
        let offset = first * perLine
        let focused = focusedLine.map { $0 * perLine }
        let chosen = selectedBytes
        perLine = wanted
        reqly_numbers_set_count(cast(numbers), 0)
        reqly_numbers_set_count(cast(numbers), UInt32(HexLines.count(size: size, perLine: perLine)))
        if let chosen {
            select(chosen)
        }
        idle { [weak self] in
            guard let self else { return false }
            gtk_list_view_scroll_to(cast(list), UInt32(offset / perLine), GTK_LIST_SCROLL_NONE, nil)
            // The line that had the focus went, and GTK moves the focus out of the list, so the
            // list has it again, which gives it to the line the scroll chose.
            if let focused {
                gtk_list_view_scroll_to(cast(list), UInt32(focused / perLine), GTK_LIST_SCROLL_FOCUS, nil)
                gtk_widget_grab_focus(list)
            }
            return false
        }
    }

    /// How wide a line of `perLine` bytes is, in the list's monospace text, with the row's margins.
    private func lineWidth(_ perLine: Int) -> Int32 {
        let characters = HexLines.width(perLine: perLine, size: size)
        let layout = gtk_widget_create_pango_layout(list, String(repeating: "0", count: characters))!
        defer { g_object_unref(raw(layout)) }
        let font = pango_font_description_copy(pango_context_get_font_description(pango_layout_get_context(layout)))
        defer { pango_font_description_free(font) }
        pango_font_description_set_family(font, "monospace")
        pango_layout_set_font_description(layout, font)
        var width: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, nil)
        // The row's margins, and room for the scrollbar.
        return width + 20 + 12
    }

    /// The line whose row has the keyboard's focus, or `nil` while none has it.
    var focusedLine: Int? {
        guard let focus = gtk_widget_get_root(list).flatMap({ gtk_root_get_focus($0) }) else { return nil }
        return bound.first { item, _ in
            guard let row = gtk_list_item_get_child(item).flatMap({ gtk_widget_get_parent($0) }) else { return false }
            return focus == row || gtk_widget_is_ancestor(focus, row) != 0
        }?.value
    }

    // MARK: - Choosing and copying

    /// The bytes of the lines chosen, from the first to the last, or `nil` for none.
    var selectedBytes: Range<Int>? {
        let chosen = gtk_selection_model_get_selection(cast(selection))!
        defer { gtk_bitset_unref(chosen) }
        guard gtk_bitset_is_empty(chosen) == 0 else { return nil }
        let first = Int(gtk_bitset_get_minimum(chosen))
        let last = Int(gtk_bitset_get_maximum(chosen))
        return first * perLine..<min(size, (last + 1) * perLine)
    }

    /// Chooses the lines that hold `bytes`, as the self-check does, and as the lines' length
    /// changes.
    func select(_ bytes: Range<Int>) {
        let first = bytes.lowerBound / perLine
        let last = (bytes.upperBound - 1) / perLine
        gtk_selection_model_select_range(cast(selection), UInt32(first), UInt32(last - first + 1), 1)
    }

    private func showSelection() {
        gtk_label_set_text(cast(selected), selectedBytes.map { BodyWords.selected($0) } ?? "")
    }

    /// The hex of the lines chosen, or of the first megabyte, as Copy as Hex copies it.
    func hexToCopy() async -> String? {
        let bytes = selectedBytes ?? 0..<min(size, 1 << 20)
        guard let data = await read(bytes.lowerBound, bytes.count) else { return nil }
        return HexLines.hex(data)
    }

    private func copySelection() {
        Task { [weak self] in
            guard let text = await self?.hexToCopy(), let self else { return }
            gdk_clipboard_set_text(gtk_widget_get_clipboard(widget), text)
            onCopy?(text)
        }
    }
}
