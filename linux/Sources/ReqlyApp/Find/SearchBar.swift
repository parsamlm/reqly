import CGtk
import Foundation
import GtkBinding

/// The search bar, under the list's header bar. Ctrl+F or the header bar's search button opens
/// it, and so does typing in the list, and it searches the list and the session's store together
/// as you type, as on the Mac: the session narrows the list at once, by the requests' addresses,
/// methods, apps, devices and comments, and from 3 characters, 150 ms after you stop, adds those
/// with the text in their headers or bodies. Escape closes it, which clears the search. The window
/// puts ``widget`` under the list's header bar, with the filter bar under it, and binds its search
/// button to it.
@MainActor
final class SearchBar {
    /// The GtkSearchBar, which shows and hides the field.
    let widget: Widget
    /// The field.
    let entry: Widget
    /// What the session searches for: the field's text, without the spaces around it.
    private(set) var query = ""
    /// Runs once the session searches for new text, and the list shows what it found so far.
    var onSearch: (() -> Void)?
    private let model: AppModel
    /// The latest search. The next one waits for it, so the session gets them in order.
    private var searching: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        entry = gtk_search_entry_new()
        gtk_search_entry_set_placeholder_text(cast(entry), "Search requests")
        setAccessibleLabel(entry, "Search requests")
        gtk_widget_set_hexpand(entry, 1)
        // At once, rather than after GTK's 150 ms: the session waits that long for its store.
        gtk_search_entry_set_search_delay(cast(entry), 0)
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(cast(clamp), 400)
        adw_clamp_set_child(cast(clamp), entry)
        widget = gtk_search_bar_new()
        gtk_search_bar_set_child(cast(widget), clamp)
        gtk_search_bar_connect_entry(cast(widget), cast(entry))
        connect(entry, "search-changed") { [weak self] in self?.searchChanged() }
    }

    /// Whether the bar shows.
    var isOpen: Bool {
        gtk_search_bar_get_search_mode(cast(widget)) != 0
    }

    /// Shows the bar, and gives its field the keyboard's focus.
    func open() {
        gtk_search_bar_set_search_mode(cast(widget), 1)
        gtk_widget_grab_focus(entry)
    }

    /// Hides the bar, which clears its field, and the search with it.
    func close() {
        gtk_search_bar_set_search_mode(cast(widget), 0)
    }

    /// Typing in `pane`, such as the list's, opens the bar, with what you typed in its field.
    func captureTyping(in pane: Widget) {
        gtk_search_bar_set_key_capture_widget(cast(widget), pane)
    }

    private func searchChanged() {
        let text = string(gtk_editable_get_text(cast(entry))) ?? ""
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query != self.query, let session = model.session else { return }
        self.query = query
        let previous = searching
        searching = Task {
            await previous?.value
            await session.setSearch(query)
            onSearch?()
        }
    }
}
