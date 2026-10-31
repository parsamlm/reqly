import LinuxDesktop

/// Which parts of your desktop's proxy setting Reqly points at itself: GNOME's, which it sets on
/// every desktop that has it, since Firefox reads it everywhere, and KDE's, on KDE.
struct ProxyParts: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let gnome = ProxyParts(rawValue: 1 << 0)
    static let kde = ProxyParts(rawValue: 1 << 1)

    /// The parts `settings` has, or with `port`, only the ones that point at Reqly on that port.
    init(_ settings: DesktopProxySettings, pointingAtReqlyOn port: Int? = nil) {
        var parts: ProxyParts = []
        if let gnome = settings.gnome, port.map(gnome.pointsAtReqly(port:)) ?? true {
            parts.insert(.gnome)
        }
        if let kde = settings.kde, port.map(kde.pointsAtReqly(port:)) ?? true {
            parts.insert(.kde)
        }
        self = parts
    }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The desktops they're for, as the status line names them, or `nil` for none.
    var desktops: String? {
        switch (contains(.gnome), contains(.kde)) {
        case (true, true): "GNOME and KDE"
        case (true, false): "GNOME"
        case (false, true): "KDE"
        case (false, false): nil
        }
    }

    /// The settings themselves, as Settings › General names them, or `nil` for none.
    var settings: String? {
        switch (contains(.gnome), contains(.kde)) {
        case (true, true): "GNOME's and KDE's proxy settings"
        case (true, false): "GNOME's proxy setting"
        case (false, true): "KDE's proxy setting"
        case (false, false): nil
        }
    }
}

/// Whose proxy setting Chrome reads on the desktop you're logged in to, and with it Chromium,
/// Edge, Brave and Electron apps: GNOME's on GNOME and the desktops that use its settings, KDE's on
/// KDE, and none on the others, such as Xfce and LXQt, where they read only the proxy variables,
/// as they start. Chrome goes by the first name it knows in `XDG_CURRENT_DESKTOP`.
enum ChromeProxySetting: Equatable, Sendable {
    case gnome, kde, none

    init(currentDesktop: String?) {
        for name in (currentDesktop ?? "").split(separator: ":") {
            switch name.uppercased() {
            // MATE isn't a name Chrome knows, but MATE's DESKTOP_SESSION is, which Chrome reads next.
            case "GNOME", "UNITY", "X-CINNAMON", "PANTHEON", "DEEPIN", "UKUI", "COSMIC", "MATE":
                self = .gnome
                return
            case "KDE":
                self = .kde
                return
            case "XFCE", "LXQT":
                self = .none
                return
            default:
                continue
            }
        }
        self = .none
    }

    /// Whether Chrome follows the setting while Reqly has `parts` of it.
    func follows(_ parts: ProxyParts) -> Bool {
        switch self {
        case .gnome: parts.contains(.gnome)
        case .kde: parts.contains(.kde)
        case .none: false
        }
    }
}

/// What the status line says about capturing: the port, which desktop's proxy setting points at
/// Reqly, and what you may need to do for apps to follow it, or why capturing didn't start or
/// stop.
struct CaptureStatus: Equatable {
    var capture: AppModel.Capture
    var port: Int
    /// Why capturing didn't start or stop, as the session says.
    var problem: String?
    /// The parts of your desktop's proxy setting that point at Reqly while it captures, none when
    /// the run leaves your setting alone.
    var proxySet: ProxyParts
    var chrome: ChromeProxySetting
    /// Once capturing has stopped, the terminals whose tabs took GNOME's setting while Reqly
    /// captured, such as GNOME Terminal.
    var terminalsKeepingProxy: [String]

    /// Terminals that set the proxy variables in each new tab by themselves while GNOME's setting
    /// is manual, by program and name: GNOME Terminal and Ptyxis, as measured, and GNOME Console,
    /// whose code reads GNOME's setting for each tab the same way. Konsole and xterm don't.
    static let terminalsFollowingGNOME: [(program: String, name: String)] = [
        ("gnome-terminal", "GNOME Terminal"), ("ptyxis", "Ptyxis"), ("kgx", "GNOME Console"),
    ]

    var text: String {
        if let problem {
            return problem
        }
        switch capture {
        case .starting:
            return "Starting…"
        case .stopping:
            return "Stopping…"
        case .capturing:
            guard let desktops = proxySet.desktops else {
                return "Capturing on port \(port) · Desktop proxy not set"
            }
            var parts = ["Capturing on port \(port)", "Proxy set for \(desktops)"]
            if !chrome.follows(proxySet) {
                parts.append("Restart apps you opened earlier, or start them from Open Terminal")
            } else if proxySet.contains(.gnome) {
                parts.append(
                    "Apps keep connections they already had open, so restart Firefox to capture all of its traffic")
            }
            return parts.joined(separator: " · ")
        case .stopped:
            var parts = ["Not capturing", "Port \(port)"]
            if let terminals = Self.list(terminalsKeepingProxy) {
                parts.append("\(terminals) tabs opened while capturing still point at Reqly, so open a new tab")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Names as a sentence lists them: "A", "A and B", "A, B and C".
    private static func list(_ names: [String]) -> String? {
        guard let last = names.last else { return nil }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }
}
