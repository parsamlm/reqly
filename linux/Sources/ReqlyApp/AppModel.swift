import AppSetup
import CoreInterface
import Dispatch
import Foundation
import Presentation
import ReqlyModel

/// Reqly's state, on the main actor: what's the app's rather than a window's. The live session
/// (``live``) and capturing, your desktop's proxy, HTTPS, your settings, and the rules, devices,
/// connections and `.proto` files the live session opened, with the requests breakpoints hold and
/// the devices that wait to be let in. Windows and features read it, and hear of each change
/// through ``observe(_:)``. A file's window has a session of its own, a ``SessionModel``, which
/// shares the rest.
@MainActor
final class AppModel {
    /// Where capturing is.
    enum Capture: Sendable, Equatable {
        case stopped, starting, capturing, stopping
    }

    /// A request or a response a breakpoint holds, with its edit as the core first gave it.
    struct Paused {
        var id: ExchangeID
        var edit: PausedEdit
    }

    /// A device on the network that asked to use Reqly, as the latest `deviceWaiting` event said.
    struct WaitingDevice: Equatable {
        var id: String
        var address: String
        /// How many devices wait, this one with them.
        var waiting: Int
    }

    let options: Options
    let folders: AppFolders
    private(set) var settings: AppSettings
    /// The live session's window's session: the session, once it's open, a live one or the saved
    /// one a test run opens, and its events.
    private(set) lazy var live = SessionModel(app: self, file: nil)
    /// HTTPS decryption: Reqly's certificate, and the hosts to decrypt.
    private(set) lazy var https = HTTPSModel(app: self)
    /// Your desktop's proxy setting, as capturing changes it.
    private(set) lazy var desktopProxy = DesktopProxy(options: options, folders: folders)
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
    /// Whether Open Terminal has opened a terminal in this run, whose shell points at Reqly
    /// whether it captures or not.
    var openedTerminal = false {
        didSet { changed() }
    }
    /// Whether the session is still opening, or capturing still starting after the live window
    /// first showed, when you asked for that as Reqly opens.
    private(set) var isOpening = true {
        didSet { changed() }
    }
    /// The live session's rules, as it last said, once it has opened `Rules.json`.
    var rules: RulesState? {
        didSet { changed() }
    }
    /// The devices you let in and the ones that wait, as the live session last said.
    var devices: DevicesState? {
        didSet { changed() }
    }
    /// The upstream proxy, the reverse proxies and the client certificates, once the live session
    /// has opened them, as the live window first showed.
    var connections: ConnectionsState? {
        didSet { changed() }
    }
    /// The `.proto` files bodies are read with, which every session shares, once they're read.
    var protobuf: ProtobufState? {
        didSet { changed() }
    }
    /// The requests and responses breakpoints hold, in the order they paused, from the live
    /// session's events, so a window made later still shows them.
    private(set) var paused: [Paused] = [] {
        didSet { changed() }
    }
    /// The latest device that asked to use Reqly. There's no event once it's answered: whoever
    /// answers, or reads the devices again, sets ``devices``, which says who still waits.
    private(set) var waitingDevice: WaitingDevice? {
        didSet { changed() }
    }
    /// Whether the live window has shown, which starts capturing as Reqly opens, when you asked
    /// for that, and opens the connections.
    private(set) var liveWindowHasShown = false
    /// Whether the live window shows now: capturing at launch waits for it, and closing it stops
    /// capturing.
    private(set) var liveWindowIsShowing = false

    private var observers: [Int: @MainActor () -> Void] = [:]
    private var nextObserver = 0
    private var opening: Task<Void, Never>?
    /// Reading the certificate and handing the session your hosts, as it opened.
    private var loadingHTTPS: Task<Void, Never>?
    /// What starts once the live window first shows, and the session has opened.
    private var firstShowing: Task<Void, Never>?
    /// The latest start or stop of capturing. The next one waits for it, and so does quitting.
    private var captureChange: Task<Void, Never>?
    private var isClosing = false
    /// Whether ``close()`` has finished.
    private(set) var isClosed = false

    init(options: Options, folders: AppFolders) {
        self.options = options
        self.folders = folders
        settings = AppSettings.load(from: folders.settingsFile)
    }

    /// The live session, once it's open.
    var session: SessionHost? { live.session }

    var isCapturing: Bool { capture == .capturing }

    /// The port capturing listens on, or starts on: the run's own, or the one in your settings.
    var port: Int { listeningPort ?? options.port ?? settings.proxyPort }

    // MARK: - Changes and events

    /// Runs `body` after each change to the state, until ``stopObserving(_:)`` with what it
    /// returns.
    @discardableResult
    func observe(_ body: @escaping @MainActor () -> Void) -> Int {
        nextObserver += 1
        observers[nextObserver] = body
        return nextObserver
    }

    func stopObserving(_ observer: Int) {
        observers[observer] = nil
    }

