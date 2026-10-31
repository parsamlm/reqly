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

    /// What to write to put `yours` back, when these are the settings in place and Reqly pointed
    /// yours at itself on `port`, or `nil` to leave these as they are. Settings made of parts that
    /// apps read apart, such as GNOME's and KDE's on Linux, can put back only the parts still
    /// pointing at Reqly. Others put back all or nothing, as ``pointsAtReqly(port:)`` says.
    func restoring(_ yours: Self, port: Int) -> Self?
}

extension UserProxySettings {
    /// Yours, while these are still Reqly's settings for `port`; otherwise `nil`.
    public func restoring(_ yours: Self, port: Int) -> Self? {
        pointsAtReqly(port: port) ? yours : nil
    }
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
        // On the disk before your settings change, so a power cut right after can't lose them.
        try FileReplacement.writeDurably(JSONEncoder().encode(Kept(yours: yours, port: port)), to: restoreFile)
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

    /// Puts your settings back if the ones in place are still Reqly's, or the parts of them that
    /// are, then forgets them. Returns whether it put any back.
    public static func restoreLeftBehind(settings: Store, restoreFile: URL) throws -> Bool {
        guard let data = try? Data(contentsOf: restoreFile), let kept = try? JSONDecoder().decode(Kept.self, from: data)
        else { return false }
        let restored = try settings.read().restoring(kept.yours, port: kept.port)
        if let restored {
            try settings.write(restored)
        }
        try? FileManager.default.removeItem(at: restoreFile)
        return restored != nil
    }

    /// What the restore file holds: your settings, and the port Reqly pointed them at. A file
    /// that an earlier version of Reqly left holds the same, so it still puts your settings back.
    struct Kept: Codable {
        var yours: Store.Settings
        var port: Int
    }
}
