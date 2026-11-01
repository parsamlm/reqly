import CGio
import Foundation

/// GNOME's proxy setting, read and changed in the process through GSettings, which keeps it in
/// dconf. Apps that follow it hear about a change at once. Every call can block on D-Bus, so
/// each runs off the main thread, with a time limit.
public struct GNOMEProxyStore: Sendable {
    /// The settings' schema, which `gsettings-desktop-schemas` installs.
    public static let schema = "org.gnome.system.proxy"

    /// How long reading or writing may take.
    static let timeLimit = 10.0

    public init() {}

    /// A key an administrator has locked, so Reqly can't change it, such as
    /// `org.gnome.system.proxy.http host`.
    public struct Locked: LocalizedError, Hashable, CustomStringConvertible {
        public var keys: [String]

        public var description: String {
            "An administrator has locked your proxy settings (\(keys.joined(separator: ", ")))."
        }

        public var errorDescription: String? { description }
    }

    /// Whether GNOME's settings are installed. Without them, GSettings would end the process
    /// rather than open them.
    public static var isInstalled: Bool {
        guard let source = g_settings_schema_source_get_default() else { return false }
        return [schema, "\(schema).http", "\(schema).https"].allSatisfy { id in
            guard let found = g_settings_schema_source_lookup(source, id, 1) else { return false }
            g_settings_schema_unref(found)
            return true
        }
    }

    /// GNOME's setting, or `nil` when it isn't installed.
    public func read() throws -> GNOMEProxy? {
        guard Self.isInstalled else { return nil }
        return try TimeLimit.run("reading GNOME's proxy setting", seconds: Self.timeLimit) {
            try Self.withSettings(delayed: false) { proxy, http, https, others in
                GNOMEProxy(
                    mode: Self.string(proxy, "mode"), httpHost: Self.string(http, "host"),
                    httpPort: Self.int(http, "port"), httpsHost: Self.string(https, "host"),
                    httpsPort: Self.int(https, "port"), socksHost: others.socks.map { Self.string($0, "host") },
                    ftpHost: others.ftp.map { Self.string($0, "host") })
            }
        }
    }

    /// Changes the keys whose value, or whether they're at their default, differs from `settings`,
    /// all at once, and waits until dconf has them. Keys at their default are reset rather than
    /// written. Throws ``Locked`` and changes nothing when a key to change is locked.
    public func write(_ settings: GNOMEProxy) throws {
        guard Self.isInstalled else { return }
        try TimeLimit.run("changing GNOME's proxy setting", seconds: Self.timeLimit) {
            // Changes wait until they're applied, so apps see them together: never manual mode
            // with no host.
            try Self.withSettings(delayed: true) { proxy, http, https, others in
                var wanted = [
                    Self.change(proxy, "", "mode", settings.mode, current: Self.string(proxy, "mode")),
                    Self.change(http, ".http", "host", settings.httpHost, current: Self.string(http, "host")),
                    Self.change(http, ".http", "port", settings.httpPort, current: Self.int(http, "port")),
                    Self.change(https, ".https", "host", settings.httpsHost, current: Self.string(https, "host")),
                    Self.change(https, ".https", "port", settings.httpsPort, current: Self.int(https, "port")),
                ]
                // Settings that don't know a host, from an earlier Reqly's restore file, leave it.
                if let socks = others.socks, let host = settings.socksHost {
                    wanted.append(Self.change(socks, ".socks", "host", host, current: Self.string(socks, "host")))
                }
                if let ftp = others.ftp, let host = settings.ftpHost {
                    wanted.append(Self.change(ftp, ".ftp", "host", host, current: Self.string(ftp, "host")))
                }
                let changes = wanted.compactMap { $0 }
                let locked = changes.filter { g_settings_is_writable($0.settings, $0.key) == 0 }
                guard locked.isEmpty else {
                    g_settings_revert(proxy)
                    throw Locked(keys: locked.map(\.name))
                }
                for change in changes {
                    change.apply()
                }
                g_settings_apply(proxy)
                g_settings_sync()
            }
        }
    }

    // MARK: - GSettings

