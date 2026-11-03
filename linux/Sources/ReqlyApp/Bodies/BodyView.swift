import CGtk
import CoreInterface
import GtkBinding
import Presentation
import ReqlyModel

/// One body of one request, as the Request and Response pages show it: a line saying what it is,
/// such as "JSON · 1.2 KB", with the switch between its modes and Copy Body; the body in the mode
/// chosen, as code, a tree, a form, a picture or hex; and footnotes when it was unpacked or cut
/// short. A page makes one for each body it shows, puts ``widget`` in its box, and hands it the
/// body as the session presents it, again as it grows.
///
/// So far it keeps the body and its mode, and shows neither.
@MainActor
final class BodyView {
    let id: ExchangeID
    let part: MessagePart
    /// The line, then the body, one under the other.
    let widget: Widget
    /// The switch between the body's modes, one button for each, one always on; or a label, when
    /// there's only one mode.
    let modeSwitch: Widget
    /// The body, as the session last presented it.
    private(set) var body: PresentedBody?
    /// The mode it shows the body in.
    private(set) var mode: BodyMode?
    /// Runs when you choose another mode, so the page can choose it for the next body like this
    /// one.
    var onMode: ((BodyMode) -> Void)?
    private let model: AppModel

    init(model: AppModel, id: ExchangeID, part: MessagePart) {
        self.model = model
        self.id = id
        self.part = part
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
        modeSwitch = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(modeSwitch, "linked")
        gtk_box_append(cast(widget), modeSwitch)
    }

    /// Shows `body`, in the mode it showed in, while the body has it, and in its first mode
    /// otherwise.
    func show(_ body: PresentedBody) {
        self.body = body
        let modes = body.body.modes
        show(mode: mode.flatMap { modes.contains($0) ? $0 : nil } ?? modes.first ?? .hex)
    }

    /// Shows the body in `mode`.
    func show(mode: BodyMode) {
        self.mode = mode
    }
}
