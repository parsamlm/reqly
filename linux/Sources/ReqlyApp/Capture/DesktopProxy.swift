import AppSetup
import Foundation
import LinuxDesktop
import ReqlyModel

/// Your desktop's proxy setting as capturing changes it: which parts of it Reqly points at
/// itself, whose setting Chrome reads on your desktop, and which terminals take it into their
/// tabs. The status line and Settings › General say what it finds. A test run reads its stand-in
/// instead, and never your own setting.
@MainActor
final class DesktopProxy {
    private let options: Options
    private let restoreFile: URL
    /// The environment your desktop and your terminals are found in: the process's own, or one
    /// the self-check makes up.
    var environment: [String: String]
    /// The parts that point at Reqly while it captures, as they were once capturing started.
    private(set) var proxySet: ProxyParts = []
    /// Whether capturing stopped after pointing GNOME's setting at Reqly, until it starts again.
    private(set) var stoppedAfterSettingGNOME = false

    init(options: Options, folders: AppFolders, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.options = options
        restoreFile = folders.proxyRestoreFile
        self.environment = environment
    }

    var chrome: ChromeProxySetting {
        ChromeProxySetting(currentDesktop: environment["XDG_CURRENT_DESKTOP"])
    }

    /// The terminals installed whose tabs take GNOME's setting by themselves.
    var terminalsFollowingGNOME: [String] {
        CaptureStatus.terminalsFollowingGNOME.filter { Programs.find($0.program, in: environment["PATH"]) != nil }
            .map(\.name)
    }

    /// The parts capturing points at Reqly: GNOME's wherever its settings are installed and KDE's
    /// on KDE or wherever its file is, or the stand-in's parts. None when the run leaves your
    /// setting alone.
    var partsToChange: ProxyParts {
        guard options.setsSystemProxy else { return [] }
        if let standIn = options.proxySettingsStandIn {
            return (try? DesktopProxyStandIn(file: URL(filePath: standIn)).read()).map { ProxyParts($0) } ?? []
        }
        var parts: ProxyParts = GNOMEProxyStore.isInstalled ? .gnome : []
        if DesktopProxyStore(environment: environment).usesKDE {
            parts.insert(.kde)
        }
        return parts
    }

    /// Capturing started on `port`: reads which parts now point at Reqly.
    func captureStarted(port: Int) async {
        stoppedAfterSettingGNOME = false
        guard options.setsSystemProxy else {
            proxySet = []
            return
        }
        let standIn = options.proxySettingsStandIn
        let environment = environment
        let settings = await onOwnThread { try? Self.read(standIn: standIn, environment: environment) }
        proxySet = settings.map { ProxyParts($0, pointingAtReqlyOn: port) } ?? []
    }

    /// Capturing stopped, and your setting is back.
    func captureStopped() {
        stoppedAfterSettingGNOME = proxySet.contains(.gnome)
        proxySet = []
    }

    /// Puts back the setting a Reqly that quit unexpectedly left pointing at itself, yours or the
    /// stand-in, as Reqly opens, before anything captures, as on Windows.
    func restoreLeftBehind() async {
        guard options.setsSystemProxy else { return }
        let standIn = options.proxySettingsStandIn
        let restoreFile = restoreFile
        let environment = environment
        let restored = await onOwnThread {
            Result {
                if let standIn {
                    return try UserProxySwitch.restoreLeftBehind(
                        settings: DesktopProxyStandIn(file: URL(filePath: standIn)), restoreFile: restoreFile)
                }
                return try DesktopProxySwitch.restoreLeftBehind(
                    store: DesktopProxyStore(environment: environment),
                    guardian: ProxyGuard(restoreFile: restoreFile, environment: environment))
            }
        }
        switch restored {
        case .success(true):
            AppLog.write("put back the proxy settings a Reqly that quit unexpectedly left")
        case .success(false):
            break
        case .failure(let error):
            AppLog.write("couldn't put back the proxy settings a Reqly left: \(error)")
        }
    }

    /// Your setting, or the stand-in's.
    private nonisolated static func read(standIn: String?, environment: [String: String]) throws
        -> DesktopProxySettings
    {
        if let standIn {
            return try DesktopProxyStandIn(file: URL(filePath: standIn)).read()
        }
        return try DesktopProxyStore(environment: environment).read()
    }
}
