import ReqlyModel

/// Your desktop's proxy settings: GNOME's and KDE's, each kept apart, since apps read them
/// apart. Firefox reads GNOME's on every desktop, KDE's apps read KDE's, and Chrome reads the one
/// for the desktop it runs on. The core's ``UserProxySwitch`` points them at Reqly, and puts back
/// each part on its own.
public struct DesktopProxySettings: UserProxySettings, Hashable {
    /// GNOME's part, or `nil` where GNOME's settings aren't installed.
    public var gnome: GNOMEProxy?
    /// KDE's part, or `nil` away from KDE when there's no `kioslaverc`.
    public var kde: KDEProxy?

    public init(gnome: GNOMEProxy?, kde: KDEProxy?) {
        self.gnome = gnome
        self.kde = kde
    }

    /// A computer's first settings: GNOME's, all at their defaults, and no KDE part.
    public static var noProxy: DesktopProxySettings { DesktopProxySettings(gnome: GNOMEProxy(), kde: nil) }

    /// These settings while Reqly captures on `port`: each part there is points at Reqly.
    public func capturing(port: Int) -> DesktopProxySettings {
        DesktopProxySettings(gnome: gnome?.capturing(port: port), kde: kde?.capturing(port: port))
    }

    /// Whether either part points at Reqly on `port`.
    public func pointsAtReqly(port: Int) -> Bool {
        gnome?.pointsAtReqly(port: port) == true || kde?.pointsAtReqly(port: port) == true
    }

    /// Yours, key by key, wherever these are still what Reqly set while capturing on `port`, and
    /// these settings where you changed them since: see ``GNOMEProxy/restoring(_:port:)``. `nil`
    /// when nothing Reqly set is left.
    public func restoring(_ yours: DesktopProxySettings, port: Int) -> DesktopProxySettings? {
        var restored = self
        var putsBack = false
        if let mine = yours.gnome, let back = gnome?.restoring(mine, port: port) {
            restored.gnome = back
            putsBack = true
        }
        if let mine = yours.kde, let back = kde?.restoring(mine, port: port) {
            restored.kde = back
            putsBack = true
        }
        return putsBack ? restored : nil
    }
}

/// Putting back one key, or a host and its port together: yours while it's still what Reqly
/// wrote, and as it is when you changed it since, which `changed` notes. `putsBack` notes a key
/// Reqly had changed that goes back. A key Reqly's restore file doesn't know, `nil` in what Reqly
/// wrote, stays as it is.
private func restore<Value: Equatable>(
    _ current: Value, wrote: Value?, yours: Value, putsBack: inout Bool, changed: inout Bool
) -> Value {
    guard let wrote else { return current }
    guard current == wrote else {
        changed = true
        return current
    }
    if wrote != yours {
        putsBack = true
    }
    return yours
}

/// One of GNOME's settings and whether it's yours: a value you, or an app, set, or the default,
/// which putting it back resets rather than writes, so a later change to the default still reaches
/// you.
public struct GSettingsValue<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var value: Value
    /// Whether it's at its default, with no value of your own.
    public var isDefault: Bool

    public init(_ value: Value, isDefault: Bool) {
        self.value = value
        self.isDefault = isDefault
    }

    /// A value of your own.
    public static func set(_ value: Value) -> GSettingsValue { GSettingsValue(value, isDefault: false) }
}

/// GNOME's proxy setting, in GSettings' `org.gnome.system.proxy`: the keys Reqly changes. It
/// leaves the others, such as `ignore-hosts`, as you set them.
public struct GNOMEProxy: Codable, Hashable, Sendable {
    /// `none`, `manual` or `auto`.
    public var mode: GSettingsValue<String>
    public var httpHost: GSettingsValue<String>
    public var httpPort: GSettingsValue<Int>
    public var httpsHost: GSettingsValue<String>
    public var httpsPort: GSettingsValue<Int>
    /// The SOCKS and FTP proxies' hosts, which manual mode applies too, so Reqly clears ones you
    /// left behind with another mode while it captures. `nil` when not known, as in a restore
    /// file an earlier Reqly wrote, or where GNOME's settings don't have them: they're left alone.
    public var socksHost: GSettingsValue<String>?
    public var ftpHost: GSettingsValue<String>?

