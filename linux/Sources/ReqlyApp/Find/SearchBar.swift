import CGtk
import GtkBinding

/// The search bar, under the list's header bar. Ctrl+F or the header bar's search button opens
/// it, and so does typing in the list, and it searches the list and the session's store together
/// as you type, as on the Mac. The window puts ``widget`` under the list's header bar, with the
/// filter bar under it, and binds its search button to it.
///
/// So far it's the bar and its field, which search nothing yet.
@MainActor
final class SearchBar {
    /// The GtkSearchBar, which shows and hides the field.
    let widget: Widget
    /// The field.
    let entry: Widget
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        entry = gtk_search_entry_new()
        gtk_search_entry_set_placeholder_text(cast(entry), "Search requests")
        setAccessibleLabel(entry, "Search requests")
        gtk_widget_set_hexpand(entry, 1)
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(cast(clamp), 400)
        adw_clamp_set_child(cast(clamp), entry)
        widget = gtk_search_bar_new()
        gtk_search_bar_set_child(cast(widget), clamp)
        gtk_search_bar_connect_entry(cast(widget), cast(entry))
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

    func close() {
        gtk_search_bar_set_search_mode(cast(widget), 0)
    }

    /// Typing in `pane`, such as the list's, opens the bar, with what you typed in its field.
    func captureTyping(in pane: Widget) {
        gtk_search_bar_set_key_capture_widget(cast(widget), pane)
    }
}
