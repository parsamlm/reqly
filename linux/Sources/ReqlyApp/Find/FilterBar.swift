import CGtk
import GtkBinding

/// The filter bar, under the search bar: the status buttons, All, 2xx to 5xx and Failed; Filters…,
/// with the App, Host and Method menus and the content types; and a token for each filter that's
/// set. It's hidden while the session is empty. The window puts ``widget`` under the search bar.
///
/// So far it's an empty bar, hidden.
@MainActor
final class FilterBar {
    /// The bar, a row of its own.
    let widget: Widget
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_widget_add_css_class(widget, "toolbar")
        gtk_widget_set_visible(widget, 0)
    }
}
