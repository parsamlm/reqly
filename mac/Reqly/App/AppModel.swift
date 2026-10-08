import AppKit
import Capture
import Foundation
import Observation
import ProxyEngine
import ReqlyModel
import SourceResolver
import SystemProxy
import TrafficStore
import UniformTypeIdentifiers

/// Creates the app's services once at launch and hands them to the feature models.
@Observable
final class AppModel {
    /// Where this run's traffic is kept. It's deleted when Reqly quits.
    let store: TrafficStore
    let session: CaptureSession
    let capture: CaptureModel
    let traffic: TrafficListModel
    let https: HTTPSModel
    let rules: RulesModel
    let devices: DevicesModel
    let connections: ConnectionsModel
    let simulators = SimulatorsModel()
    let emulators = EmulatorsModel()
    let composer = ComposerModel()
    let protobuf = ProtobufModel()
    let settings = SettingsNavigation()
    let updates = UpdatesModel()
    let crashes = CrashReporter()
    /// Files to open in windows of their own, such as ones double-clicked in Finder.
    var filesToOpen: [URL] = []
    /// The copies of the files open in windows. Closing a window deletes its copy; quitting
    /// deletes the ones still open.
    private var openedStores: [WeakReference<TrafficStore>] = []

    /// Reqly itself, as the app that sends the requests you compose or resend.
    static let reqly = Source(name: "Reqly", bundleID: Bundle.main.bundleIdentifier, path: Bundle.main.bundlePath)

    init() {
        let defaults = UserDefaults.standard
        // bool(forKey:) also reads launch arguments such as `-setsSystemProxy NO`, which arrive as text.
        let wantsSystemProxy =
            defaults.object(forKey: DefaultsKey.setsSystemProxy) == nil
            || defaults.bool(forKey: DefaultsKey.setsSystemProxy)
        let systemProxy = wantsSystemProxy ? SystemProxyController() : nil
        store = Self.makeStore()
        let resolver = SourceResolver()
        let directory = DeviceDirectory()
        session = CaptureSession(store: store, systemProxy: systemProxy, extraTrustedRoots: Self.trustedRoots) {
            client, proxyPort in
            // The Mac's own apps, and its simulators and emulators, connect from the Mac itself.
            if client.isLoopback {
                guard var origin = await resolver.origin(ofClientPort: client.port, proxyPort: proxyPort) else {
                    return nil
                }
                if let device = origin.device {
                    origin.device = await directory.named(device)
                }
                return origin
            }
            return await directory.origin(ofAddress: client.ip)
        }
        capture = CaptureModel(session: session, systemProxy: systemProxy)
        traffic = TrafficListModel(session: session)
        https = HTTPSModel(session: session)
        rules = RulesModel(session: session)
        devices = DevicesModel(session: session)
        connections = ConnectionsModel(session: session)
        directory.model = devices
        if defaults.bool(forKey: DefaultsKey.removeHelper) {
            // For scripts and uninstalling: remove the helper, then quit without capturing.
            Task {
                _ = try? await SystemProxyController()?.removeHelper()
                NSApp.terminate(nil)
            }
        } else if defaults.bool(forKey: DefaultsKey.startCapturingOnLaunch) {
            Task { await capture.start() }
        }
        #if DEBUG
            if let path = defaults.string(forKey: DefaultsKey.openFile) {
                filesToOpen.append(URL(filePath: path))
            }
            if let spec = defaults.string(forKey: DefaultsKey.installCertificateOn) {
                let simulators = self.simulators
                let https = self.https
                Task { await DebugLaunch.installCertificate(spec, simulators: simulators, https: https) }
            }
            if defaults.string(forKey: DefaultsKey.useReqlyOnEmulator) != nil
                || defaults.string(forKey: DefaultsKey.copyCertificateToEmulator) != nil
            {
                Task { await DebugLaunch.driveEmulators(self) }
            }
        #endif
    }
}

extension AppModel {
    /// Where sessions live: this run's, and the copies of the ones you open.
    var sessionsFolder: URL { store.directory.deletingLastPathComponent() }

    func rememberOpened(_ store: TrafficStore) {
        openedStores.removeAll { $0.value == nil }
        openedStores.append(WeakReference(store))
    }

    /// Deletes this run's traffic, and the copies of the files still open.
    func discardSessions() {
        store.discard()
        for opened in openedStores {
            opened.value?.discard()
        }
    }

    /// Names a device, in its traffic so far and from now on.
    func renameDevice(_ device: Device, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        devices.rename(device.id, to: name)
        traffic.renameDevice(device.id, to: name)
    }

    /// Sends a request from Reqly. It's recorded in the traffic being captured, like any other.
    func send(_ request: OutgoingRequest) async -> ExchangeID {
        await session.send(request, from: Self.reqly)
    }

