import CGio
import CGtk
import Foundation
import GtkBinding

/// Reqly as a client of your session manager: gnome-session, or Cinnamon's, which shares its
/// interface. As you log out, the session manager asks each client whether the session may end,
/// shows its confirmation, and only once you've confirmed ends the session, waiting for each
/// client's answer before your desktop goes. So Reqly keeps capturing while you're asked, a
/// logout you call off leaves it as it was, and it closes at the end, while the session manager
/// waits.
///
/// Reqly registers itself rather than through GTK: GTK 4.18 and 4.22 follow the session through
/// the portal where there's one, which answers the session's end for its apps at once, leaving
/// them no time to close, and a portal left from an earlier session, as Cinnamon's can be, still
/// says that one is ending, and never hears this one's logout.
@MainActor
final class SessionManagerClient {
    /// The session manager's name on the session bus.
    static let name = "org.gnome.SessionManager"
    private static let path = "/org/gnome/SessionManager"
    private static let clientInterface = "org.gnome.SessionManager.ClientPrivate"

    /// Runs as the session ends: Reqly closes, then quits.
    var atEnd: (@MainActor () -> Void)?
    /// Runs when the session manager tells Reqly to quit.
    var atStop: (@MainActor () -> Void)?

    private let connection: OpaquePointer
    /// Reqly's client, as the session manager named it once Reqly registered.
    private var client: String?
    private var subscription: UInt32 = 0
    /// Whether the session has ended and still wants Reqly's answer.
    private var endIsUnanswered = false

    /// A client on `connection`, the session bus's, which it keeps.
    init(connection: OpaquePointer) {
        self.connection = connection
    }

    /// Whether a session manager has its name on `connection`'s bus.
    static func isRunning(on connection: OpaquePointer) -> Bool {
        let reply = g_dbus_connection_call_sync(
            connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
            tuple([g_variant_new_string(name)]), nil, G_DBUS_CALL_FLAGS_NONE, 1000, nil, nil)
        guard let reply else { return false }
        defer { g_variant_unref(reply) }
        let answer = g_variant_get_child_value(reply, 0)
        defer { g_variant_unref(answer) }
        return g_variant_get_boolean(answer) != 0
    }

    /// Registers Reqly under `appID`, and listens to what the session manager says to its client
    /// from then on.
    func register(appID: String) {
        // An app the session manager started itself has an ID from it.
        let startupID = ProcessInfo.processInfo.environment["DESKTOP_AUTOSTART_ID"] ?? ""
        let (callback, context) = whenReady { [weak self] _, result in self?.registered(result) }
        g_dbus_connection_call(
            connection, Self.name, Self.path, Self.name, "RegisterClient",
            tuple([g_variant_new_string(appID), g_variant_new_string(startupID)]), nil, G_DBUS_CALL_FLAGS_NONE, -1,
            nil, callback, context)
    }

    /// Answers the session's end, if it came. Call it once Reqly has closed and its main loop has
    /// ended: the session manager ends the session, and the display with it, once every client
    /// has answered, and the display going while GTK still runs would end Reqly at once. The
    /// answer is sent before this returns, since Reqly ends next.
    func answerTheEnd() {
        guard endIsUnanswered else { return }
        endIsUnanswered = false
        answer()
        g_dbus_connection_flush_sync(connection, nil, nil)
    }

    private func registered(_ result: OpaquePointer?) {
        var error: UnsafeMutablePointer<GError>?
        guard let reply = g_dbus_connection_call_finish(connection, result, &error) else {
            AppLog.write("couldn't register with the session manager: \(message(error))")
            return
        }
        defer { g_variant_unref(reply) }
        let path = g_variant_get_child_value(reply, 0)
        defer { g_variant_unref(path) }
        guard let client = string(g_variant_get_string(path, nil)) else { return }
        self.client = client
        subscription = g_dbus_connection_signal_subscribe(
            connection, Self.name, Self.clientInterface, nil, client, nil, G_DBUS_SIGNAL_FLAGS_NONE, signalCall,
            Box<SignalBody>({ [weak self] signal in self?.heard(signal) }).retained(), releaseContext)
    }

    private func heard(_ signal: String) {
        switch signal {
        case "QueryEndSession":
            // Yes, at once: Reqly keeps capturing while you're asked, and closes once the session
            // ends. A client that doesn't answer within a second holds the logout up as busy.
            answer()
        case "EndSession":
            endIsUnanswered = true
            atEnd?()
        case "Stop":
            atStop?()
        default:
            // CancelEndSession: you called the logout off, and Reqly changed nothing for it.
            break
        }
    }

    /// EndSessionResponse, which answers both questions: yes, the session may end, and Reqly has
    /// done what it does as it ends.
    private func answer() {
        guard let client else { return }
        // With no callback, GDBus sends it as a call that wants no reply.
        g_dbus_connection_call(
            connection, Self.name, client, Self.clientInterface, "EndSessionResponse",
            tuple([g_variant_new_boolean(1), g_variant_new_string("")]), nil, G_DBUS_CALL_FLAGS_NONE, -1, nil, nil,
            nil)
    }
}

private typealias SignalBody = @MainActor (String) -> Void

// GDBus calls it in the main context, where Reqly subscribed.
private let signalCall: GDBusSignalCallback = { _, _, _, _, signal, _, context in
    let body = Box<SignalBody>.from(context)
    let name = string(signal) ?? ""
    MainActor.assumeIsolated { body(name) }
}

/// A tuple of GVariants, such as a call's parameters, which takes the floating children.
private func tuple(_ children: [OpaquePointer?]) -> OpaquePointer {
    children.withUnsafeBufferPointer { g_variant_new_tuple($0.baseAddress, gsize($0.count)) }
}
