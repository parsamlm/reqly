import CGio
import CGtk
import Foundation
import GtkBinding

/// The logout part's stand-in for your desktop's session manager, on a D-Bus of its own: it
/// serves what GTK asks the session manager as Reqly starts, then, as a logout does, asks whether
/// the session may end, and ends it. Each kind is what one GTK follows:
///
/// - The portal: xdg-desktop-portal's Inhibit, whose session states GTK 4.18 and later follow, as
///   on Debian 13's GNOME and Cinnamon and on Ubuntu 26.04. GTK 4.22 also wants its registry.
/// - gnome-session: its client interface, which GTK 4.14 and 4.18 follow where there's no portal,
///   as on Ubuntu 24.04. Like gnome-session as the session ends, it never answers UnregisterClient.
@MainActor
final class SessionStandIn {
    enum Kind: String {
        case portal
        case gnomeSession = "gnome-session"

        /// The name it owns on the bus.
        var name: String { self == .portal ? "org.freedesktop.portal.Desktop" : "org.gnome.SessionManager" }
    }

    let kind: Kind
    /// The client GTK registered, by its unique name on the bus, once it has.
    private(set) var client: String?
    /// When the client answered the question, in monotonic microseconds.
    private(set) var answered: Int?
    /// What `atAnswer` found as the answer came.
    private(set) var foundAtAnswer: [String] = []
    /// Whether the client has left the bus, since it registered.
    private(set) var clientLeft = false
    /// Whether the client asked to leave the session, as GTK does once the session has ended.
    private(set) var unregistered = false
    /// Runs as the answer comes, before anything else can happen, and says what isn't so yet.
    var atAnswer: (@MainActor () -> [String])?
    /// Whether it ends the session as the answer comes, before the client has left the bus, as
    /// gnome-session does once the last app has answered, and the portal once every one has.
    var endsAtAnswer = false

    private let connection: OpaquePointer
    private var objects: [UInt32] = []
    private var watch: UInt32 = 0
    /// The portal's session with the client, as GTK named it.
    private var session = ""
    private var isAsking = false

    private static let portalPath = "/org/freedesktop/portal/desktop"
    private static let clientPath = "/org/gnome/SessionManager/Client1"

