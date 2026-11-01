import Foundation

/// Your user's proxy settings, as a system keeps them, such as Windows' Internet Options. Reqly
/// points them at itself while it captures, and knows them again afterwards.
public protocol UserProxySettings: Codable, Sendable {
    /// The settings a computer starts with: no proxy.
    static var noProxy: Self { get }

    /// These settings while Reqly captures on `port`.
    func capturing(port: Int) -> Self

    /// Whether these are Reqly's settings for `port`.
    func pointsAtReqly(port: Int) -> Bool
}

/// Where proxy settings live: the system's own, or a stand-in in the tests.
public protocol ProxySettingsStore: Sendable {
    associatedtype Settings: UserProxySettings

    func read() throws -> Settings
    func write(_ settings: Settings) throws
}

/// Points your user's proxy at Reqly while capturing, and puts your own settings back after.
///
/// Your settings are kept in a file before they change, so they come back even if Reqly quits
/// unexpectedly: a watcher, or the next Reqly to start, finds the file and puts them back. They
/// only go back while Reqly's settings are still in place; settings you changed since stay.
/// Changing them needs no administrator rights.
public actor UserProxySwitch<Store: ProxySettingsStore>: SystemProxySwitch {
    private let settings: Store
    private let restoreFile: URL

    public init(settings: Store, restoreFile: URL) {
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
    public static func restoreLeftBehind(settings: Store, restoreFile: URL) throws -> Bool {
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

    /// What the restore file holds: your settings, and the port Reqly pointed them at. A file
    /// that an earlier version of Reqly left holds the same, so it still puts your settings back.
    struct Kept: Codable {
        var yours: Store.Settings
        var port: Int
    }
}
