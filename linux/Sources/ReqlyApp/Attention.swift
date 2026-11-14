import CGtk
import CoreInterface
import Foundation
import GtkBinding
import Presentation
import ReqlyModel

/// What needs you, though nothing in Reqly answers it for you: a request or a response a
/// breakpoint holds, which holds up its app, or a device on the network that waits to be let in.
/// GTK 4 has no urgency hint, and GNOME doesn't bring a window forward that asks without your
/// say, so Reqly says it where you are: see ``AttentionWay``.
struct Attention: Equatable, Sendable {
    enum Subject: Equatable, Sendable {
        /// What a breakpoint holds: a request, by its method and URL, or a response, by its status
        /// and reason.
        case paused(ExchangeID, breakpoint: String, message: String)
        case deviceWaiting(id: String, address: String)
    }

    var subject: Subject

    /// What a breakpoint holds, with the words its edit gives.
    init(paused id: ExchangeID, _ edit: PausedEdit) {
        let message =
            switch edit.original {
            case .request: [edit.method, edit.url].filter { !$0.isEmpty }.joined(separator: " ")
            case .response: [edit.status, edit.reason].filter { !$0.isEmpty }.joined(separator: " ")
            }
        subject = .paused(id, breakpoint: edit.breakpoint, message: message)
    }

    /// A device that waits.
    init(deviceWaiting id: String, address: String) {
        subject = .deviceWaiting(id: id, address: address)
    }

    init(_ subject: Subject) {
        self.subject = subject
    }

    /// The notification's ID, which takes the place of the one before about the same, and goes
    /// once it's answered.
    var id: String {
        switch subject {
        case .paused(let id, _, _): "paused-\(id.rawValue)"
        case .deviceWaiting(let id, _): "device-\(id)"
        }
    }

    /// What the toast and the notification's title say.
    var title: String {
        switch subject {
        case .paused(_, let breakpoint, _): "Request paused by breakpoint “\(breakpoint)”"
        case .deviceWaiting: "A device wants to use Reqly"
        }
    }

    /// What the notification says under its title.
    var body: String {
        switch subject {
        case .paused(_, _, let message) where !message.isEmpty: "\(message) waits until you continue it."
        case .paused: "It waits until you continue it."
        case .deviceWaiting(_, let address):
            "A device at \(address) wants to send its traffic through Reqly. Allow it only if it's yours."
        }
    }

    /// The toast's button, which shows the request, or the question, in the live window.
    var button: String {
        switch subject {
        case .paused: "Show"
        case .deviceWaiting: "Review…"
        }
    }
}

/// How Reqly gets your attention: a notification while no Reqly window is active, as when you're
/// in another app; a toast in the Reqly window that's active, when it doesn't show what needs you;
/// or nothing, when the window that's active shows it already, as the live window does with its
/// banner.
enum AttentionWay: Equatable, Sendable {
    case notification, toast, nothing

    /// The way for where the keyboard's focus is: in no Reqly window, `nil`, or in one that
    /// shows what needs you, or doesn't.
    static func choose(activeWindowShowsIt: Bool?) -> AttentionWay {
        switch activeWindowShowsIt {
        case nil: .notification
        case true?: .nothing
        case false?: .toast
        }
    }
}

/// A window that may show what needs you itself, such as a composer whose request a breakpoint
/// holds, which shows the paused editor, or Devices, which shows the device that waits: there's no
/// toast in it then.
@MainActor
protocol ShowsAttention: AnyObject {
    func shows(_ attention: Attention) -> Bool
}

extension App {
    /// Follows what needs you in the app's model, as breakpoints hold requests and devices ask:
    /// each new one gets your attention, once, and its notification goes once it's answered, or
    /// gone. The notifications' actions show the request or the question in the live window.
    func followAttention() {
        addAttentionActions()
        model.observe { [weak self] in self?.attentionChanged() }
    }

    /// What needs you now, from the app's model.
    private var needsYou: [Attention] {
        model.paused.map { Attention(paused: $0.id, $0.edit) }
            + (model.waitingDevice.map { [Attention(deviceWaiting: $0.id, address: $0.address)] } ?? [])
    }

    private func attentionChanged() {
        let now = needsYou
        let ids = Set(now.map(\.id))
        for gone in attended.subtracting(ids) {
            withdrawNotification(gone)
        }
        for attention in now where !attended.contains(attention.id) {
            getAttention(attention, activeWindow: activeReqlyWindow)
        }
        attended = ids
    }

    /// The Reqly window the keyboard's focus is in, or `nil` while it's in none, as when you're in
    /// another app.
    var activeReqlyWindow: Widget? {
        let windows = [liveWindow?.window].compactMap { $0 } + fileWindows.map(\.window) + secondaries.map(\.window)
        return windows.first { gtk_window_is_active(cast($0)) != 0 }
    }