    /// Connects to the bus at `address` and takes the session manager's name there, so GTK finds
    /// it as it starts.
    init(_ kind: Kind, address: String) throws {
        self.kind = kind
        var error: UnsafeMutablePointer<GError>?
        let flags = GDBusConnectionFlags(
            rawValue: G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue
                | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
        guard let connection = g_dbus_connection_new_for_address_sync(address, flags, nil, nil, &error) else {
            throw SelfCheck.Failure("the stand-in couldn't reach its bus: \(message(error))")
        }
        self.connection = connection
        guard let node = g_dbus_node_info_new_for_xml(kind == .portal ? Self.portal : Self.gnomeSession, &error)
        else {
            throw SelfCheck.Failure("the stand-in's interfaces don't parse: \(message(error))")
        }
        defer { g_dbus_node_info_unref(node) }
        let paths =
            kind == .portal
            ? [
                (Self.portalPath, "org.freedesktop.portal.Inhibit"),
                (Self.portalPath, "org.freedesktop.host.portal.Registry"),
            ]
            : [
                ("/org/gnome/SessionManager", "org.gnome.SessionManager"),
                (Self.clientPath, "org.gnome.SessionManager.ClientPrivate"),
            ]
        for (path, interface) in paths {
            let called = closure { [weak self] arguments in self?.called(arguments) }
            // Each version: Inhibit 3, with session states and QueryEndResponse, the registry 1.
            let version =
                kind == .portal
                ? closure { arguments in
                    let isInhibit = arguments.string(3) == "org.freedesktop.portal.Inhibit"
                    arguments.returns(variant: g_variant_new_uint32(isInhibit ? 3 : 1))
                } : nil
            let id = g_dbus_connection_register_object_with_closures(
                connection, path, g_dbus_node_info_lookup_interface(node, interface), called, version, nil, &error)
            guard id != 0 else {
                throw SelfCheck.Failure("the stand-in couldn't serve \(interface): \(message(error))")
            }
            objects.append(id)
        }
        let reply = g_dbus_connection_call_sync(
            connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            Self.variant("('\(kind.name)', uint32 4)"), nil, G_DBUS_CALL_FLAGS_NONE, 5000, nil, &error)
        guard let reply else { throw SelfCheck.Failure("the stand-in couldn't take \(kind.name): \(message(error))") }
        g_variant_unref(reply)
    }

    isolated deinit {
        g_object_unref(raw(connection))
    }

    /// Asks the client whether the session may end, as a logout starts.
    func askToEnd() {
        isAsking = true
        if kind == .portal {
            sendState(2)
        } else {
            emit(to: nil, Self.clientPath, "org.gnome.SessionManager.ClientPrivate", "QueryEndSession", "(uint32 0,)")
        }
    }

    /// Ends the session, as the logout goes on.
    func end() {
        if kind == .portal {
            sendState(3)
        } else {
            emit(to: nil, Self.clientPath, "org.gnome.SessionManager.ClientPrivate", "EndSession", "(uint32 0,)")
        }
    }

    /// Leaves the bus.
    func stop() {
        if watch != 0 {
            g_bus_unwatch_name(watch)
            watch = 0
        }
        for id in objects {
            g_dbus_connection_unregister_object(connection, id)
        }
        objects = []
        g_dbus_connection_close_sync(connection, nil, nil)
    }

    // MARK: - What GTK calls

    private func called(_ call: Arguments) {
        let sender = call.string(1) ?? ""
        let invocation: OpaquePointer = cast(call.object(6))
        switch call.string(4) ?? "" {
        case "CreateMonitor":
            // The window, and the options, with the token GTK names the session with.
            let options: OpaquePointer? = call.variant(5).flatMap { g_variant_get_child_value($0, 1) }
            defer { options.map { g_variant_unref($0) } }
            let token = options.flatMap { Self.string($0, "session_handle_token") } ?? "reqly"
            let escaped = sender.dropFirst().replacingOccurrences(of: ".", with: "_")
            session = "\(Self.portalPath)/session/\(escaped)/\(token)"
            reply(invocation, "(objectpath '\(Self.portalPath)/request/\(escaped)/\(token)',)")
            registered(sender)
            // As the portal does, it says the session runs.
            idle { [weak self] in
                self?.sendState(1)
                return false
            }
        case "RegisterClient":
            reply(invocation, "(objectpath '\(Self.clientPath)',)")
            registered(sender)
        case "QueryEndResponse", "EndSessionResponse":
            reply(invocation, nil)
            if isAsking, answered == nil, sender == client {
                answered = monotonicMicroseconds()
                foundAtAnswer = atAnswer?() ?? []
                if endsAtAnswer {
                    end()
                }
            }
        case "UnregisterClient":
            // Never answered: GTK's call waits until the stand-in leaves the bus.
            unregistered = true
        case "IsInhibited":
            reply(invocation, "(false,)")
        case "Inhibit":
            let cookie = kind == .portal ? "(objectpath '\(Self.portalPath)/request/reqly/inhibit',)" : "(uint32 1,)"
            reply(invocation, cookie)
        default:
            reply(invocation, nil)
        }
    }

    private func registered(_ sender: String) {
        guard client == nil else { return }
        client = sender
        watch = g_bus_watch_name_on_connection_with_closures(
            connection, sender, G_BUS_NAME_WATCHER_FLAGS_NONE, nil,
            closure { [weak self] _ in self?.clientLeft = true })
    }

    /// The portal's StateChanged, to the client alone, as the portal sends it: 1 while the session
    /// runs, 2 to ask whether it may end, 3 as it ends.
    private func sendState(_ state: UInt32) {
        guard let client else { return }
        emit(
            to: client, Self.portalPath, "org.freedesktop.portal.Inhibit", "StateChanged",
            "(objectpath '\(session)', {'screensaver-active': <false>, 'session-state': <uint32 \(state)>})")
    }

    private func emit(to destination: String?, _ path: String, _ interface: String, _ name: String, _ text: String) {
        let parameters = Self.variant(text)
        defer { g_variant_unref(parameters) }
        var error: UnsafeMutablePointer<GError>?
        if g_dbus_connection_emit_signal(connection, destination, path, interface, name, parameters, &error) == 0 {
            g_error_free(error)
        }
    }

    private func reply(_ invocation: OpaquePointer, _ text: String?) {
        let value = text.map(Self.variant)
        g_dbus_method_invocation_return_value(invocation, value)
        value.map { g_variant_unref($0) }
    }

    /// A GVariant from GLib's text for it, such as "(uint32 0,)", which the caller unrefs.
    private static func variant(_ text: String) -> OpaquePointer {
        var error: UnsafeMutablePointer<GError>?
        guard let value = g_variant_parse(nil, text, nil, nil, &error) else {
            preconditionFailure("\(text) isn't a GVariant: \(message(error))")
        }
        return value
    }

    /// The string under `key` in a dictionary of variants.
    private static func string(_ dictionary: OpaquePointer, _ key: String) -> String? {
        guard let value = g_variant_lookup_value(dictionary, key, nil) else { return nil }
        defer { g_variant_unref(value) }
        return GtkBinding.string(g_variant_get_string(value, nil))
    }

    // MARK: - The interfaces

    private static let portal = """
        <node>
          <interface name="org.freedesktop.portal.Inhibit">
            <method name="Inhibit">
              <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="a{sv}" direction="in"/>
              <arg type="o" direction="out"/>
            </method>
            <method name="CreateMonitor">
              <arg type="s" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/>
            </method>
            <method name="QueryEndResponse"><arg type="o" direction="in"/></method>
            <signal name="StateChanged"><arg type="o"/><arg type="a{sv}"/></signal>
            <property name="version" type="u" access="read"/>
          </interface>
          <interface name="org.freedesktop.host.portal.Registry">
            <method name="Register"><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/></method>
            <property name="version" type="u" access="read"/>
          </interface>
        </node>
        """

    private static let gnomeSession = """
        <node>
          <interface name="org.gnome.SessionManager">
            <method name="RegisterClient">
              <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/>
            </method>
            <method name="UnregisterClient"><arg type="o" direction="in"/></method>
            <method name="Inhibit">
              <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
              <arg type="u" direction="in"/><arg type="u" direction="out"/>
            </method>
            <method name="Uninhibit"><arg type="u" direction="in"/></method>
            <method name="IsInhibited"><arg type="u" direction="in"/><arg type="b" direction="out"/></method>
          </interface>
          <interface name="org.gnome.SessionManager.ClientPrivate">
            <method name="EndSessionResponse"><arg type="b" direction="in"/><arg type="s" direction="in"/></method>
            <signal name="Stop"/>
            <signal name="QueryEndSession"><arg type="u"/></signal>
            <signal name="EndSession"><arg type="u"/></signal>
            <signal name="CancelEndSession"/>
          </interface>
        </node>
        """
}

/// A server the logout part starts for its copy of Reqly, which says on its first line where to
/// reach it: a D-Bus of its own, or an X server of its own, which goes as a logout takes the
/// display away.
@MainActor
final class ChildServer {
    /// What it said on its first line: the bus's address, or the display's number.
    let firstLine: String
    private let process: OpaquePointer
    private let output: UnsafeMutablePointer<GDataInputStream>

