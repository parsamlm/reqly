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

    /// Yours, for each part still pointing at Reqly, and these settings for the others, which you
    /// changed since. `nil` when no part points at Reqly.
    public func restoring(_ yours: DesktopProxySettings, port: Int) -> DesktopProxySettings? {
        guard pointsAtReqly(port: port) else { return nil }
        var restored = self
        if gnome?.pointsAtReqly(port: port) == true {
            restored.gnome = yours.gnome
        }
        if kde?.pointsAtReqly(port: port) == true {
            restored.kde = yours.kde
        }
        return restored
    }
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
/// leaves the others, such as `ignore-hosts` and SOCKS's, as you set them.
public struct GNOMEProxy: Codable, Hashable, Sendable {
    /// `none`, `manual` or `auto`.
    public var mode: GSettingsValue<String>
    public var httpHost: GSettingsValue<String>
    public var httpPort: GSettingsValue<Int>
    public var httpsHost: GSettingsValue<String>
    public var httpsPort: GSettingsValue<Int>

    /// The settings as GNOME installs them, with no values of your own.
    public init(
        mode: GSettingsValue<String> = GSettingsValue("none", isDefault: true),
        httpHost: GSettingsValue<String> = GSettingsValue("", isDefault: true),
        httpPort: GSettingsValue<Int> = GSettingsValue(8080, isDefault: true),
        httpsHost: GSettingsValue<String> = GSettingsValue("", isDefault: true),
        httpsPort: GSettingsValue<Int> = GSettingsValue(0, isDefault: true)
    ) {
        self.mode = mode
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.httpsHost = httpsHost
        self.httpsPort = httpsPort
    }

    /// The host Reqly sets: itself, on this computer.
    public static let reqlyHost = "127.0.0.1"

    /// These settings while Reqly captures on `port`: HTTP and HTTPS through Reqly, in manual mode.
    public func capturing(port: Int) -> GNOMEProxy {
        GNOMEProxy(
            mode: .set("manual"), httpHost: .set(Self.reqlyHost), httpPort: .set(port),
            httpsHost: .set(Self.reqlyHost), httpsPort: .set(port))
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
    /// Whether `kioslaverc` was there. Putting back settings from before it was removes the file,
    /// as long as nothing else has been added to it.
    public var fileExists: Bool
    /// `0` for no proxy, `1` for manual, and others for a setup script, automatic detection and
    /// environment variables.
    public var proxyType: String?
    /// The proxy for HTTP, as a URL, a space and the port, such as `http://127.0.0.1 9090`.
    public var httpProxy: String?
    public var httpsProxy: String?

    public init(fileExists: Bool, proxyType: String? = nil, httpProxy: String? = nil, httpsProxy: String? = nil) {
        self.fileExists = fileExists
        self.proxyType = proxyType
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
    }

    /// The proxy Reqly sets for `port`, as KDE writes it, with a space before the port.
    public static func reqlyProxy(port: Int) -> String { "http://127.0.0.1 \(port)" }

    /// These settings while Reqly captures on `port`: manual, with HTTP and HTTPS through Reqly.
    public func capturing(port: Int) -> KDEProxy {
        KDEProxy(
            fileExists: fileExists, proxyType: "1", httpProxy: Self.reqlyProxy(port: port),
            httpsProxy: Self.reqlyProxy(port: port))
    }

    /// Whether manual mode sends HTTP and HTTPS to Reqly on `port`. A colon before the port counts
    /// too, which KDE also reads.
    public func pointsAtReqly(port: Int) -> Bool {
        let reqly: Set = [Self.reqlyProxy(port: port), "http://127.0.0.1:\(port)"]
        return proxyType == "1" && reqly.contains(httpProxy ?? "") && reqly.contains(httpsProxy ?? "")
    }
}
