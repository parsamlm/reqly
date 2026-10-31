import CGio

/// A GLib error, such as GSettings' or D-Bus', as a Swift one.
public struct GLibError: Error, Hashable, CustomStringConvertible {
    public var message: String

    public var description: String { message }

    /// The error GLib returned in `error`, which this frees.
    static func taking(_ error: UnsafeMutablePointer<GError>?, or fallback: String) -> GLibError {
        guard let error else { return GLibError(message: fallback) }
        defer { g_error_free(error) }
        return GLibError(message: error.pointee.message.map { String(cString: $0) } ?? fallback)
    }
}

/// Your login session's D-Bus, through GDBus. Each call can block, so each runs off the main
/// thread, with a time limit.
enum SessionBus {
    /// How long a call may take.
    static let timeLimit = 5.0

    /// Sends a signal with one string to every app listening, such as KDE's
    /// `reparseSlaveConfiguration`.
    static func emit(path: String, interface: String, member: String, string: String) throws {
        try TimeLimit.run("D-Bus signal \(member)", seconds: timeLimit) {
            let connection = try Self.connection()
            defer { g_object_unref(UnsafeMutableRawPointer(connection)) }
            var error: UnsafeMutablePointer<GError>?
            var child = g_variant_new_string(string)
            let sent = withUnsafePointer(to: &child) { children in
                g_dbus_connection_emit_signal(
                    connection, nil, path, interface, member, g_variant_new_tuple(children, 1), &error)
            }
            guard sent != 0 else { throw GLibError.taking(error, or: "couldn't send \(member)") }
            // Signals wait in a queue; this sends it before the call returns.
            guard g_dbus_connection_flush_sync(connection, nil, &error) != 0 else {
                throw GLibError.taking(error, or: "couldn't send \(member)")
            }
        }
    }

    /// Whether an app on the session bus has `name`, such as a running Reqly's
    /// `net.reqly.Reqly`.
    static func nameHasOwner(_ name: String) throws -> Bool {
        try TimeLimit.run("D-Bus NameHasOwner", seconds: timeLimit) {
            let connection = try Self.connection()
            defer { g_object_unref(UnsafeMutableRawPointer(connection)) }
            var error: UnsafeMutablePointer<GError>?
            var child = g_variant_new_string(name)
            let reply = withUnsafePointer(to: &child) { children in
                g_dbus_connection_call_sync(
                    connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", g_variant_new_tuple(children, 1), nil, G_DBUS_CALL_FLAGS_NONE,
                    Int32(timeLimit * 1000), nil, &error)
            }
            guard let reply else { throw GLibError.taking(error, or: "couldn't ask D-Bus about \(name)") }
            defer { g_variant_unref(reply) }
            guard let answer = g_variant_get_child_value(reply, 0) else {
                throw GLibError(message: "D-Bus didn't say whether \(name) is taken")
            }
            defer { g_variant_unref(answer) }
            return g_variant_get_boolean(answer) != 0
        }
    }

    /// The session bus's shared connection, with a reference for the caller.
    private static func connection() throws -> OpaquePointer {
        var error: UnsafeMutablePointer<GError>?
        guard let connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error) else {
            throw GLibError.taking(error, or: "there's no session bus")
        }
        return connection
    }
}