    /// Sends a request again, as it was, and selects the new one in the list.
    func resend(_ exchange: Exchange) {
        guard let request = OutgoingRequest(resending: exchange.request, body: exchange.requestBody) else { return }
        Task {
            traffic.selection = await send(request)
        }
    }

    /// A new session in Application Support, or in the temporary folder if that fails.
    private static func makeStore() -> TrafficStore {
        let roots = sessionRoots
        for root in roots {
            if let store = try? TrafficStore.newSession(in: root, limits: sessionLimits) {
                return store
            }
        }
        fatalError("Reqly couldn't create a folder for its traffic in \(roots[0].path(percentEncoded: false)).")
    }

    /// Where sessions can go, in order. In debug builds, `-sessionsFolder path` names the only one.
    private static var sessionRoots: [URL] {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: DefaultsKey.sessionsFolder) {
                // That folder only, so a test copy leaves the sessions of the Reqly you use alone.
                return [URL(filePath: path, directoryHint: .isDirectory)]
            }
        #endif
        return [
            URL.applicationSupportDirectory.appending(path: "Reqly/Sessions", directoryHint: .isDirectory),
            URL.temporaryDirectory.appending(path: "Reqly Sessions", directoryHint: .isDirectory),
        ]
    }

    private static var sessionLimits: TrafficStore.Limits {
        #if DEBUG
            let limit = UserDefaults.standard.integer(forKey: DefaultsKey.sessionLimit)
            if limit > 0 {
                return TrafficStore.Limits(exchanges: limit)
            }
        #endif
        return TrafficStore.Limits()
    }

    /// Root certificates to trust when checking servers, on top of the ones the Mac trusts: in
    /// debug builds, the ones `-trustRoots path` names.
    private static var trustedRoots: [[UInt8]] {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: DefaultsKey.trustRoots) {
                return rootCertificates(at: path)
            }
        #endif
        return []
    }

    #if DEBUG
        /// The certificates in a PEM file, or the one in a DER file, in DER.
        private static func rootCertificates(at path: String) -> [[UInt8]] {
            guard let data = FileManager.default.contents(atPath: path) else { return [] }
            let begin = "-----BEGIN CERTIFICATE-----"
            guard let text = String(data: data, encoding: .utf8), text.contains(begin) else {
                return [[UInt8](data)]
            }
            return text.components(separatedBy: begin).dropFirst().compactMap { block in
                let base64 = block.components(separatedBy: "-----END")[0].filter { !$0.isWhitespace }
                return Data(base64Encoded: base64).map { [UInt8]($0) }
            }
        }
    #endif
}

/// Puts the Mac's proxy back before Reqly quits, and deletes the session's traffic. If putting the
/// proxy back fails, the helper still does it once it sees Reqly exit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI brings menu items up to date with the window in front when a menu opens, not
        // when a shortcut is pressed, so a shortcut such as ⇧⌘C could find its item still
        // disabled. Bringing them up to date first, as opening the menus does, keeps each
        // shortcut working.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) {
                for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                    menu.delegate?.menuNeedsUpdate?(menu)
                }
            }
            return event
        }
        Self.prepareForFirstTraffic()
        #if DEBUG
            PerfProbe.start(traffic: model.traffic)
        #endif
    }

    /// The first traffic brings the list an app's icon, a time and the status dots, and the Mac
    /// sets up what each needs the first time it's asked, which together takes tens of
    /// milliseconds while the list waits. Asking once now, off the main thread, gets that done
    /// before traffic arrives.
    private nonisolated static func prepareForFirstTraffic() {
        Task.detached(priority: .utility) {
            var rect = NSRect(x: 0, y: 0, width: 16, height: 16)
            _ = NSWorkspace.shared.icon(for: .unixExecutable).cgImage(forProposedRect: &rect, context: nil, hints: nil)
            _ = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))?
                .cgImage(forProposedRect: &rect, context: nil, hints: nil)
            // As the list's Time column shows it.
            _ = Date.now.formatted(date: .omitted, time: .standard)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.capture.isCapturing else { return .terminateNow }
        Task {
            await model.capture.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Files opened from Finder, or dropped on Reqly's icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.filesToOpen.append(contentsOf: urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
            PerfProbe.finish()
        #endif
        // Captured traffic doesn't outlive the session that captured it.
        model.discardSessions()
    }
}

/// Lets the session's lookups reach the devices model, which can only be made once the session is.
private final class DeviceDirectory {
    weak var model: DevicesModel?

    func origin(ofAddress ip: String) -> Origin? {
        model?.origin(ofAddress: ip)
    }

    func named(_ device: Device) -> Device {
        model?.named(device) ?? device
    }
}

private final class WeakReference<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object) {
        self.value = value
    }
}