    /// Gets your attention for `attention`, as ``AttentionWay`` says for `activeWindow`, the Reqly
    /// window that's active, or none. Says which way it took, for the self-check.
    @discardableResult
    func getAttention(_ attention: Attention, activeWindow: Widget?) -> AttentionWay {
        let showsIt = activeWindow.map { active -> Bool in
            if active == liveWindow?.window {
                return true
            }
            let secondary = secondaries.first { $0.window == active }
            return (secondary as? ShowsAttention)?.shows(attention) ?? false
        }
        let way = AttentionWay.choose(activeWindowShowsIt: showsIt)
        switch way {
        case .notification:
            sendNotification(attention)
        case .toast:
            guard let active = activeWindow else { break }
            let show: @MainActor () -> Void = { [weak self] in self?.show(attention) }
            if let window = fileWindows.first(where: { $0.window == active }) {
                window.toast(attention.title, button: attention.button, isUrgent: true, onButton: show)
            } else {
                DetailsBlocks.toast(
                    attention.title, from: windowContent(active), button: attention.button, isUrgent: true,
                    onButton: show)
            }
        case .nothing:
            break
        }
        return way
    }

    /// A window's content, which is in its toast overlay, or is it.
    private func windowContent(_ window: Widget) -> Widget {
        let content: Widget? =
            if g_type_check_instance_is_a(cast(window), adw_application_window_get_type()) != 0 {
                adw_application_window_get_content(cast(window))
            } else if g_type_check_instance_is_a(cast(window), adw_window_get_type()) != 0 {
                adw_window_get_content(cast(window))
            } else {
                nil
            }
        return content ?? window
    }

    /// Shows what needs you, in the live window, presented first: the request, or the question.
    func show(_ attention: Attention) {
        let window = presentLive()
        switch attention.subject {
        case .paused(let id, _, _): window.showPaused(id)
        case .deviceWaiting: window.reviewWaitingDevice()
        }
    }

    // MARK: - Notifications

    /// The notification for `attention`, whose default action shows it. A test run, which has no
    /// notification server, writes what it would notify to its log instead: GLib warns when it
    /// can't send one, and the self-check fails on GLib's warnings.
    func sendNotification(_ attention: Attention) {
        if options.isTestRun {
            AppLog.write("notification: \(attention.title). \(attention.body)")
            notified.append(attention)
            return
        }
        let notification = g_notification_new(attention.title)!
        defer { g_object_unref(raw(notification)) }
        g_notification_set_body(notification, attention.body)
        switch attention.subject {
        case .paused(let id, _, _):
            g_notification_set_priority(notification, G_NOTIFICATION_PRIORITY_HIGH)
            g_notification_set_default_action_and_target_value(
                notification, "app.show-paused", g_variant_new_uint64(guint64(id.rawValue)))
        case .deviceWaiting(let id, _):
            g_notification_set_default_action_and_target_value(
                notification, "app.review-device", g_variant_new_string(id))
        }
        g_application_send_notification(cast(application), attention.id, notification)
        notified.append(attention)
    }

    private func withdrawNotification(_ id: String) {
        guard notified.contains(where: { $0.id == id }) else { return }
        notified.removeAll { $0.id == id }
        if !options.isTestRun {
            g_application_withdraw_notification(cast(application), id)
        }
    }

    /// The notifications' actions: `app.show-paused`, with the request's ID, and
    /// `app.review-device`, with the device's.
    private func addAttentionActions() {
        let addAction: (String, String, @escaping @MainActor (OpaquePointer) -> Void) -> Void = { name, type, body in
            let variantType = g_variant_type_new(type)
            let action = g_simple_action_new(name, variantType)!
            g_variant_type_free(variantType)
            connect(action, "activate") { (arguments: Arguments) in
                if let parameter = arguments.variant(1) {
                    body(parameter)
                }
            }
            g_action_map_add_action(cast(self.application), cast(action))
            g_object_unref(raw(action))
        }
        addAction("show-paused", "t") { [weak self] parameter in
            let id = ExchangeID(rawValue: UInt64(g_variant_get_uint64(parameter)))
            guard let self, let held = model.paused.first(where: { $0.id == id }) else {
                self?.presentLive()
                return
            }
            show(Attention(paused: held.id, held.edit))
        }
        addAction("review-device", "s") { [weak self] parameter in
            let id = string(g_variant_get_string(parameter, nil)) ?? ""
            guard let self else { return }
            show(Attention(deviceWaiting: id, address: model.waitingDevice?.address ?? ""))
        }
    }
}
