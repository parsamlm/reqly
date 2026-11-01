import ReqlyModel

/// Your user's proxy settings for the local network, as Windows' Internet Options keeps them.
/// Apps follow them, through WinINet and WinHTTP. The core's ``UserProxySwitch`` points them at
/// Reqly.
public struct ProxySettings: UserProxySettings, Hashable {
    /// Which ways to connect are on, as WinINet's `PROXY_TYPE_` flags.
    public var flags: UInt32
    /// The proxy server, such as `proxy:8080`, or one per protocol: `http=…;https=…`.
    public var server: String?
    /// The addresses that don't go through the proxy, such as `<local>`.
    public var bypass: String?
    /// The setup script's address, kept even while the script is off.
    public var setupScript: String?

    public static let direct: UInt32 = 0x1
    public static let usesProxy: UInt32 = 0x2
    public static let usesSetupScript: UInt32 = 0x4
    public static let detectsAutomatically: UInt32 = 0x8

    public init(flags: UInt32 = direct, server: String? = nil, bypass: String? = nil, setupScript: String? = nil) {
        self.flags = flags
        self.server = server
        self.bypass = bypass
        self.setupScript = setupScript
    }

    /// Windows' first settings: direct, with no proxy.
    public static var noProxy: ProxySettings { ProxySettings() }

    /// The proxy server Reqly sets while capturing on `port`.
    public static func reqlyServer(port: Int) -> String {
        "http=127.0.0.1:\(port);https=127.0.0.1:\(port)"
    }

    /// These settings while Reqly captures on `port`: HTTP and HTTPS go through Reqly. Everything
    /// else stays as you set it, including the addresses to bypass, as on the Mac.
    public func capturing(port: Int) -> ProxySettings {
        var settings = self
        settings.flags |= Self.usesProxy
        settings.server = Self.reqlyServer(port: port)
        return settings
    }

    /// Whether these are Reqly's settings for `port`.
    public func pointsAtReqly(port: Int) -> Bool {
        flags & Self.usesProxy != 0 && server == Self.reqlyServer(port: port)
    }
}
