/// What a cgroup's name says about the app in it. systemd names a unit for each app a desktop
/// starts, and every process the app starts stays in it, so a socket's cgroup names its app
/// without reading the process.
public struct SystemdUnit: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// An app's own unit, named after the desktop entry it was started from:
        /// `app-gnome-<desktop ID>-<pid>.scope` from GNOME Shell or an autostart entry,
        /// `app-<desktop ID>@<random>.service` or `app-<desktop ID>-<pid>.scope` from KDE.
        case app(desktopID: String)
        /// A Flatpak's unit, `app-flatpak-<app ID>-<pid>.scope`.
        case flatpak(appID: String)
        /// A snap's unit, `snap.<snap>.<app>-<uuid>.scope`.
        case snap(name: String, app: String)
        /// A command run in a terminal, such as curl: GNOME Terminal's `vte-spawn-<uuid>.scope`,
        /// Ptyxis's `ptyxis-spawn-<uuid>.scope`, or Konsole's `app-org.kde.konsole@<uuid>.service`.
        /// The terminal's desktop ID, when the name says it.
        case terminal(desktopID: String?)
        /// A service, such as `packagekit.service`, the system's or your user's.
        case service(String)
        /// A unit whose name doesn't say which app: a login's `session-<n>.scope`, which also
        /// holds what's started from it, or D-Bus's `dbus.service`, which holds the apps it
        /// starts.
        case other
    }

    /// The unit's name, the last part of the cgroup's path, as systemd escapes it.
    public var name: String
    public var kind: Kind
    /// The process the unit was made for, when its name says, as `app-gnome-<id>-<pid>.scope`'s
    /// does.
    public var pid: Int32?

    /// Desktop IDs of terminals, whose units hold the commands you run in them. Terminals whose
    /// desktop entries Reqly finds are known by their TerminalEmulator category too.
    public static let terminals: Set<String> = [
        "org.gnome.Terminal", "org.gnome.Ptyxis", "org.gnome.Console", "org.kde.konsole", "org.kde.yakuake",
        "xterm", "debian-xterm", "debian-uxterm", "uxterm", "com.gexperts.Tilix", "terminator",
        "xfce4-terminal", "org.xfce.terminal", "mate-terminal", "lxterminal", "qterminal",
        "io.elementary.terminal", "kitty", "Alacritty", "org.wezfurlong.wezterm", "com.mitchellh.ghostty",
        "foot", "footclient", "org.codeberg.dnkl.foot", "guake", "tilda", "terminology", "cool-retro-term",
    ]

    /// The unit of the cgroup at `path`, such as
    /// `/user.slice/user-1000.slice/user@1000.service/app.slice/snap.firefox.firefox-<uuid>.scope`.
    public init(cgroupPath path: String) {
        let parts = path.split(separator: "/").map(String.init)
        name = parts.last ?? ""
        (kind, pid) = Self.read(parts)
    }

    public init(name: String, kind: Kind, pid: Int32? = nil) {
        self.name = name
        self.kind = kind
        self.pid = pid
    }

    /// The desktop ID of the app the unit is for: an app's, a Flatpak's app ID, or a snap's
    /// `<snap>_<app>`, the name snapd gives its desktop entries.
    public var desktopID: String? {
        switch kind {
        case .app(let id), .flatpak(let id): id
        case .snap(let name, let app): "\(name)_\(app)"
        case .terminal, .service, .other: nil
        }
    }

    private static func read(_ parts: [String]) -> (Kind, Int32?) {
        guard let leaf = parts.last else { return (.other, nil) }
        if leaf.hasPrefix("vte-spawn-"), leaf.hasSuffix(".scope") {
            return (.terminal(desktopID: slicedApp(parts.dropLast())), nil)
        }
        if leaf.hasPrefix("ptyxis-spawn-"), leaf.hasSuffix(".scope") {
            return (.terminal(desktopID: "org.gnome.Ptyxis"), nil)
        }
        // A command started as a GNOME Terminal window opens can make its connection before VTE
        // moves it into its own scope.
        if leaf == "gnome-terminal-server.service" {
            return (.terminal(desktopID: "org.gnome.Terminal"), nil)
        }
        if leaf.hasPrefix("snap."), let snap = snap(leaf) {
            return (.snap(name: snap.name, app: snap.app), nil)
        }
        if let app = app(leaf) {
            if terminals.contains(app.id) {
                return (.terminal(desktopID: app.id), nil)
            }
            return (app.launcher == "flatpak" ? .flatpak(appID: app.id) : .app(desktopID: app.id), app.pid)
        }
        if leaf == "dbus.service" || leaf == "dbus-broker.service" || leaf == "init.scope"
            || (leaf.hasPrefix("session-") && leaf.hasSuffix(".scope"))
        {
            return (.other, nil)
        }
        if leaf.hasSuffix(".service") {
            return (.service(unescape(leaf)), nil)
        }
        // A process right in an app's slice, such as app-org.gnome.Terminal.slice.
        if let id = slicedApp(parts[...]) {
            return (terminals.contains(id) ? .terminal(desktopID: id) : .app(desktopID: id), nil)
        }
        return (.other, nil)
    }

    /// The app of the nearest `app-<id>.slice` the cgroup is in.
    private static func slicedApp(_ parts: ArraySlice<String>) -> String? {
        parts.last { $0.hasPrefix("app-") && $0.hasSuffix(".slice") }.flatMap { app($0)?.id }
    }

    /// Reads systemd's names for apps' units, `app[-<launcher>]-<app ID>[@<random>].service`,
    /// `app[-<launcher>]-<app ID>-<random>.scope` and `app[-<launcher>]-<app ID>.slice`, where
    /// the parts are escaped so they hold no dashes of their own. GNOME Shell's launcher is
    /// `gnome` and Flatpak's `flatpak`; KDE's units have none. For a scope, the random part is
    /// usually the process's ID.
    static func app(_ unit: String) -> (launcher: String?, id: String, pid: Int32?)? {
        // Where D-Bus starts an app as a unit of its own, as dbus-broker does, the unit is named
        // after its bus name, which is the app's ID: `app-dbus\x2d:1.2\x2dorg.gnome.Maps@0.service`.
        if let id = dbusActivated(unit) {
            return (nil, id, nil)
        }
        guard unit.hasPrefix("app-") else { return nil }
        let kinds = [".scope", ".service", ".slice"]
        guard let kind = kinds.first(where: unit.hasSuffix) else { return nil }
        var stem = Substring(unit.dropFirst("app-".count).dropLast(kind.count))
        var pid: Int32?
        if let at = stem.firstIndex(of: "@") {
            stem = stem[..<at]
        } else if kind == ".scope" {
            // A scope always ends in a random part: a UUID, or the process's ID.
            if stem.count > 37, isUUID(stem.suffix(36)), stem.dropLast(36).hasSuffix("-") {
                stem = stem.dropLast(37)
            } else if let dash = stem.lastIndex(of: "-") {
                pid = Int32(stem[stem.index(after: dash)...])
                stem = stem[..<dash]
            } else {
                return nil
            }
        } else if kind == ".service", stem.split(separator: "-").count >= 3,
            let last = stem.split(separator: "-").last, isRandom(last)
        {
            stem = stem.dropLast(last.count + 1)
        }
        let pieces = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, !pieces.contains(where: \.isEmpty) else { return nil }
        let launcher = pieces.count >= 2 ? unescape(String(pieces[0])) : nil
        let id = unescape(pieces.dropFirst(pieces.count >= 2 ? 1 : 0).joined(separator: "-"))
        return (launcher, id, pid)
    }

    /// The bus name in `dbus-:1.2-org.gnome.Maps@0.service`, with or without `app-` before it.
    private static func dbusActivated(_ unit: String) -> String? {
        var name = unescape(unit)
        if name.hasPrefix("app-") {
            name.removeFirst("app-".count)
        }
        guard name.hasPrefix("dbus-:"), name.hasSuffix(".service"), let at = name.firstIndex(of: "@") else {
            return nil
        }
        // The connection's own name, such as `:1.2`, then the bus name.
        let connection = name.dropFirst("dbus-".count)
        guard let dash = connection.firstIndex(of: "-"), dash < at else { return nil }
        let id = name[name.index(after: dash)..<at]
        return id.isEmpty ? nil : String(id)
    }

    /// Reads a snap's unit, `snap.<snap>.<app>-<uuid>.scope`, or `snap.<snap>.<app>.service` for
    /// its services. Older snapd put a dot and 32 digits in place of the dash and the UUID.
    static func snap(_ unit: String) -> (name: String, app: String)? {
        guard let kind = [".scope", ".service"].first(where: unit.hasSuffix) else { return nil }
        var stem = unit.dropFirst("snap.".count).dropLast(kind.count)
        if stem.count > 37, isUUID(stem.suffix(36)), stem.dropLast(36).hasSuffix("-") {
            stem = stem.dropLast(37)
        } else if stem.count > 33, stem.suffix(32).allSatisfy(\.isHexDigit), stem.dropLast(32).hasSuffix(".") {
            stem = stem.dropLast(33)
        }
        guard let dot = stem.firstIndex(of: ".") else { return nil }
        let name = stem[..<dot]
        let app = stem[stem.index(after: dot)...]
        guard !name.isEmpty, !app.isEmpty else { return nil }
        return (unescape(String(name)), unescape(String(app)))
    }

    /// Turns systemd's escapes, such as `\x2d` for a dash, back into what they stand for.
    public static func unescape(_ text: String) -> String {
        guard text.contains("\\x") else { return text }
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\"), index + 3 < bytes.count, bytes[index + 1] == UInt8(ascii: "x"),
                let value = UInt8(String(decoding: bytes[index + 2...index + 3], as: UTF8.self), radix: 16)
            {
                result.append(value)
                index += 4
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Whether the text is a UUID with dashes, such as `e53afeb0-6c09-4570-bfe0-099d25593b6f`.
    private static func isUUID(_ text: Substring) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    /// Whether a part of a unit's name looks made up to keep it apart from others: hexadecimal
    /// digits, such as a process's ID or part of a UUID.
    private static func isRandom(_ text: Substring) -> Bool {
        text.count >= 4 && text.allSatisfy(\.isHexDigit)
    }
}
