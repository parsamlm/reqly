import CGtk
import CoreInterface
import GtkBinding

/// The sidebar: the scopes the list can show, from the session's sidebar events, each with its
/// count: All Traffic, Pinned while something is, the apps, and the hosts. The window puts
/// ``widget`` under the sidebar's header bar, shows the chosen scope's title and count in the
/// list's header bar, and hides the sidebar once you've chosen one, when it shows over the list.
///
/// So far it has only All Traffic, the session's whole list. Choosing a scope tells the session
/// with ``SessionHost/setScope(_:)``, then the window, through ``onScope``.
///
/// The session's own value for the sidebar's rows is `CoreInterface.Sidebar` here, since this
/// type has its name.
@MainActor
final class Sidebar {
    /// A scope the list can show: its key, as the session's sidebar events name it, and what the
    /// list's header bar calls it.
    struct Scope: Equatable, Sendable {
        var key: String
        var title: String

        static let all = Scope(key: "all", title: "All Traffic")
    }

    /// The rows, in their scroller.
    let widget: Widget
    /// The rows' list, which takes the keyboard's focus.
    let view: Widget
    /// The scope the list shows.
    private(set) var scope = Scope.all
    /// How many requests the chosen scope has, before search and filters, once the session has
    /// said.
    private(set) var count: Int?
    /// Runs once you've chosen a scope, and the session shows it.
    var onScope: ((Scope) -> Void)?
    /// Runs when the chosen scope's count changes.
    var onCount: (() -> Void)?
    private let model: AppModel
    /// The rows' scope keys, as text, which the view shows.
    private let rows: OpaquePointer

    init(model: AppModel) {
        self.model = model
        rows = withCStrings([Scope.all.key]) { gtk_string_list_new($0) }
        let selection = gtk_single_selection_new(cast(rows))!
        let factory = gtk_signal_list_item_factory_new()
        connect(factory, "setup") { (arguments: Arguments) in
            let label = gtk_label_new(Scope.all.title)!
            gtk_label_set_xalign(cast(label), 0)
            gtk_list_item_set_child(cast(arguments.object(1)), label)
        }
        view = gtk_list_view_new(cast(selection), factory)
        gtk_widget_add_css_class(view, "navigation-sidebar")
        setAccessibleLabel(view, "Sidebar")
        widget = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(cast(widget), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(widget), view)
        model.listen { [weak self] event in
            switch event {
            case .sidebar(let sidebar): self?.counted(sidebar.total)
            case .counts(let total, _, _): self?.counted(total)
            default: break
            }
        }
    }

    /// Gives the keyboard's focus to the chosen row, and says whether it could.
    @discardableResult
    func focus() -> Bool {
        gtk_widget_grab_focus(view) != 0
    }

    private func counted(_ total: Int) {
        guard scope == .all, count != total else { return }
        count = total
        onCount?()
    }
}
