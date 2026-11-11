import CGtk
import CGtkSource
import GtkBinding

/// Code or text in GtkSourceView, for reading: line numbers in the margin, and a caret the arrow
/// keys move, which Orca follows, though nothing can be typed. It's colored from the core's own
/// tokens, as both other apps color it, with GtkSourceView's highlighter off, in Adwaita's style
/// scheme or its dark one, as the style manager is. Code keeps its lines whole and scrolls
/// sideways; plain text wraps.
///
/// On a page, ``widget`` scrolls only sideways, and the view is as tall as its text, so the page's
/// one scroller scrolls it, and keeps the caret in view as it moves. In a view of its own, such as
/// Show Whole Body's, it scrolls both ways, and lays out only the lines that show.
@MainActor
final class CodeView {
    /// The view in its scroller.
    let widget: Widget
    let view: Widget
    let buffer: UnsafeMutablePointer<GtkTextBuffer>
    private(set) var text: CodeText
    /// One tag for each color, and for punctuation, under them, which is code without a token.
    private var tags: [CodeText.Color?: UnsafeMutablePointer<GtkTextTag>] = [:]
    /// The runs colored so far, a frame's worth at a time for a long text, and whether code's
    /// punctuation is.
    private var colored = 0
    private var isPunctuated = false
    /// What's left of the text to put in the buffer, for a long one, which goes in a piece at a
    /// time so the window keeps answering.
    private var rest: Substring?
    /// Whether the text is being replaced, as the caret moves on its own.
    private var isReplacing = false

    /// So many runs color before the view shows, or fewer, as many as color within ``coloring``,
    /// since a run on a line of thousands of characters takes longer; the rest color between
    /// frames.
    private static let colorsAtOnce = 2_000
    /// How long the view colors at a time, in microseconds: about half a frame.
    private static let coloring = 8_000
    /// A long text goes into the buffer this many bytes at a time, at a line's end.
    private static let piece = 256 << 10

