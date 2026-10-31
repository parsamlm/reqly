import CGtk
import CoreInterface
import GtkBinding

/// The request list's place in the window. Until the list itself is built, it says how many
/// requests the session has, from its rows events, on a status page.
@MainActor
final class RequestList {
    let widget: Widget
    /// How many requests the session has.
    private(set) var total = 0

    init(model: AppModel) {
        widget = adw_status_page_new()
        adw_status_page_set_icon_name(cast(widget), "network-transmit-receive-symbolic")
        show()
        model.listen { [weak self] event in
            guard let self, case .rows(_, let total, _, _) = event else { return }
            self.total = total
            self.show()
        }
    }

    private func show() {
        let title =
            switch total {
            case 0: "No Requests"
            case 1: "1 Request"
            default: "\(total) Requests"
            }
        adw_status_page_set_title(cast(widget), title)
        adw_status_page_set_description(cast(widget), total == 0 ? "Turn on Capture to see what your apps send." : nil)
    }
}
