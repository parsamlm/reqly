import Foundation
import ReqlyModel

/// Your user's proxy settings for the local network, as Windows' Internet Options keeps them.
/// Apps follow them, through WinINet and WinHTTP.
public struct ProxySettings: Codable, Hashable, Sendable {
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

/// Where proxy settings live: Windows' own, or a stand-in in the tests.
public protocol ProxySettingsStore: Sendable {
    func read() throws -> ProxySettings
    func write(_ settings: ProxySettings) throws
}

/// Points your user's proxy at Reqly while capturing, and puts your own settings back after.
///
/// Your settings are kept in a file before they change, so they come back even if Reqly quits
/// unexpectedly: a watcher, or the next Reqly to start, finds the file and puts them back. They
/// only go back while Reqly's settings are still in place; settings you changed since stay.
/// Changing them needs no administrator rights.
public actor UserProxySwitch: SystemProxySwitch {
    private let settings: any ProxySettingsStore
    private let restoreFile: URL

    public init(settings: any ProxySettingsStore, restoreFile: URL) {
        self.settings = settings
        self.restoreFile = restoreFile
    }

    public func enable(port: Int) async throws {
        // Settings an earlier Reqly left go back first, so the ones kept are yours.
        _ = try Self.restoreLeftBehind(settings: settings, restoreFile: restoreFile)
        let yours = try settings.read()
        try FileReplacement.write(JSONEncoder().encode(Kept(yours: yours, port: port)), to: restoreFile)
        do {
            try settings.write(yours.capturing(port: port))
        } catch {
            try? FileManager.default.removeItem(at: restoreFile)
            throw error
        }
    }

    public func disable() async throws {
        _ = try Self.restoreLeftBehind(settings: settings, restoreFile: restoreFile)
    }

    /// Puts your settings back if the ones in place are still Reqly's, then forgets them.
    /// Returns whether it put them back.
    public static func restoreLeftBehind(settings: any ProxySettingsStore, restoreFile: URL) throws -> Bool {
        guard let data = try? Data(contentsOf: restoreFile), let kept = try? JSONDecoder().decode(Kept.self, from: data)
        else { return false }
        var restored = false
        if try settings.read().pointsAtReqly(port: kept.port) {
            try settings.write(kept.yours)
            restored = true
        }
        try? FileManager.default.removeItem(at: restoreFile)
        return restored
    }

    /// What the restore file holds: your settings, and the port Reqly pointed them at.
    struct Kept: Codable {
        var yours: ProxySettings
        var port: Int
    }
}
