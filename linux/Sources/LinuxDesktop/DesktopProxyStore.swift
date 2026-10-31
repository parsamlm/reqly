import Foundation
import ReqlyModel

/// Your desktop's proxy settings, as the system keeps them: GNOME's in GSettings, on every
/// desktop that has them, and KDE's in `kioslaverc`, on KDE or wherever the file is. Changing them
/// needs no administrator rights. Test runs use ``FileProxySettings`` over the same settings
/// instead, so they never touch dconf or `kioslaverc`.
public struct DesktopProxyStore: ProxySettingsStore {
    /// GNOME's part, or `nil` to leave it alone.
    public var gnome: GNOMEProxyStore?
    public var kde: KDEProxyStore
    public var desktop: SessionDesktop

    public init(gnome: GNOMEProxyStore?, kde: KDEProxyStore, desktop: SessionDesktop) {
        self.gnome = gnome
        self.kde = kde
        self.desktop = desktop
    }

    /// The stores for `environment`, such as the process's own: its desktop and its folders.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            gnome: GNOMEProxyStore(), kde: KDEProxyStore(environment: environment),
            desktop: SessionDesktop(currentDesktop: environment["XDG_CURRENT_DESKTOP"]))
    }

    /// Whether KDE's part counts: on KDE, or wherever `kioslaverc` is, since KDE's apps can run
    /// on other desktops.
    public var usesKDE: Bool { desktop.isKDE || kde.fileExists }

    public func read() throws -> DesktopProxySettings {
        DesktopProxySettings(gnome: try gnome?.read(), kde: usesKDE ? try kde.read() : nil)
    }

    /// Changes each part there is in `settings`, only the keys that differ. If KDE's part fails,
    /// GNOME's goes back as it was, so the two never disagree about whether Reqly captures.
    public func write(_ settings: DesktopProxySettings) throws {
        var gnomeBefore: GNOMEProxy?
        if let wanted = settings.gnome, let gnome {
            gnomeBefore = try gnome.read()
            try gnome.write(wanted)
        }
        guard let wanted = settings.kde else { return }
        do {
            try kde.write(wanted)
        } catch {
            if let gnomeBefore {
                try? gnome?.write(gnomeBefore)
            }
            throw error
        }
    }
}

/// Test runs' stand-in for your desktop's settings: the same settings in a JSON file, so a run
/// with `-setsSystemProxy NO` never touches dconf or `kioslaverc`.
public typealias DesktopProxyStandIn = FileProxySettings<DesktopProxySettings>
