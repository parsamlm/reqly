import CGtk
import GtkBinding

/// The whole of a body too long for its page, as Show Whole Body opens it: a dialog over the
/// window, with the body in a code view that scrolls both ways, which lays out only the lines in
/// view, and Copy Body in its header bar. A line too long to lay out quickly shows in pieces,
/// wrapped, and the dialog says so. Escape closes it.
@MainActor
final class WholeBody {
    let dialog: Widget
    let code: CodeView
    /// Runs once it has closed.
    var onClosed: (() -> Void)?

    /// Shows `text` under `title`, such as "Response Body", and `summary`, such as "JSON · 2.1 MB".
    /// `copy` copies the body, as the page's Copy Body does.
    init(_ text: CodeText, title: String, summary: String, copy: @escaping @MainActor () -> Void) {
        code = CodeView(text, fillsItsOwn: true, label: title)
        gtk_widget_remove_css_class(code.widget, "card")
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(cast(header), adw_window_title_new(title, summary))
        let copyButton = gtk_button_new_from_icon_name("edit-copy-symbolic")!
        gtk_widget_set_tooltip_text(copyButton, "Copy Body")
        setAccessibleLabel(copyButton, "Copy Body")
        adw_header_bar_pack_end(cast(header), copyButton)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), header)
        if text.isSplit {
            let banner = adw_banner_new(
                "Lines over \(CodeText.longestLine.formatted()) characters show in pieces here, so they come up quickly."
            )!
            adw_banner_set_revealed(cast(banner), 1)
            adw_toolbar_view_add_top_bar(cast(toolbar), banner)
        }
        adw_toolbar_view_set_content(cast(toolbar), code.widget)
        dialog = cast(adw_dialog_new())
        g_object_ref_sink(raw(dialog))
        adw_dialog_set_title(cast(dialog), title)
        adw_dialog_set_content_width(cast(dialog), 960)
        adw_dialog_set_content_height(cast(dialog), 720)
        adw_dialog_set_child(cast(dialog), toolbar)
        connect(copyButton, "clicked") { copy() }
        connect(dialog, "closed") { [weak self] in self?.onClosed?() }
    }

    isolated deinit {
        g_object_unref(raw(dialog))
    }

    /// Shows it over the window `widget` is in, with the body's text focused.
    func present(over widget: Widget) {
        adw_dialog_present(cast(dialog), widget)
        adw_dialog_set_focus(cast(dialog), code.view)
    }

    func close() {
        adw_dialog_close(cast(dialog))
    }
}