    /// Hands `body` each of the live session's events, in order, once the live window listens.
    func listen(_ body: @escaping @MainActor (Event) -> Void) {
        live.listen(body)
    }

    /// Tells the observers that the state changed.
    func changed() {
        for (_, observer) in observers.sorted(by: { $0.key < $1.key }) {
            observer()
        }
    }

    /// One of the live session's events: the app keeps what breakpoints hold and who waits, at
    /// once, and the live window hears each event once it listens.
    private func handle(_ event: Event) {
        switch event {
        case .paused(let id, let edit):
            if let index = paused.firstIndex(where: { $0.id == id }) {
                paused[index].edit = edit
            } else {
                paused.append(Paused(id: id, edit: edit))
            }
        case .resumed(let id):
            paused.removeAll { $0.id == id }
        case .deviceWaiting(let id, let address, let waiting):
            waitingDevice = WaitingDevice(id: id, address: address, waiting: waiting)
        default:
            break
        }
        live.receive(event)
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

    /// Opens the live session, with its rules, its devices and the `.proto` files.
    func open() {
        opening = Task { await openSession() }
    }

    private func openSession() async {
        defer {
            // Still opening while capturing starts, when the live window has shown.
            if !startOnFirstShowing() {
                isOpening = false
            }
        }
        // Settings a Reqly that quit unexpectedly left pointing at itself go back first, as on
        // Windows.
        await desktopProxy.restoreLeftBehind()
        do {
            try folders.makeSessionsFolder()
        } catch {
            // Foundation's own description of a file error says nothing on Linux.
            problem = "Reqly couldn't make the folder for its sessions, \(folders.sessionsFolder.path)."
            return
        }
        let session: SessionHost
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
        // Every session shares the `.proto` files, so they're read once, beside the rest.
        let protobufFile = folders.protobufFile
        Task { [weak self] in
            let state = await session.protobuf.open(protobufFile)
            self?.protobuf = state
        }
        rules = await session.openRules(folders.rulesFile)
        devices = await session.openDevices(
            folders.devicesFile, allowsNetworkDevices: options.allowsNetworkDevices ?? settings.allowsNetworkDevices)
        live.opened(session)
        // Reading the certificate may wait for you to unlock your keyring, so quitting doesn't
        // wait for it.
        loadingHTTPS = Task { await https.load() }
    }

    /// The live window shows. The first time, capturing starts, if you asked for that as Reqly
    /// opens, once the connections are open. A Reqly started to show a file does neither until
    /// you show the live window.
    func liveWindowShown() {
        liveWindowIsShowing = true
        guard !liveWindowHasShown else { return }
        liveWindowHasShown = true
        startOnFirstShowing()
    }

    /// The live window hid, as you closed it: capturing stops, which puts your proxy settings back,
    /// and doesn't start as Reqly opens if it hadn't yet.
    func liveWindowHidden() {
        liveWindowIsShowing = false
        Task { await setCapturing(false) }
    }

    /// Once the live window has shown and the session has opened: the connections open, after the
    /// certificate's been read, so one unlock of your keyring may serve both, then capturing
    /// starts if you asked for that. Whether capturing starts.
    @discardableResult
    private func startOnFirstShowing() -> Bool {
        guard liveWindowHasShown, firstShowing == nil, let session, !isClosing else { return false }
        let startsCapturing = options.startsCapturing ?? settings.startsCapturingOnLaunch
        if startsCapturing {
            isOpening = true
        }
        let loadingHTTPS = loadingHTTPS
        firstShowing = Task {
            defer { isOpening = false }
            await loadingHTTPS?.value
            guard !isClosing else { return }
            await openConnections(session)
            if startsCapturing, liveWindowIsShowing {
                await setCapturing(true)
            }
        }
        return startsCapturing
    }

    /// Opens the connections: the upstream proxy, the reverse proxies and the client
    /// certificates, with their secrets, which may wait for your keyring. A test run's secrets
    /// are a plain file.
    func openConnections(_ session: SessionHost) async {
        connections = await session.openConnections(
            folders.connectionsFile, secrets: folders.secretsFile, protectsSecrets: options.secretsStandIn == nil)
    }

    /// A device's question was answered, or the devices read again: who still waits. There's no
    /// event for that.
    func devicesChanged(_ state: DevicesState) {
        devices = state
        let stillWaiting = waitingDevice.flatMap { device in
            state.waiting.contains { $0.id == device.id } ? device : nil
        }
        let next = stillWaiting ?? state.waiting.first.map { WaitingDevice(id: $0.id, address: $0.address, waiting: 0) }
        waitingDevice = next.map { WaitingDevice(id: $0.id, address: $0.address, waiting: state.waiting.count) }
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
        defer { isClosed = true }
        // A test run's slow close, as the self-check's logout part asks for.
        if options.isTestRun, let delay = options.closeDelay {
            try? await Task.sleep(for: .milliseconds(delay))
        }
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
        await live.close()
    }
}
