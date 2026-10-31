import AppSetup
import CoreInterface
import Dispatch
import Foundation
import LinuxDesktop

/// Reqly's state, on the main actor, and the live session behind it. The window and the features
/// read the state, and hear of each change through ``observe(_:)``. The session's events arrive in
/// the order the session sends them, and go to whoever listens through ``listen(_:)``, such as
/// the request list.
@MainActor
final class AppModel {
    /// Where capturing is.
    enum Capture: Sendable, Equatable {
        case stopped, starting, capturing, stopping
    }

    let options: Options
    let folders: AppFolders
    private(set) var settings: AppSettings
    /// The live session, once it's open.
    private(set) var session: SessionHost?
    /// HTTPS decryption: Reqly's certificate, and the hosts to decrypt.
    private(set) lazy var https = HTTPSModel(app: self)
    var capture = Capture.stopped {
        didSet { changed() }
    }
    /// The port Reqly listens on while it captures.
    var listeningPort: Int? {
        didSet { changed() }
    }
    /// What went wrong, such as why the session didn't open or capturing didn't start, until it
    /// works.
    var problem: String? {
        didSet { changed() }
    }

    private var observers: [@MainActor () -> Void] = []
    private var listeners: [@MainActor (Event) -> Void] = []
    private var opening: Task<Void, Never>?
    /// The latest start or stop of capturing. The next one waits for it, and so does quitting.
    private var captureChange: Task<Void, Never>?
    private var isClosing = false

    init(options: Options, folders: AppFolders) {
        self.options = options
        self.folders = folders
        settings = AppSettings.load(from: folders.settingsFile)
    }

    var isCapturing: Bool { capture == .capturing }

    /// The port capturing listens on, or starts on: the run's own, or the one in your settings.
    var port: Int { listeningPort ?? options.port ?? settings.proxyPort }

    // MARK: - Changes and events

    /// Runs `body` after each change to the state.
    func observe(_ body: @escaping @MainActor () -> Void) {
        observers.append(body)
    }

    /// Hands `body` each of the session's events, in order.
    func listen(_ body: @escaping @MainActor (Event) -> Void) {
        listeners.append(body)
    }

    /// Tells the observers that the state changed.
    func changed() {
        for observer in observers {
            observer()
        }
    }

    private func handle(_ event: Event) {
        for listener in listeners {
            listener(event)
        }
    }

    // MARK: - Settings

    /// Changes your settings and saves them. Throws when they couldn't be saved; the change stays
    /// for this run.
    func changeSettings(_ change: (inout AppSettings) -> Void) throws {
        var new = settings
        change(&new)
        guard new != settings else { return }
        settings = new
        changed()
        try new.save(to: folders.settingsFile)
    }

    // MARK: - The session

    /// Opens the live session, then starts capturing if you asked for that.
    func open() {
        opening = Task { await openSession() }
    }

    private func openSession() async {
        // Settings a Reqly that quit unexpectedly left pointing at itself go back first, as on
        // Windows.
        if options.setsSystemProxy, options.proxySettingsStandIn == nil {
            do {
                let guardian = ProxyGuard(restoreFile: folders.proxyRestoreFile)
                if try DesktopProxySwitch.restoreLeftBehind(guardian: guardian) {
                    AppLog.write("put back the proxy settings a Reqly that quit unexpectedly left")
                }
            } catch {
                AppLog.write("couldn't put back the proxy settings a Reqly left: \(error)")
            }
        }
        do {
            try folders.makeSessionsFolder()
        } catch {
            problem = "Reqly couldn't make the folder for its sessions. \(error.localizedDescription)"
            return
        }
        do {
            session = try await SessionHost.open(folders.openOptions(options), system: options.systemParts) {
                [weak self] event in
                // The main queue runs its work in the order it's queued, so the events stay in
                // the session's order, as rows events need: each applies to the version before.
                DispatchQueue.main.async { self?.handle(event) }
            }
        } catch {
            problem = error.message
            return
        }
        changed()
        await https.load()
        if options.startsCapturing ?? settings.startsCapturingOnLaunch {
            await setCapturing(true)
        }
    }

    /// Runs `change`, a start or a stop of capturing, once the one before it has finished, so two
    /// never overlap. Once Reqly is quitting, it doesn't run.
    func changeCapturing(_ change: @escaping @MainActor () async -> Void) async {
        guard !isClosing else { return }
        let previous = captureChange
        let next = Task {
            await previous?.value
            await change()
        }
        captureChange = next
        await next.value
    }

    /// Stops capturing, which puts your desktop's proxy back, and closes the session, which
    /// deletes its folder, as Reqly quits. A session still opening, or capturing still starting,
    /// finishes first.
    func close() async {
        isClosing = true
        await opening?.value
        await captureChange?.value
        guard let session else { return }
        if capture != .stopped {
            do {
                try await session.stopCapturing()
            } catch {
                AppLog.write("couldn't stop capturing as Reqly quit: \(error.message)")
            }
            capture = .stopped
            listeningPort = nil
        }
        await session.close()
        self.session = nil
    }
}
