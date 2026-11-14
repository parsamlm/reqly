import CGtk
import GtkBinding

/// What the list's pane shows in the list's place while there's traffic, but the sidebar's scope,
/// the search and the filters leave none of it to show, in ``NoMatches``' words, with Clear Filters
/// while any filter is set. The window shows it, and says what Clear Filters does.
@MainActor
final class NoMatchesPage {
    /// The page, an AdwStatusPage.
    let widget: Widget
    let clearButton: Widget
    /// What the page says now.
    private(set) var words = NoMatches(query: "", filtersAreSet: false)
    /// Runs when you choose Clear Filters.
    var onClear: (() -> Void)?

    init() {
        widget = namedStatusPage("Requests")
        adw_status_page_set_icon_name(cast(widget), "edit-find-symbolic")
        clearButton = gtk_button_new_with_label("Clear Filters")
        gtk_widget_add_css_class(clearButton, "pill")
        gtk_widget_set_halign(clearButton, GTK_ALIGN_CENTER)
        adw_status_page_set_child(cast(widget), clearButton)
        connect(clearButton, "clicked") { [weak self] in self?.onClear?() }
        show(words)
    }

    func show(_ words: NoMatches) {
        self.words = words
        adw_status_page_set_title(cast(widget), words.title)
        adw_status_page_set_description(cast(widget), words.description)
        gtk_widget_set_visible(clearButton, cBool(words.clearsFilters))
    }
}