    /// Shows `text`. `fillsItsOwn` puts it in a scroller of its own, both ways, rather than one
    /// that's part of a page. `label` is what screen readers call it.
    init(_ text: CodeText, fillsItsOwn: Bool = false, label: String = "Body") {
        self.text = text
        let source = gtk_source_buffer_new(nil)!
        buffer = cast(source)
        gtk_text_buffer_set_enable_undo(buffer, 0)
        gtk_source_buffer_set_highlight_syntax(source, 0)
        gtk_source_buffer_set_highlight_matching_brackets(source, 0)
        view = gtk_source_view_new_with_buffer(source)
        // The view holds the buffer now.
        g_object_unref(raw(source))
        gtk_text_view_set_editable(cast(view), 0)
        gtk_text_view_set_cursor_visible(cast(view), 1)
        gtk_text_view_set_accepts_tab(cast(view), 0)
        gtk_text_view_set_monospace(cast(view), 1)
        gtk_text_view_set_wrap_mode(cast(view), text.wraps ? GTK_WRAP_WORD_CHAR : GTK_WRAP_NONE)
        gtk_text_view_set_top_margin(cast(view), 8)
        gtk_text_view_set_bottom_margin(cast(view), 8)
        gtk_text_view_set_left_margin(cast(view), 8)
        gtk_text_view_set_right_margin(cast(view), 8)
        gtk_source_view_set_show_line_numbers(cast(view), 1)
        setAccessibleLabel(view, label)

        widget = namedScroller(label)
        g_object_ref_sink(raw(widget))
        gtk_scrolled_window_set_child(cast(widget), view)
        gtk_widget_add_css_class(widget, "card")
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        if fillsItsOwn {
            gtk_scrolled_window_set_policy(
                cast(widget), text.wraps ? GTK_POLICY_NEVER : GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
            gtk_widget_set_vexpand(widget, 1)
        } else {
            // As tall as the text: the page scrolls it down, and it scrolls only sideways.
            gtk_scrolled_window_set_policy(
                cast(widget), text.wraps ? GTK_POLICY_NEVER : GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
            gtk_scrolled_window_set_propagate_natural_height(cast(widget), 1)
        }

        for color in [nil] + CodeText.Color.allCases {
            let tag = gtk_text_tag_new(nil)!
            gtk_text_tag_table_add(gtk_text_buffer_get_tag_table(buffer), tag)
            g_object_unref(raw(tag))
            tags[color] = tag
        }
        restyle()
        let manager = adw_style_manager_get_default()
        connect(raw(manager), "notify::dark", whileAlive: raw(buffer)) { [weak self] in self?.restyle() }
        connect(raw(manager), "notify::high-contrast", whileAlive: raw(buffer)) { [weak self] in self?.restyle() }
        if !fillsItsOwn {
            connect(raw(buffer), "notify::cursor-position") { [weak self] in self?.keepCaretInView() }
        }
        fill()
    }

    isolated deinit {
        g_object_unref(raw(widget))
    }

    /// Whether the whole text is in the buffer and colored.
    var isFilled: Bool { rest == nil && colored == text.runs.count }

    /// The buffer's text, as the self-check reads it.
    var shownText: String {
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        return takeString(gtk_text_buffer_get_text(buffer, &start, &end, 1)) ?? ""
    }

    /// The color the character at `offset` shows in, as the self-check reads it: one of code's,
    /// or "punctuation", or "plain" for text with no color of its own.
    func color(at offset: Int) -> String {
        var place = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &place, Int32(offset))
        // Tags made later win, so the last color made that's there is the one that shows.
        for color in CodeText.Color.allCases.reversed() {
            if let tag = tags[color], gtk_text_iter_has_tag(&place, tag) != 0 {
                return "\(color)"
            }
        }
        if let tag = tags[nil], gtk_text_iter_has_tag(&place, tag) != 0 {
            return "punctuation"
        }
        return "plain"
    }

    /// What a color's tag shows now, such as `#AE4F18`, as the self-check reads it, or
    /// punctuation's for `nil`.
    func shade(of color: CodeText.Color?) -> String {
        guard let tag = tags[color] else { return "" }
        var value = GValue()
        g_value_init(&value, gdk_rgba_get_type())
        defer { g_value_unset(&value) }
        g_object_get_property(cast(tag), "foreground-rgba", &value)
        guard let rgba = g_value_get_boxed(&value)?.assumingMemoryBound(to: GdkRGBA.self).pointee else { return "" }
        let parts = [rgba.red, rgba.green, rgba.blue].map { String(format: "%02X", Int(($0 * 255).rounded())) }
        return "#" + parts.joined()
    }

    // MARK: - Filling it

    /// Shows `text` in place of the text it shows, in the same view, so the keyboard's focus stays
    /// in it, and the caret too, or at the end of a shorter text, as a body grows. The page stays
    /// where it was scrolled to.
    func replace(with text: CodeText) {
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &caret, gtk_text_buffer_get_insert(buffer))
        let offset = Int(gtk_text_iter_get_offset(&caret))
        self.text = text
        colored = 0
        isPunctuated = false
        gtk_text_view_set_wrap_mode(cast(view), text.wraps ? GTK_WRAP_WORD_CHAR : GTK_WRAP_NONE)
        var horizontal = GTK_POLICY_NEVER
        var vertical = GTK_POLICY_NEVER
        gtk_scrolled_window_get_policy(cast(widget), &horizontal, &vertical)
        gtk_scrolled_window_set_policy(cast(widget), text.wraps ? GTK_POLICY_NEVER : GTK_POLICY_AUTOMATIC, vertical)
        isReplacing = true
        fill(caret: offset)
        isReplacing = false
    }

    /// Puts the text in the buffer, all at once for a short one, then colors it. The caret goes at
    /// `caret`, or the end of what's in the buffer.
    private func fill(caret: Int = 0) {
        let all = Substring(text.text)
        if all.utf8.count <= Self.piece {
            rest = nil
            gtk_text_buffer_set_text(buffer, text.text, Int32(all.utf8.count))
            placeCaret(at: caret)
            colorSome(Self.colorsAtOnce, within: Self.coloring)
            finishSoon()
            return
        }
        if rest == nil {
            idle(priority: G_PRIORITY_DEFAULT_IDLE) { [weak self] in self?.insertPiece() ?? false }
        }
        gtk_text_buffer_set_text(buffer, "", 0)
        rest = all
        // The first piece shows at once; the rest follow between frames.
        _ = insertPiece()
        placeCaret(at: caret)
    }

    /// Puts the next piece of the text at the buffer's end. Gives whether there's more.
    private func insertPiece() -> Bool {
        guard let rest else { return false }
        var cut = rest.utf8.index(rest.utf8.startIndex, offsetBy: min(Self.piece, rest.utf8.count))
        if cut < rest.utf8.endIndex, let lineEnd = rest.utf8[cut...].firstIndex(of: 0x0A) {
            cut = rest.utf8.index(after: lineEnd)
        } else if cut < rest.utf8.endIndex {
            cut = rest.utf8.endIndex
        }
        var piece = String(rest[..<cut])
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        piece.withUTF8 { bytes in
            bytes.withMemoryRebound(to: CChar.self) {
                gtk_text_buffer_insert(buffer, &end, $0.baseAddress, Int32($0.count))
            }
        }
        self.rest = cut < rest.endIndex ? rest[cut...] : nil
        guard self.rest == nil else { return true }
        finishSoon()
        return false
    }

