import AppSetup
import CGio
import CGtk
import CGtkSource
import Foundation
import GtkBinding
import LinuxDesktop

/// Reqly for Linux: the application, its windows and its actions.
///
/// A real run is the only Reqly: a second launch hands GApplication's activation to the first one,
/// through its name on the session bus, with the files it was given, and quits before it touches
/// anything, so two never put back each other's proxy settings. Without files, the first brings
/// back its live window; with files, it opens each in a window of its own. A test run is a
/// non-unique application, so it runs beside the Reqly that's open and opens its own files, unless
/// `--app-id` gives it an ID of its own, under which it's the only one.
///
/// The live session and its window are the app's: the window is made the first time it shows, and
/// closing it hides it, which stops capturing and closes the windows that belong to it, such as
/// Rules. A file's window closes alone, and its session with it. Reqly quits once no window shows,
/// or with Quit, closing every session.
@MainActor
final class App {
    /// The app ID: the name a running Reqly holds on the session bus, and its desktop file's name.
    static let id = ProxyGuard.appName
    /// Reqly for Linux's version, as About and `--version` show it.
    static let version = "1.0.0-dev"
    /// Where Sponsor Reqly goes, as on the Mac.
    static let sponsor = "https://github.com/sponsors/parsamlm"

    let options: Options
    let model: AppModel
    let application: UnsafeMutablePointer<AdwApplication>
    /// The live session's window, once it has shown.
    private(set) var liveWindow: MainWindow?
    /// The windows of the files opened, in the order they opened.
    private(set) var fileWindows: [MainWindow] = []
    /// Windows that belong to the live window, such as Rules, Devices and composers, which close as
    /// it hides: see ``addSecondary(_:over:)``.
    private(set) var secondaries: [any SecondaryWindow] = []
    /// Each file window's file, to find the window that shows a file again.
    private var fileWindowFiles: [ObjectIdentifier: OpaquePointer] = [:]
    private var selfCheck: SelfCheck?
    private(set) var isQuitting = false
    /// Every session's close, once something has started it: quitting, the session's end, or the
    /// main loop's. They share it, since each of the core's sessions closes once.
    private var closing: Task<Void, Never>?
    /// Whether every session has closed.
    private var isClosed = false
    /// The sessions of file windows that closed, until their copies have gone.
    private var closingFiles: [Task<Void, Never>] = []
    /// The session bus's shared connection, which GApplication uses too, kept for as long as
    /// Reqly runs, with its filter.
    private var sessionBus: OpaquePointer?
    /// Reqly's client of your session manager, where there's one.
    private var sessionClient: SessionManagerClient?
    /// What `run` returns when GApplication itself has nothing to report: 1 once the self-check
    /// fails.
    var exitStatus: Int32 = 0

    init(options: Options) {
        self.options = options
        model = AppModel(options: options, folders: AppFolders(options: options))
        let isUnique = !options.isTestRun || options.appID != nil
        let flags = G_APPLICATION_HANDLES_OPEN.rawValue | (isUnique ? 0 : G_APPLICATION_NON_UNIQUE.rawValue)
        application = adw_application_new(options.appID ?? Self.id, GApplicationFlags(rawValue: flags))
    }

    /// Runs Reqly until it quits, and returns its exit status.
    func run() -> Int32 {
        MainLoop.runSwiftMainQueue()
        connect(application, "startup") { [weak self] in self?.startUp() }
        connect(application, "activate") { [weak self] in self?.activate() }
        connect(application, "open") { [weak self] (arguments: Arguments) in
            self?.open(files: arguments.pointer(1), count: Int(arguments.int(2)))
        }
        followTheSession()
        // The window's X11 class, as the app ID, so desktops that match windows to desktop files by
        // their class find Reqly's. On Wayland, GTK names the window by the app ID itself.
        g_set_prgname(Self.id)
        // The program's name and the files, which GApplication makes full paths of, or takes as
        // URIs: Reqly's own options aren't GApplication's, which would refuse them. A Reqly that's
        // running already gets the files.
        let given = [CommandLine.arguments[0]] + options.files
        var arguments: [UnsafeMutablePointer<CChar>?] = given.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        let status = g_application_run(cast(application), Int32(given.count), &arguments)
        // When the main loop ended without Reqly's quit, as when the display went on GNOME 50.
        close(within: 5)
        // Only now, with nothing left to do but end: the session manager ends the session, and the
        // display with it, once every app has answered.
        sessionClient?.answerTheEnd()
        return status != 0 ? status : exitStatus
    }