    /// The settings as GNOME installs them, with no values of your own.
    public init(
        mode: GSettingsValue<String> = GSettingsValue("none", isDefault: true),
        httpHost: GSettingsValue<String> = GSettingsValue("", isDefault: true),
        httpPort: GSettingsValue<Int> = GSettingsValue(8080, isDefault: true),
        httpsHost: GSettingsValue<String> = GSettingsValue("", isDefault: true),
        httpsPort: GSettingsValue<Int> = GSettingsValue(0, isDefault: true),
        socksHost: GSettingsValue<String>? = GSettingsValue("", isDefault: true),
        ftpHost: GSettingsValue<String>? = GSettingsValue("", isDefault: true)
    ) {
        self.mode = mode
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.httpsHost = httpsHost
        self.httpsPort = httpsPort
        self.socksHost = socksHost
        self.ftpHost = ftpHost
    }

    /// The host Reqly sets: itself, on this computer.
    public static let reqlyHost = "127.0.0.1"

    /// These settings while Reqly captures on `port`: HTTP and HTTPS through Reqly, in manual
    /// mode. A SOCKS or FTP proxy you left behind with another mode, which manual mode would
    /// switch on for other protocols, such as IMAP, goes to its default, no host, meanwhile.
    public func capturing(port: Int) -> GNOMEProxy {
        func cleared(_ host: GSettingsValue<String>?) -> GSettingsValue<String>? {
            guard let host, mode.value != "manual", !host.value.isEmpty else { return host }
            return GSettingsValue("", isDefault: true)
        }
        return GNOMEProxy(
            mode: .set("manual"), httpHost: .set(Self.reqlyHost), httpPort: .set(port),
            httpsHost: .set(Self.reqlyHost), httpsPort: .set(port), socksHost: cleared(socksHost),
            ftpHost: cleared(ftpHost))
    }

    /// Yours, key by key, wherever these are still what Reqly set while capturing on `port`, and
    /// these where you changed them since. HTTP and HTTPS each go back as a host and its port
    /// together, and the mode only once nothing you changed needs manual mode, so a proxy you set
    /// meanwhile keeps working, and Reqly's port never stays behind. `nil` when nothing Reqly set
    /// is left.
    public func restoring(_ yours: GNOMEProxy, port: Int) -> GNOMEProxy? {
        let wrote = yours.capturing(port: port)
        var restored = self
        var putsBack = false
        var changed = false
        (restored.httpHost, restored.httpPort) =
            restore(
                Pair(httpHost, httpPort), wrote: Pair(wrote.httpHost, wrote.httpPort),
                yours: Pair(yours.httpHost, yours.httpPort), putsBack: &putsBack, changed: &changed
            ).values
        (restored.httpsHost, restored.httpsPort) =
            restore(
                Pair(httpsHost, httpsPort), wrote: Pair(wrote.httpsHost, wrote.httpsPort),
                yours: Pair(yours.httpsHost, yours.httpsPort), putsBack: &putsBack, changed: &changed
            ).values
        if let current = socksHost {
            restored.socksHost = restore(
                current, wrote: wrote.socksHost, yours: yours.socksHost ?? current, putsBack: &putsBack,
                changed: &changed)
        }
        if let current = ftpHost {
            restored.ftpHost = restore(
                current, wrote: wrote.ftpHost, yours: yours.ftpHost ?? current, putsBack: &putsBack, changed: &changed)
        }
        if mode == wrote.mode, !changed {
            restored.mode = restore(mode, wrote: wrote.mode, yours: yours.mode, putsBack: &putsBack, changed: &changed)
        }
        return putsBack ? restored : nil
    }

    /// Whether manual mode sends HTTP and HTTPS to Reqly on `port`.
    public func pointsAtReqly(port: Int) -> Bool {
        mode.value == "manual" && httpHost.value == Self.reqlyHost && httpPort.value == port
            && httpsHost.value == Self.reqlyHost && httpsPort.value == port
    }
}

/// KDE's proxy setting, in `~/.config/kioslaverc`'s `[Proxy Settings]` group: the keys Reqly
/// changes, each `nil` when the file doesn't have it.
public struct KDEProxy: Codable, Hashable, Sendable {
    /// KDE's proxies for FTP and SOCKS, `ftpProxy` and `socksProxy`, which manual mode applies
    /// too, each `nil` when the file doesn't have it.
    public struct OtherProxies: Codable, Hashable, Sendable {
        public var ftp: String?
        public var socks: String?

        public init(ftp: String? = nil, socks: String? = nil) {
            self.ftp = ftp
            self.socks = socks
        }
    }

