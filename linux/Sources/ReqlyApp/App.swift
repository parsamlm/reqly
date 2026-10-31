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
/// application, so it runs beside the Reqly that's open.
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
    /// What `run` returns when GApplication itself has nothing to report: 1 once the self-check
    /// fails.
    var exitStatus: Int32 = 0

    init(options: Options) {
        self.options = options
        model = AppModel(options: options, folders: AppFolders(options: options))
        application = adw_application_new(
            Self.id, options.isTestRun ? G_APPLICATION_NON_UNIQUE : G_APPLICATION_DEFAULT_FLAGS)
    }

    /// Runs Reqly until it quits, and returns its exit status.
    func run() -> Int32 {
        MainLoop.runSwiftMainQueue()
        connect(application, "startup") { [weak self] in self?.startUp() }
        connect(application, "activate") { [weak self] in self?.activate() }
        // The window's X11 class, as the app ID, so desktops that match windows to desktop files by
        // their class find Reqly's. On Wayland, GTK names the window by the app ID itself.
        g_set_prgname(Self.id)
        // Only the program's name: Reqly's own options aren't GApplication's.
        var arguments: [UnsafeMutablePointer<CChar>?] = [CommandLine.unsafeArgv[0], nil]
        let status = g_application_run(cast(application), 1, &arguments)
        return status != 0 ? status : exitStatus
    }

    /// The first Reqly only: its styles, its actions and the signals it quits on, then the session.
    private func startUp() {
        Styles.install(theme: options.theme)
        addActions()
        // Logging out ends Reqly with SIGTERM, Ctrl+C in its terminal with SIGINT, and closing the
        // terminal with SIGHUP. Each quits as the menu does, so your proxy settings go back.
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            onSignal(signal) { [weak self] in
                self?.quit()
                return true
            }
        }
        model.open()
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

    /// The menu's actions, each in one place, calling the feature that owns it.
    private func addActions() {
        add("set-up-https") { [weak self] in self?.window?.setUpHTTPS() }
        add("open-terminal") { [weak self] in self?.window?.openTerminal() }
        add("copy-terminal-setup") { [weak self] in self?.window?.copyTerminalSetup() }
        add("settings", accelerator: "<Control>comma") { [weak self] in self?.window?.showSettings() }
        add("about") { [weak self] in self?.window?.showAbout() }
        add("quit", accelerator: "<Control>q") { [weak self] in self?.quit() }
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
        Task {
            await model.close()
            g_application_quit(cast(application))
        }
    }
}