    /// One key to change: its settings object, its name, and how.
    private struct Change {
        var settings: UnsafeMutablePointer<GSettings>
        var key: String
        /// The key's full name, such as `org.gnome.system.proxy.http host`.
        var name: String
        var apply: () -> Void
    }

    /// The change that makes `key` `wanted`, or `nil` when it's that already. `child` is the
    /// settings' part of the schema's ID, such as `.http`.
    private static func change<Value>(
        _ settings: UnsafeMutablePointer<GSettings>, _ child: String, _ key: String, _ wanted: GSettingsValue<Value>,
        current: GSettingsValue<Value>
    ) -> Change? {
        guard wanted != current else { return nil }
        return Change(settings: settings, key: key, name: "\(schema)\(child) \(key)") {
            if wanted.isDefault {
                g_settings_reset(settings, key)
            } else if let text = wanted.value as? String {
                g_settings_set_string(settings, key, text)
            } else if let number = wanted.value as? Int {
                g_settings_set_int(settings, key, Int32(clamping: number))
            }
        }
    }

    /// The `socks` and `ftp` children, each `nil` where GNOME's settings don't have it.
    private struct Others {
        var socks: UnsafeMutablePointer<GSettings>?
        var ftp: UnsafeMutablePointer<GSettings>?
    }

    /// Runs `body` with the proxy settings and their `http`, `https`, `socks` and `ftp` children,
    /// in a main context of this thread's own, so GSettings' notices don't go to the app's main
    /// loop. With `delayed`, changes to all of them wait until `g_settings_apply` on the first.
    private static func withSettings<Result>(
        delayed: Bool,
        _ body: (
            _ proxy: UnsafeMutablePointer<GSettings>, _ http: UnsafeMutablePointer<GSettings>,
            _ https: UnsafeMutablePointer<GSettings>, _ others: Others
        ) throws -> Result
    ) throws -> Result {
        let context = g_main_context_new()
        g_main_context_push_thread_default(context)
        defer {
            while g_main_context_iteration(context, 0) != 0 {}
            g_main_context_pop_thread_default(context)
            g_main_context_unref(context)
        }
        guard let proxy = g_settings_new(schema) else {
            throw GLibError(message: "Reqly couldn't open GNOME's proxy settings, \(schema).")
        }
        defer { g_object_unref(proxy) }
        if delayed {
            g_settings_delay(proxy)
        }
        // Made after the delay, the children share it.
        let children = (http: g_settings_get_child(proxy, "http"), https: g_settings_get_child(proxy, "https"))
        defer {
            children.http.map { g_object_unref($0) }
            children.https.map { g_object_unref($0) }
        }
        guard let http = children.http, let https = children.https else {
            throw GLibError(message: "Reqly couldn't open GNOME's proxy settings for HTTP and HTTPS, in \(schema).")
        }
        // GSettings ends the process rather than open a child whose schema isn't installed.
        let source = g_settings_schema_source_get_default()
        func child(_ name: String) -> UnsafeMutablePointer<GSettings>? {
            guard let source, let found = g_settings_schema_source_lookup(source, "\(schema).\(name)", 1) else {
                return nil
            }
            g_settings_schema_unref(found)
            return g_settings_get_child(proxy, name)
        }
        let others = Others(socks: child("socks"), ftp: child("ftp"))
        defer {
            others.socks.map { g_object_unref($0) }
            others.ftp.map { g_object_unref($0) }
        }
        return try body(proxy, http, https, others)
    }

    /// Whether the key has a value of its own, rather than its default.
    private static func hasValue(_ settings: UnsafeMutablePointer<GSettings>, _ key: String) -> Bool {
        guard let value = g_settings_get_user_value(settings, key) else { return false }
        g_variant_unref(value)
        return true
    }

    private static func string(_ settings: UnsafeMutablePointer<GSettings>, _ key: String) -> GSettingsValue<String> {
        let text = g_settings_get_string(settings, key)
        defer { g_free(text) }
        return GSettingsValue(text.map { String(cString: $0) } ?? "", isDefault: !hasValue(settings, key))
    }

    private static func int(_ settings: UnsafeMutablePointer<GSettings>, _ key: String) -> GSettingsValue<Int> {
        GSettingsValue(Int(g_settings_get_int(settings, key)), isDefault: !hasValue(settings, key))
    }
}