    /// Whether `kioslaverc` was there. Putting back settings from before it was removes the file,
    /// as long as nothing else has been added to it.
    public var fileExists: Bool
    /// `0` for no proxy, `1` for manual, and others for a setup script, automatic detection and
    /// environment variables.
    public var proxyType: String?
    /// The proxy for HTTP, as a URL, a space and the port, such as `http://127.0.0.1 9090`.
    public var httpProxy: String?
    public var httpsProxy: String?
    /// The other proxies, which Reqly clears while it captures when you left them behind with
    /// another type. `nil` when not known, as in a restore file an earlier Reqly wrote: they're
    /// left alone.
    public var others: OtherProxies?

    public init(
        fileExists: Bool, proxyType: String? = nil, httpProxy: String? = nil, httpsProxy: String? = nil,
        others: OtherProxies? = OtherProxies()
    ) {
        self.fileExists = fileExists
        self.proxyType = proxyType
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.others = others
    }

    /// The proxy Reqly sets for `port`, as KDE writes it, with a space before the port.
    public static func reqlyProxy(port: Int) -> String { "http://127.0.0.1 \(port)" }

    /// These settings while Reqly captures on `port`: manual, with HTTP and HTTPS through Reqly,
    /// and the FTP and SOCKS proxies you left behind with another type emptied meanwhile.
    public func capturing(port: Int) -> KDEProxy {
        var others = others
        if proxyType != "1" {
            others = others.map { OtherProxies(ftp: Self.cleared($0.ftp), socks: Self.cleared($0.socks)) }
        }
        return KDEProxy(
            fileExists: fileExists, proxyType: "1", httpProxy: Self.reqlyProxy(port: port),
            httpsProxy: Self.reqlyProxy(port: port), others: others)
    }

    /// A proxy that's set, emptied in its place in the file, as KDE writes one that isn't.
    private static func cleared(_ proxy: String?) -> String? {
        (proxy ?? "").isEmpty ? proxy : ""
    }

    /// Yours, key by key, wherever these are still what Reqly set while capturing on `port`, and
    /// these where you changed them since, as ``GNOMEProxy/restoring(_:port:)`` does: the type
    /// goes back only once nothing you changed needs manual. `nil` when nothing Reqly set is left.
    public func restoring(_ yours: KDEProxy, port: Int) -> KDEProxy? {
        let wrote = yours.capturing(port: port)
        var restored = self
        restored.fileExists = yours.fileExists
        var putsBack = false
        var changed = false
        for key in [\KDEProxy.httpProxy, \KDEProxy.httpsProxy] {
            // Either way of writing Reqly's proxy counts as Reqly's.
            let current = pointsAtReqly(self[keyPath: key], port: port) ? wrote[keyPath: key] : self[keyPath: key]
            restored[keyPath: key] = restore(
                current, wrote: wrote[keyPath: key], yours: yours[keyPath: key], putsBack: &putsBack,
                changed: &changed)
        }
        if let current = others {
            restored.others = restore(
                current, wrote: wrote.others, yours: yours.others ?? current, putsBack: &putsBack, changed: &changed)
        }
        if proxyType == wrote.proxyType, !changed {
            restored.proxyType = restore(
                proxyType, wrote: wrote.proxyType, yours: yours.proxyType, putsBack: &putsBack, changed: &changed)
        }
        return putsBack ? restored : nil
    }

    /// Whether `proxy` is Reqly's on `port`, written either way KDE reads.
    private func pointsAtReqly(_ proxy: String?, port: Int) -> Bool {
        [Self.reqlyProxy(port: port), "http://127.0.0.1:\(port)"].contains(proxy ?? "")
    }

    /// Whether manual mode sends HTTP and HTTPS to Reqly on `port`. A colon before the port counts
    /// too, which KDE also reads.
    public func pointsAtReqly(port: Int) -> Bool {
        let reqly: Set = [Self.reqlyProxy(port: port), "http://127.0.0.1:\(port)"]
        return proxyType == "1" && reqly.contains(httpProxy ?? "") && reqly.contains(httpsProxy ?? "")
    }
}

/// A host and its port, which go back together.
private struct Pair<Host: Equatable, Port: Equatable>: Equatable {
    var host: Host
    var port: Port

    init(_ host: Host, _ port: Port) {
        self.host = host
        self.port = port
    }

    var values: (Host, Port) { (host, port) }
}