    /// How Reqly hears that you're logging out. GNOME's and Cinnamon's logout sends no signal: the
    /// session manager asks each app whether the session may end, shows its confirmation, then
    /// ends the session, and with it the display, which ends Reqly at once. Where there's a
    /// session manager, Reqly is its client: see ``SessionManagerClient``. Elsewhere GTK follows
    /// the session, as on Xfce: 4.14 and 4.18 only for an app that registers, and 4.22 always,
    /// ignoring the property; then Reqly closes when it's asked.
    private func followTheSession() {
        // Before GTK's startup, so the filter is there before GTK asks the portal anything.
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil) else { return }
        sessionBus = bus
        // The portal's word that the session ends never reaches GTK: GTK 4.18 hands GApplication
        // the wrong object then and logs a critical, 4.22 quits with the display about to go, and
        // a portal left from an earlier session, as Cinnamon's can be, says so to each app as it
        // starts. Reqly quits when its session manager, or you, say so.
        g_dbus_connection_add_filter(bus, dropThePortalsEnd, nil, nil)
        if SessionManagerClient.isRunning(on: bus) {
            let client = SessionManagerClient(connection: bus)
            client.atEnd = { [weak self] in self?.sessionEnded() }
            client.atStop = { [weak self] in self?.quit() }
            sessionClient = client
            return
        }
        if gtk_get_minor_version() < 22 {
            set(raw(application), "register-session", .bool(true))
        }
        connect(application, "query-end") { [weak self] in self?.sessionEnding() }
    }

    /// The first Reqly only: its styles, its actions and the signals it quits on, then the session.
    private func startUp() {
        Styles.install(theme: options.theme)
        Icons.install()
        Icons.installAppIcon()
        PreviewView.clearOpened()
        // GtkSourceView's types and translations, once, before any code view.
        gtk_source_init()
        addActions()
        // Ctrl+C in its terminal ends Reqly with SIGINT, closing the terminal with SIGHUP, and
        // some desktops' logout with SIGTERM. Each quits as the menu does, so your proxy settings
        // go back.
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            onSignal(signal) { [weak self] in
                self?.quit()
                return true
            }
        }
        sessionClient?.register(appID: options.appID ?? Self.id)
        model.open()
    }

    /// You've confirmed the logout, and the session manager waits for Reqly's answer before it
    /// ends the session: Reqly closes, as quitting does, so capturing stops, which puts your proxy
    /// settings back, and the session's folder goes. Then it quits, and answers once its main loop
    /// has ended.
    private func sessionEnded() {
        AppLog.write("the session is ending, so Reqly closes")
        isQuitting = true
        // gnome-session waits a minute and a half for the answer, and Cinnamon's half a minute.
        close(within: 5)
        g_application_quit(cast(application))
    }

    /// You're logging out where GTK follows the session: it asks whether the session may end, and
    /// waits for the answer, which GTK sends once this returns. So Reqly closes now, as quitting
    /// does: capturing stops, which puts your proxy settings back, and the session's folder goes.
    /// Then the main loop ends, before your desktop goes, which would end Reqly at once. If the
    /// logout is called off, Reqly has quit, as apps do on a Mac.
    private func sessionEnding() {
        AppLog.write("the session is ending, so Reqly closes")
        isQuitting = true
        stopHearingTheSessionManager()
        // The session manager and the portal wait a second for the answer, then go on without it.
        close(within: 0.75)
        g_application_quit(cast(application))
    }

    /// From the question on, what the session manager says reaches GTK no more: the session's
    /// end, which comes once every app has answered, a stop, or a logout called off. Reqly quits
    /// whatever it says. GTK's handler for the session manager's client signals keeps a pointer
    /// to the object GTK frees as Reqly quits, and never lets go of it, so the session's end would
    /// reach freed memory whenever the main loop runs after that: while Reqly's close still runs,
    /// when it took longer than the session manager waits, and while GTK hands a clipboard Reqly
    /// owns to X11's clipboard manager. Nor does GTK's own handling of the session's end run,
    /// which logs a warning with GTK 4.14 and a critical with 4.18, even when a session manager
    /// ends the session while Reqly still closes, before it has answered.
    private func stopHearingTheSessionManager() {
        guard let connection = g_application_get_dbus_connection(cast(application)) else { return }
        g_dbus_connection_add_filter(connection, dropSessionManagerSignals, nil, nil)
    }

    /// Closes every session, unless they're closed, and waits for it at most `seconds`, running
    /// the main loop, which runs the close meanwhile: capturing stops, so your proxy settings go
    /// back before Reqly ends, and the sessions' folders go. The watcher puts the settings back if
    /// Reqly ends before that. Call it only from a GLib callback, such as a signal's handler,
    /// never from a Swift task: GLib doesn't run Swift's main queue again while it's running a
    /// task from it, so the close would wait for the deadline.
    private func close(within seconds: Double) {
        guard !isClosed else { return }
        let task = startClosing()
        let done = Closing()
        Task {
            await task.value
            done.isDone = true
        }
        let deadline = monotonicMicroseconds() + Int(seconds * 1_000_000)
        // Wakes the loop now and then, so the deadline is seen even while nothing happens.
        let tick = timeout(25) { true }
        while !done.isDone, monotonicMicroseconds() < deadline {
            g_main_context_iteration(nil, 1)
        }
        g_source_remove(tick)
    }

    /// Starts every session's close, or returns the one that's under way: the live one, which
    /// stops capturing first, and each file window's, which deletes its copy, together.
    private func startClosing() -> Task<Void, Never> {
        if let closing {
            return closing
        }
        let files = fileWindows.map(\.model)
        let closed = closingFiles
        let task = Task { [model] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.close() }
                for file in files {
                    group.addTask { await file.close() }
                }
                for close in closed {
                    group.addTask { await close.value }
                }
            }
            self.isClosed = true
        }
        closing = task
        return task
    }

    // MARK: - Windows

    /// A launch without files, the first or a later one: the live window shows, made the first
    /// time, or brought back.
    private func activate() {
        presentLive()
    }

    /// Shows the live window, made the first time, brought back once it was closed, or brought to
    /// the front, as every command for the live session does first.
    @discardableResult
    func presentLive() -> MainWindow {
        if let liveWindow {
            liveWindow.present()
            return liveWindow
        }
        let window = MainWindow(app: self, model: model.live)
        liveWindow = window
        window.present()
        startSelfCheck()
        return window
    }

    /// A launch with files, the first or a later one, through GApplication: each in a window of
    /// its own, made here, before GApplication goes on, so a first launch with only files keeps
    /// running. Nothing captures, and the live window doesn't show.
    private func open(files: UnsafeMutableRawPointer?, count: Int) {
        guard let files, count > 0 else { return }
        let list = files.assumingMemoryBound(to: OpaquePointer?.self)
        open((0..<count).compactMap { list[$0] })
        startSelfCheck()
    }

    /// Opens each of `files` in a window of its own, or brings forward the window that shows it.
    /// A file that can't be opened gets its window too, which says why.
    func open(_ urls: [URL]) {
        let files = urls.map { g_file_new_for_path($0.path)! }
        open(files)
        for file in files {
            g_object_unref(raw(file))
        }
    }

    private func open(_ files: [OpaquePointer]) {
        for file in files {
            if let shown = window(showing: file) {
                shown.present()
                continue
            }
            guard let path = takeString(g_file_get_path(file)) else { continue }
            let session = SessionModel(app: model, file: URL(filePath: path))
            let window = MainWindow(app: self, model: session)
            fileWindows.append(window)
            fileWindowFiles[ObjectIdentifier(window)] = file
            g_object_ref(raw(file))
            session.openFile()
            window.present()
        }
    }

    /// The file window that shows `file`, the same file as GIO compares them, case and all.
    private func window(showing file: OpaquePointer) -> MainWindow? {
        fileWindows.first { window in
            fileWindowFiles[ObjectIdentifier(window)].map { g_file_equal($0, file) != 0 } ?? false
        }
    }

    /// The window `window` asked to close, with its close button or Ctrl+W: a file's window
    /// closes, and its session with it; the live window hides, which stops capturing and closes
    /// the windows that belong to it. Once no window shows, Reqly quits.
    func closeWindow(_ window: MainWindow) {
        let showsOthers =
            fileWindows.contains { $0 !== window } || (liveWindow.map { $0 !== window && $0.isShowing } ?? false)
        // Quitting holds the application first, so it doesn't end with its last window, before
        // the sessions have closed.
        if !showsOthers {
            quit()
        }
        if window === liveWindow {
            hideLive()
        } else if let index = fileWindows.firstIndex(where: { $0 === window }) {
            fileWindows.remove(at: index)
            if let file = fileWindowFiles.removeValue(forKey: ObjectIdentifier(window)) {
                g_object_unref(raw(file))
            }
            gtk_window_destroy(cast(window.window))
            if !isQuitting {
                let session = window.model
                closingFiles.append(Task { await session.close() })
            }
        }
    }

    /// The live window goes, but its session and list stay: capturing stops, which puts your
    /// proxy settings back, and the windows that belong to it close. Show Live Traffic, or a
    /// launch without files, brings it back.
    private func hideLive() {
        guard let liveWindow, liveWindow.isShowing else { return }
        for secondary in secondaries {
            gtk_window_destroy(cast(secondary.window))
        }
        secondaries = []
        gtk_widget_set_visible(liveWindow.window, 0)
        if !isQuitting {
            model.liveWindowHidden()
        }
    }

    /// Keeps `secondary` until its window goes, as it closes, or as the live window hides.
    func keepSecondary(_ secondary: any SecondaryWindow) {
        let window = secondary.window
        secondaries.append(secondary)
        connect(window, "destroy") { [weak self] in
            self?.secondaries.removeAll { $0.window == window }
        }
    }

    /// The Reqly window in front, the live window or a file's, or the live window when none of
    /// them is.
    var windowInFront: MainWindow? {
        let active = gtk_application_get_active_window(cast(application)).map { cast($0) as Widget }
        return ([liveWindow].compactMap { $0 } + fileWindows).first { $0.window == active } ?? liveWindow
    }

    /// Whether a dialog shows over the window in front, while which shortcuts wait.
    var dialogShows: Bool {
        guard let active = gtk_application_get_active_window(cast(application)).map({ cast($0) as Widget }) else {
            return false
        }
        if g_type_check_instance_is_a(cast(active), adw_application_window_get_type()) != 0 {
            return visibleDialog(over: active) != nil
        }
        if g_type_check_instance_is_a(cast(active), adw_window_get_type()) != 0 {
            return adw_window_get_visible_dialog(cast(active)) != nil
        }
        return false
    }

    /// Starts the self-check, once, as the first window shows, when the run asks for it.
    private func startSelfCheck() {
        guard selfCheck == nil, let report = options.smokeReport else { return }
        let check = SelfCheck(app: self, report: URL(filePath: report), names: options.smokeParts)
        selfCheck = check
        Task { await check.run() }
    }

    // MARK: - Quitting

    /// Quits Reqly, whichever way you quit: from the menu, by closing the last window, with a
    /// signal, or as the self-check ends. Capturing stops first, which puts your desktop's proxy
    /// back, and every session's folder goes. The application holds on until then, rather than
    /// ending as its last window goes, and until a self-check has written its report.
    func quit() {
        guard !isQuitting else { return }
        isQuitting = true
        g_application_hold(cast(application))
        let closing = startClosing()
        Task {
            await closing.value
            await selfCheck?.finished()
            g_application_quit(cast(application))
        }
    }
}