    private init(process: OpaquePointer, output: UnsafeMutablePointer<GDataInputStream>, firstLine: String) {
        self.process = process
        self.output = output
        self.firstLine = firstLine
    }

    isolated deinit {
        g_subprocess_force_exit(process)
        g_object_unref(raw(output))
        g_object_unref(raw(process))
    }

    /// A D-Bus of its own in `folder`, as linux/scripts/test-bus.conf has it, which starts no
    /// services but lists the names in `activatable` as ones it could start: GTK 4.22 uses the
    /// portal only then.
    static func bus(in folder: URL, activatable: [String]) async throws -> ChildServer {
        var config = """
            <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
             "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            <busconfig>
              <type>session</type>
              <keep_umask/>
              <listen>unix:tmpdir=/tmp</listen>
              <auth>EXTERNAL</auth>
              <policy context="default">
                <allow send_destination="*" eavesdrop="true"/>
                <allow eavesdrop="true"/>
                <allow own="*"/>
              </policy>

            """
        if !activatable.isEmpty {
            let services = folder.appending(path: "services")
            try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
            for name in activatable {
                try "[D-BUS Service]\nName=\(name)\nExec=/bin/false\n".write(
                    to: services.appending(path: "\(name).service"), atomically: true, encoding: .utf8)
            }
            config += "  <servicedir>\(services.path)</servicedir>\n"
        }
        config += "</busconfig>\n"
        let file = folder.appending(path: "bus.conf")
        try config.write(to: file, atomically: true, encoding: .utf8)
        return try await start(["dbus-daemon", "--nofork", "--print-address=1", "--config-file=\(file.path)"])
    }

    /// An X server of its own, on the first display that's free.
    static func screen() async throws -> ChildServer {
        try await start(["Xvfb", "-displayfd", "1", "-nolisten", "tcp", "-screen", "0", "1024x768x24"])
    }

    /// The display, for DISPLAY.
    var display: String { ":\(firstLine)" }

    /// Ends it at once, as a logout ends the X server.
    func kill() {
        g_subprocess_send_signal(process, SIGKILL)
    }

    private static func start(_ arguments: [String]) async throws -> ChildServer {
        var error: UnsafeMutablePointer<GError>?
        let flags = GSubprocessFlags(
            rawValue: G_SUBPROCESS_FLAGS_STDOUT_PIPE.rawValue | G_SUBPROCESS_FLAGS_STDERR_SILENCE.rawValue)
        guard let process = withCStrings(arguments, { g_subprocess_newv($0, flags, &error) }) else {
            throw SelfCheck.Failure("\(arguments[0]) didn't start: \(message(error))")
        }
        let output = g_data_input_stream_new(g_subprocess_get_stdout_pipe(process))!
        let line = await withCheckedContinuation { done in
            let (callback, context) = whenReady { _, result in
                var error: UnsafeMutablePointer<GError>?
                let line = takeString(g_data_input_stream_read_line_finish_utf8(output, result, nil, &error))
                if let error {
                    g_error_free(error)
                }
                done.resume(returning: line)
            }
            g_data_input_stream_read_line_async(output, G_PRIORITY_DEFAULT, nil, callback, context)
        }
        let server = ChildServer(process: process, output: output, firstLine: line ?? "")
        guard let line, !line.isEmpty else { throw SelfCheck.Failure("\(arguments[0]) said nothing as it started") }
        return server
    }
}