/// Keys for the settings Reqly keeps in `UserDefaults`. Any of them can also be passed as a
/// launch argument, such as `-startCapturingOnLaunch YES`.
enum DefaultsKey {
    static let proxyPort = "proxyPort"
    static let startCapturingOnLaunch = "startCapturingOnLaunch"
    /// Turn off to capture only apps that are pointed at Reqly by hand.
    static let setsSystemProxy = "setsSystemProxy"
    /// Pass `-removeHelper YES` to remove Reqly's helper from macOS and quit.
    static let removeHelper = "removeHelper"
    /// The hosts on the decryption list, such as `api.weatherly.dev` or `*.weatherly.dev`.
    static let decryptedHosts = "decryptedHosts"
    /// The hosts on the list that are switched off.
    static let hostsNotDecrypted = "hostsNotDecrypted"
    /// Whether every host the list doesn't switch off is decrypted.
    static let decryptsEveryHost = "decryptsEveryHost"
    /// Pass `-rulesFile path` to keep the rules in that file instead, in debug builds only.
    static let rulesFile = "rulesFile"
    /// Whether phones and tablets on the network may connect.
    static let allowsNetworkDevices = "allowsNetworkDevices"
    /// Pass `-devicesFile path` to keep the devices you let in in that file instead, in debug builds only.
    static let devicesFile = "devicesFile"
    /// Pass `-protobufFile path` to keep the list of `.proto` files in that file instead, in debug builds only.
    static let protobufFile = "protobufFile"
    /// Pass `-connectionsFile path` to keep the proxies and client certificates in that file
    /// instead, in debug builds only.
    static let connectionsFile = "connectionsFile"
    /// Pass `-secretsFile path` to keep passwords and private keys in that file instead of the
    /// Keychain, in debug builds only.
    static let secretsFile = "secretsFile"
    /// Pass `-rootFile path` to keep Reqly's certificate in that file instead of the Keychain, in
    /// debug builds only. Reqly makes one there the first time, and counts it as trusted without
    /// asking macOS to trust it.
    static let rootFile = "rootFile"
    /// Whether Reqly has an item in the menu bar.
    static let showsMenuBarItem = "showsMenuBarItem"
    /// Whether Reqly looks for a newer version on GitHub when it opens, once a day at most.
    static let checksForUpdates = "checksForUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    /// Set once the first-run guide has opened, so it opens only once.
    static let hasSeenWelcome = "hasSeenWelcome"
    /// When Reqly last looked for reports of its own crashes.
    static let crashReportsCheckedAt = "crashReportsCheckedAt"
    /// Whether the sidebar's sections are open.
    static let sidebarShowsApps = "sidebarShowsApps"
    static let sidebarShowsDevices = "sidebarShowsDevices"
    static let sidebarShowsHosts = "sidebarShowsHosts"

