import CGtk
import GtkBinding

/// A banner for a state that lasts, such as a request a breakpoint holds, a device that waits to be
/// let in, or a rules file's or the connections' problem: an AdwBanner under a header bar. Screen
/// readers hear its words once, as it shows or as they change, rather than each time it's drawn
/// or laid out again.
@MainActor
final class Banner {
    let widget: Widget
    /// The words it shows, while it shows.
    private(set) var title: String?
    private var onButton: (@MainActor () -> Void)?

    init() {
        widget = adw_banner_new("")
        // Its words may hold a name, which isn't Pango markup.
        adw_banner_set_use_markup(cast(widget), 0)
        connect(widget, "button-clicked") { [weak self] in self?.onButton?() }
    }

    /// Whether it shows.
    var isShowing: Bool { title != nil }

    /// Shows `title`, with a button named `button`, such as Show or Review…, that runs `onButton`,
    /// or none. Screen readers hear `title` as it shows, and again only once it has changed.
    func show(_ title: String, button: String? = nil, onButton: (@MainActor () -> Void)? = nil) {
        self.onButton = onButton
        adw_banner_set_button_label(cast(widget), button)
        guard title != self.title else { return }
        self.title = title
        adw_banner_set_title(cast(widget), title)
        adw_banner_set_revealed(cast(widget), 1)
        announce(widget, title)
    }

    /// Hides it. Shown again, it's heard again.
    func hide() {
        guard title != nil else { return }
        title = nil
        onButton = nil
        adw_banner_set_revealed(cast(widget), 0)
    }
}