/// Whether closing has finished, for ``App/close(within:)``.
@MainActor
private final class Closing {
    var isDone = false
}

/// The interfaces the session manager's signals to an app come on: gnome-session's to a client,
/// which Cinnamon's and MATE's session managers share, Xfce's, and the portal's session states.
private let sessionManagerInterfaces: Set<String> = [
    "org.gnome.SessionManager.ClientPrivate", "org.xfce.Session.Client", "org.freedesktop.portal.Inhibit",
]

/// A filter on the session bus that drops the portal's word that the session ends before GDBus
/// hands it on. GDBus runs it on a thread of its own, for every message in or out.
private let dropThePortalsEnd: GDBusMessageFilterFunction = { _, message, incoming, _ in
    guard incoming != 0, let message, g_dbus_message_get_message_type(message) == G_DBUS_MESSAGE_TYPE_SIGNAL,
        string(g_dbus_message_get_interface(message)) == "org.freedesktop.portal.Inhibit",
        string(g_dbus_message_get_member(message)) == "StateChanged",
        sessionState(g_dbus_message_get_body(message)) == 3
    else { return message }
    g_object_unref(raw(message))
    return nil
}

/// The session's state in the portal's StateChanged: 1 while it runs, 2 as the session manager
/// asks whether it may end, 3 as it ends.
private func sessionState(_ body: OpaquePointer?) -> UInt32? {
    guard let body, string(g_variant_get_type_string(body)) == "(oa{sv})" else { return nil }
    let states = g_variant_get_child_value(body, 1)
    defer { g_variant_unref(states) }
    guard let state = g_variant_lookup_value(states, "session-state", nil) else { return nil }
    defer { g_variant_unref(state) }
    return g_variant_classify(state) == G_VARIANT_CLASS_UINT32 ? g_variant_get_uint32(state) : nil
}

/// A filter on the session bus that drops the session manager's signals before GDBus hands them
/// on. GDBus runs it on a thread of its own, for every message in or out.
private let dropSessionManagerSignals: GDBusMessageFilterFunction = { _, message, incoming, _ in
    guard incoming != 0, let message, g_dbus_message_get_message_type(message) == G_DBUS_MESSAGE_TYPE_SIGNAL,
        let interface = g_dbus_message_get_interface(message),
        sessionManagerInterfaces.contains(String(cString: interface))
    else { return message }
    // The filter owns what it's handed, and drops a message by releasing it.
    g_object_unref(raw(message))
    return nil
}
