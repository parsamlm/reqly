import AppSetup
import CGtk
import Foundation
import GtkBinding
import LinuxDesktop

/// Reqly for Linux: the application, its window and its actions.
///
/// A real run is the only Reqly: a second launch hands GApplication's activation to the first one,
/// through its name on the session bus, which brings back its window, and quits before it touches
/// anything, so two never put back each other's proxy settings. A test run is a non-unique
/// application, so it runs beside the Reqly that's open, unless `--app-id` gives it an ID of its
/// own, under which it's the only one.
@MainActor
final class App {
    /// The app ID: the name a running Reqly holds on the session bus, and its desktop file's name.
    static let id = ProxyGuard.appName
    /// Reqly for Linux's version, as About and `--version` show it.
    static let version = "1.0.0-dev"

    let options: Options
    let model: AppModel
    let application: UnsafeMutablePointer<AdwApplication>
    private(set) var window: MainWindow?
    private var selfCheck: SelfCheck?
    private var isQuitting = false
    /// The model's close, once something has started it: quitting, the session's end, or the main
    /// loop's. They share it, since the core's session closes once.
    private var closing: Task<Void, Never>?
    /// What `run` returns when GApplication itself has nothing to report: 1 once the self-check
    /// fails.
    var exitStatus: Int32 = 0

    init(options: Options) {
        self.options = options
        model = AppModel(options: options, folders: AppFolders(options: options))
        let isUnique = !options.isTestRun || options.appID != nil
        application = adw_application_new(
            options.appID ?? Self.id, isUnique ? G_APPLICATION_DEFAULT_FLAGS : G_APPLICATION_NON_UNIQUE)
    }

    /// Runs Reqly until it quits, and returns its exit status.
    func run() -> Int32 {
        MainLoop.runSwiftMainQueue()
        connect(application, "startup") { [weak self] in self?.startUp() }
        connect(application, "activate") { [weak self] in self?.activate() }
        // The session manager asks whether the session may end as you log out, before your
        // desktop goes: GNOME's and Cinnamon's end the session, and with it the display, without
        // a signal. GTK 4.14 and 4.18 follow it only for an app that registers; 4.22 always does,
        // and ignores the property.
        if gtk_get_minor_version() < 22 {
            set(raw(application), "register-session", .bool(true))
        }
        connect(application, "query-end") { [weak self] in self?.sessionEnding() }
        // The window's X11 class, as the app ID, so desktops that match windows to desktop files by
        // their class find Reqly's. On Wayland, GTK names the window by the app ID itself.
        g_set_prgname(Self.id)
        // Only the program's name: Reqly's own options aren't GApplication's, and the files a
        // launcher passes wait for Step 5.
        var arguments: [UnsafeMutablePointer<CChar>?] = [CommandLine.unsafeArgv[0], nil]
        let status = g_application_run(cast(application), 1, &arguments)
        // When the main loop ended without Reqly's quit, as when the display went on GNOME 50.
        close(within: 5)
        return status != 0 ? status : exitStatus
    }

    /// The first Reqly only: its styles, its actions and the signals it quits on, then the session.
    private func startUp() {
        Styles.install(theme: options.theme)
        Icons.install()
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
        model.open()
    }

    /// You're logging out: the session manager asks whether the session may end, and waits for
    /// the answer, which GTK sends once this returns. So Reqly closes now, as quitting does:
    /// capturing stops, which puts your proxy settings back, and the session's folder goes. Then
    /// the main loop ends, before the session's end reaches GTK, and before your desktop goes,
    /// which would end Reqly at once. If the logout is called off, Reqly has quit, as apps do on
    /// a Mac.
    func sessionEnding() {
        AppLog.write("the session is ending, so Reqly closes")
        isQuitting = true
        // gnome-session and the portal wait a second for the answer, then go on without it, and
        // gnome-session says Reqly isn't responding.
        close(within: 0.75)
        g_application_quit(cast(application))
    }

    /// Closes the model, unless it's closed, and waits for it at most `seconds`, running the main
    /// loop, which runs the close meanwhile: capturing stops, so your proxy settings go back
    /// before Reqly ends, and the session's folder goes. The watcher puts the settings back if
    /// Reqly ends before that. Call it only from a GLib callback, such as a signal's handler,
    /// never from a Swift task: GLib doesn't run Swift's main queue again while it's running a
    /// task from it, so the close would wait for the deadline.
    private func close(within seconds: Double) {
        guard !model.isClosed else { return }
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

    /// Starts the model's close, or returns the one that's under way.
    private func startClosing() -> Task<Void, Never> {
        if let closing {
            return closing
        }
        let task = Task { [model] in await model.close() }
        closing = task
        return task
    }

    /// Shows the window: a new one the first time, and the one that's open when another launch
    /// asks for it.
    private func activate() {
        if let window {
            window.present()
            return
        }
        let window = MainWindow(app: self)
        self.window = window
        window.present()
        if let report = options.smokeReport {
            let check = SelfCheck(app: self, report: URL(filePath: report), names: options.smokeParts)
            selfCheck = check
            Task { await check.run() }
        }
    }

    /// The menu's actions, each in one place, calling the feature that owns it. The dialogs open
    /// once the menu has closed: see ``afterMenu(_:)``.
    private func addActions() {
        add("set-up-https") { [weak self] in self?.afterMenu { $0.setUpHTTPS() } }
        add("open-terminal") { [weak self] in self?.window?.openTerminal() }
        add("copy-terminal-setup") { [weak self] in self?.window?.copyTerminalSetup() }
        add("settings", accelerator: "<Control>comma") { [weak self] in self?.afterMenu { $0.showSettings() } }
        add("about") { [weak self] in self?.afterMenu { $0.showAbout() } }
        add("quit", accelerator: "<Control>q") { [weak self] in self?.quit() }
    }

    /// Runs `body` with the window once the main menu, whose entry may have run the action, has
    /// closed and given the keyboard's focus back to its button. A dialog opened from the entry
    /// itself would give the focus back to the entry as it closes, in the hidden menu, as
    /// libadwaita 1.5 does, which leaves the window's shortcuts and Tab doing nothing.
    private func afterMenu(_ body: @escaping @MainActor (MainWindow) -> Void) {
        idle { [weak self] in
            if let window = self?.window {
                body(window)
            }
            return false
        }
    }

    /// Adds the action `app.<name>`, which runs `body`, with its keyboard shortcut.
    private func add(_ name: String, accelerator: String? = nil, _ body: @escaping @MainActor () -> Void) {
        let action = g_simple_action_new(name, nil)!
        connect(action, "activate") { body() }
        g_action_map_add_action(cast(application), cast(action))
        g_object_unref(raw(action))
        if let accelerator {
            withCStrings([accelerator]) { gtk_application_set_accels_for_action(cast(application), "app.\(name)", $0) }
        }
    }

    /// Quits Reqly, whichever way you quit: from the menu, by closing the window, with a signal,
    /// or as the self-check ends. Capturing stops first, which puts your desktop's proxy back, and
    /// the session's folder goes.
    func quit() {
        guard !isQuitting else { return }
        isQuitting = true
        let closing = startClosing()
        Task {
            await closing.value
            g_application_quit(cast(application))
        }
    }
}

/// Whether closing has finished, for ``App/close(within:)``.
@MainActor
private final class Closing {
    var isDone = false
}
