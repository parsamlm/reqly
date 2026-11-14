import CGtk
import CoreInterface
import GtkBinding
import ReqlyModel

// The Messages page, a WebSocket's messages, between Response and Raw, with Ctrl+6, which shows
// only for a WebSocket's request: see ``DetailsPane/has(_:)``. It shows nothing yet, and is
// filled in with the page.

extension DetailsPane {
    /// What the Messages page shows of `details`: the page is built again only when it changes.
    func messagesContent(_ details: ExchangeDetails) -> ExchangeID {
        details.exchange.id
    }

    /// Builds the Messages page in `box`, for what ``messagesContent(_:)`` gave.
    func buildMessages(_ id: ExchangeID, _ box: Widget) {}
}