    /// Colors code's punctuation, then what's left of its runs between frames.
    private func finishSoon() {
        colorSome(0, within: 0)
        guard colored < text.runs.count else { return }
        idle(priority: G_PRIORITY_DEFAULT_IDLE) { [weak self] in
            guard let self else { return false }
            colorSome(text.runs.count, within: Self.coloring)
            return colored < text.runs.count
        }
    }

    /// Colors code's punctuation, then up to `count` more runs of the text in the buffer, 64 at a
    /// time, for up to `microseconds`.
    private func colorSome(_ count: Int, within microseconds: Int) {
        var start = GtkTextIter()
        var end = GtkTextIter()
        if !isPunctuated, text.isCode, let punctuation = tags[nil] {
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            gtk_text_buffer_apply_tag(buffer, punctuation, &start, &end)
        }
        isPunctuated = true
        let last = min(text.runs.count, colored + count)
        let deadline = monotonicMicroseconds() + microseconds
        while colored < last, monotonicMicroseconds() < deadline {
            let batch = min(last, colored + 64)
            while colored < batch {
                let run = text.runs[colored]
                gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(run.start))
                gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(run.end))
                if let tag = tags[run.color] {
                    gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
                }
                colored += 1
            }
        }
    }

    private func placeCaret(at offset: Int) {
        var place = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &place, Int32(clamping: offset))
        gtk_text_buffer_place_cursor(buffer, &place)
    }

    // MARK: - Its look

    /// The tags' colors and the style scheme, for the style manager's style now.
    private func restyle() {
        let look = BodyStyles.Look.now
        for (color, tag) in tags {
            set(raw(tag), "foreground", .string(BodyStyles.css(color, look)))
        }
        let manager = gtk_source_style_scheme_manager_get_default()
        if let scheme = gtk_source_style_scheme_manager_get_scheme(manager, look.isDark ? "Adwaita-dark" : "Adwaita") {
            gtk_source_buffer_set_style_scheme(cast(buffer), scheme)
        }
    }

    // MARK: - The caret

    /// Scrolls the page so the caret shows, as it moves with the keys: the view is as tall as its
    /// text, so its own scrolling never has to, and the page's scroller doesn't know where the
    /// caret is.
    private func keepCaretInView() {
        guard !isReplacing, gtk_widget_has_focus(view) != 0, let page = Self.pageScroller(above: widget) else {
            return
        }
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &caret, gtk_text_buffer_get_insert(buffer))
        var place = GdkRectangle()
        gtk_text_view_get_iter_location(cast(view), &caret, &place)
        var x: Int32 = 0
        var y: Int32 = 0
        gtk_text_view_buffer_to_window_coords(cast(view), GTK_TEXT_WINDOW_WIDGET, place.x, place.y, &x, &y)
        var point = graphene_point_t(x: Float(x), y: Float(y))
        var found = graphene_point_t()
        // Where the caret is in the page's scroller, which shows from 0 to its height.
        guard gtk_widget_compute_point(view, page, &point, &found) != 0 else { return }
        let adjustment = gtk_scrolled_window_get_vadjustment(cast(page))
        let value = gtk_adjustment_get_value(adjustment)
        let height = Double(gtk_widget_get_height(page))
        // A line's room above and below it, where there's room.
        let margin = Double(place.height)
        let caretTop = Double(found.y)
        let caretBottom = caretTop + Double(place.height)
        if caretTop - margin < 0 {
            gtk_adjustment_set_value(adjustment, value + caretTop - margin)
        } else if caretBottom + margin > height {
            gtk_adjustment_set_value(adjustment, value + caretBottom + margin - height)
        }
    }

    /// The scroller that scrolls a page down, above `widget`: the first that scrolls up and down.
    static func pageScroller(above widget: Widget) -> Widget? {
        var current = gtk_widget_get_parent(widget)
        while let found = current.flatMap({ gtk_widget_get_ancestor($0, gtk_scrolled_window_get_type()) }) {
            var horizontal = GTK_POLICY_NEVER
            var vertical = GTK_POLICY_NEVER
            gtk_scrolled_window_get_policy(cast(found), &horizontal, &vertical)
            if vertical != GTK_POLICY_NEVER {
                return found
            }
            current = gtk_widget_get_parent(found)
        }
        return nil
    }
}