    #if DEBUG
        // For checking screens without clicking, in debug builds only.
        /// `-selectRequest last` keeps the newest request selected, and `-selectRequest 3` the third.
        static let selectRequest = "selectRequest"
        /// `-inspectorTab response` opens the detail pane on that tab.
        static let inspectorTab = "inspectorTab"
        /// `-bodyMode tree` shows bodies that way when they can be.
        static let bodyMode = "bodyMode"
        /// `-filterStatus 4xx,failed` turns those status chips on.
        static let filterStatus = "filterStatus"
        /// `-filterContent json,images` filters by those kinds of content.
        static let filterContent = "filterContent"
        static let filterHost = "filterHost"
        static let filterMethod = "filterMethod"
        /// `-showFilters YES` opens the Filters popover once there's traffic.
        static let showFilters = "showFilters"
        /// `-annotate "1:pin,red;3:comment=Slow"` annotates requests by their place in the list.
        static let annotate = "annotate"
        /// `-scope pinned` opens the Pinned list.
        static let scope = "scope"
        /// `-search staging` types that into the search field.
        static let search = "search"
        /// `-clearAt 9` clears the traffic once there are that many requests.
        static let clearAt = "clearAt"
        /// `-stopCapturingAt 24` stops capturing once there are that many requests, such as for a
        /// screenshot of a finished capture.
        static let stopCapturingAt = "stopCapturingAt"
        /// `-editRequest 4` opens the fourth request in the composer, as Edit and Resend does.
        static let editRequest = "editRequest"
        /// `-sendComposed YES` sends what a composer window opens with.
        static let sendComposed = "sendComposed"
        /// `-openFile path` opens a session or HAR file, as Finder does.
        static let openFile = "openFile"
        /// `-saveSessionTo path` saves the session there once `-saveAt` requests have arrived.
        static let saveSessionTo = "saveSessionTo"
        /// `-exportHARTo path` exports the list there once `-saveAt` requests have arrived.
        static let exportHARTo = "exportHARTo"
        static let saveAt = "saveAt"
        /// `-showHARExport YES` opens the Export as HAR sheet once there's traffic.
        static let showHARExport = "showHARExport"
        /// `-showHelp YES` opens the Reqly Help window at launch.
        static let showHelp = "showHelp"
        /// `-showRules mapLocal` opens the Rules window on that kind at launch.
        static let showRules = "showRules"
        /// `-addRule block:3` opens the editor on a new rule of that kind for the third request.
        static let addRule = "addRule"
        /// `-resumePaused YES` edits each paused exchange and continues it.
        static let resumePaused = "resumePaused"
        /// `-askAboutDevice 192.168.1.23` asks whether to let that device in, as if it connected.
        static let askAboutDevice = "askAboutDevice"
        /// `-showDevices simulators` opens the Devices window on that pane at launch.
        static let showDevices = "showDevices"
        /// `-showSettings reverseProxy` opens Settings on that pane at launch: `upstreamProxy`,
        /// `reverseProxy`, `clientCertificates` or `protobuf`.
        static let showSettings = "showSettings"
        /// `-selectMessage 2` selects the second WebSocket message in the Messages tab.
        static let selectMessage = "selectMessage"
        /// `-importClientCertificate "path|password|host,host"` adds a client certificate at launch.
        static let importClientCertificate = "importClientCertificate"
        /// `-scriptExample "Log What Passes"` starts the script editor from that example.
        static let scriptExample = "scriptExample"
        /// `-tryScript YES` tries the script editor's script as soon as it opens.
        static let tryScript = "tryScript"
        /// `-showWelcome YES` opens the first-run guide at launch, without marking it seen.
        static let showWelcome = "showWelcome"
        /// `-crashReportsFolder path` looks for crash reports there, and offers the newest one at
        /// launch, whenever it was made.
        static let crashReportsFolder = "crashReportsFolder"
        /// `-showMenuBarPanel YES` opens the menu-bar item's panel in a window at launch.
        static let showMenuBarPanel = "showMenuBarPanel"
        /// `-dumpMenus path` writes the menu bar's items there as text, five seconds after launch.
        static let dumpMenus = "dumpMenus"
        /// `-auditAccessibility path` writes what VoiceOver finds in every open window there, with
        /// the problems first, six seconds after launch.
        static let auditAccessibility = "auditAccessibility"
        /// `-auditKeyboard path` presses Tab through the window in front, as someone using the
        /// keyboard alone would, and writes where the focus went, seven seconds after launch.
        static let auditKeyboard = "auditKeyboard"
        /// `-checkForUpdatesAtLaunch YES` has Sparkle look for an update as Reqly opens, without
        /// its window, in a copy built with a public key.
        static let checkForUpdatesAtLaunch = "checkForUpdatesAtLaunch"
        /// `-httpsStatus notSetUp` shows HTTPS as on a Mac without Reqly's certificate.
        static let httpsStatus = "httpsStatus"
        /// `-trustRoots path` also trusts the root certificates in that PEM or DER file when
        /// checking servers, so a test copy can reach a local HTTPS server the Mac doesn't trust.
        static let trustRoots = "trustRoots"
        /// `-installCertificateOn "UDID|path"` presses Install Certificate for that simulator once
        /// it's running and HTTPS is set up, and writes how it went to the file. It needs
        /// `-rootFile`, so the certificate it installs is a test one.
        static let installCertificateOn = "installCertificateOn"
        /// `-useReqlyOnEmulator emulator-5580` presses Use Reqly for that emulator once capturing
        /// has started and it's ready.
        static let useReqlyOnEmulator = "useReqlyOnEmulator"
        /// `-copyCertificateToEmulator emulator-5580` presses Copy Certificate for that emulator
        /// once HTTPS is set up and it's ready.
        static let copyCertificateToEmulator = "copyCertificateToEmulator"
        /// `-stopUsingReqlyOn /reqly-check/done` presses Stop Using Reqly for the
        /// `-useReqlyOnEmulator` emulator once a request for that path arrives.
        static let stopUsingReqlyOn = "stopUsingReqlyOn"
        /// `-emulatorResultFile path` writes there what each of the emulator presses did.
        static let emulatorResultFile = "emulatorResultFile"
        /// `-sessionsFolder path` keeps this run's traffic in that folder instead of Application
        /// Support. Old sessions are cleaned up there only.
        static let sessionsFolder = "sessionsFolder"
        /// `-sessionLimit 5000` keeps at most that many requests, dropping the oldest.
        static let sessionLimit = "sessionLimit"
        /// `-perfLog path` measures how the main thread keeps up, and writes it there as JSON Lines.
        static let perfLog = "perfLog"
        /// `-perfAt 10000,20000` runs the timed filter, search, scroll and select steps once each
        /// count of requests is reached, with `-perfLog`.
        static let perfAt = "perfAt"
    #endif
}
