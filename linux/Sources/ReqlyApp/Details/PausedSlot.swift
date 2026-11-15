import CGtk
import GtkBinding
import ReqlyModel

/// The paused editor, as the details pane holds it in its slot while a breakpoint holds the
/// request it shows, in the live session: the request's or the response's line, what you can
/// edit, Cancel Request and Continue. Each pane that shows the request has an editor of its own,
/// the live window's and the composer's that sent it, and each edits the one edit the app keeps
/// of it.
@MainActor
protocol PausedEditing: AnyObject {
    /// What takes the place of the pane's heading, tabs and pages.
    var widget: Widget { get }
}

extension DetailsPane {
    /// The paused editor of `id`, a request or a response a breakpoint holds in the live session,
    /// for the pane's slot, made as the pane shows it held, and let go once it goes on. None yet:
    /// it's filled in with the editor.
    func makePausedEditor(for id: ExchangeID) -> (any PausedEditing)? {
        nil
    }
}
