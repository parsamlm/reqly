import CLinux
import Foundation
import ReqlyModel
import Synchronization

/// What puts your proxy settings back if Reqly doesn't, while it captures: the restore file that
/// ``UserProxySwitch`` keeps, a watcher that outlives Reqly, and the login entry for after a power
/// cut. ``DesktopProxySwitch`` starts and stops it with capture, and the app's `main` hands it
/// the watcher's and the login entry's runs, through ``run(arguments:)``.
public struct ProxyGuard: Sendable {
    /// Your settings while Reqly captures, which ``UserProxySwitch`` writes.
    public var restoreFile: URL
    public var loginEntry: LoginEntry
    /// The Reqly program the watcher and the login entry run.
    public var executable: String
    /// The environment the watcher starts with, such as the process's own.
    public var environment: [String: String]

    public init(
        restoreFile: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: String = ProxyGuard.currentExecutable
    ) {
        self.restoreFile = restoreFile
        self.loginEntry = LoginEntry(environment: environment)
        self.executable = executable
        self.environment = environment
    }

    /// This program, as the kernel knows it.
    public static var currentExecutable: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")).map(programPath)
            ?? CommandLine.arguments[0]
    }

    /// The program's path from the name the kernel gives it. Once an upgrade replaces the file
    /// while Reqly runs, the kernel adds " (deleted)" to the name, and the new file at the same
    /// path is the one to run.
    static func programPath(_ name: String) -> String {
        name.hasSuffix(" (deleted)") ? String(name.dropLast(" (deleted)".count)) : name
    }

    /// The argument that starts Reqly as the watcher, followed by Reqly's process ID and the
    /// restore file.
    public static let watcherArgument = "--restore-proxy-after"
    /// The argument the login entry starts Reqly with, followed by the restore file.
    public static let loginArgument = "--restore-proxy"
    /// The D-Bus name a running Reqly holds, through GApplication.
    public static let appName = "net.reqly.Reqly"

    // MARK: - Capture starting and stopping

    /// Capture has started, and the restore file is written: keeps the login entry and starts a
    /// watcher. Neither is needed for capture, so a failure only goes in the log.
    public func captureStarted() {
        do {
            try loginEntry.write(executable: executable, restoreFile: restoreFile)
        } catch {
            Self.log("couldn't write the login entry: \(error)")
        }
        do {
            try startWatcher()
        } catch {
            Self.log("couldn't start the watcher: \(error)")
        }
    }

    /// Capture has stopped and your settings are back: removes the login entry. The watcher sees
    /// the restore file go and quits.
    public func captureStopped() {
        loginEntry.remove()
    }

    /// How many watchers this process has started, so each gets a unit name of its own.
    private static let watchersStarted = Atomic<Int>(0)

    /// Starts `executable --restore-proxy-after <this process> <restore file>`: as a user service
    /// of its own, through `systemd-run`, so that systemd-oomd ending Reqly's scope doesn't end it
    /// too, or else as a child in a session of its own. Either way it keeps none of Reqly's
    /// descriptors.
    func startWatcher() throws {
        let pid = getpid()
        let command = [executable, Self.watcherArgument, "\(pid)", restoreFile.path]
        if let systemdRun = Programs.find("systemd-run", in: environment["PATH"]) {
            let started = Self.watchersStarted.add(1, ordering: .relaxed).newValue
            let unit = "net.reqly.Reqly-restore-\(pid)" + (started > 1 ? "-\(started)" : "")
            let arguments = Self.systemdRunArguments(unit: unit, environment: environment) + command
            if let started = try? Programs.start(systemdRun, arguments, environment: environment),
                Programs.wait(for: started, seconds: 10) == 0
            {
                return
            }
            Self.log("systemd-run didn't start the watcher, so it runs as Reqly's child")
        }
        let watcher = try Programs.start(executable, Array(command.dropFirst()), environment: environment)
        Programs.reapWhenDone(watcher)
    }

    /// `systemd-run`'s arguments for the watcher's service, `unit`: removed once it ends, even
    /// after a failure, with the variables that say where your settings are copied from
    /// `environment`, since the user manager's own may not have them.
    static func systemdRunArguments(unit: String, environment: [String: String]) -> [String] {
        let passed = [
            "XDG_CURRENT_DESKTOP", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_STATE_HOME", "XDG_DATA_HOME",
            "DBUS_SESSION_BUS_ADDRESS",
        ].filter { environment[$0] != nil }
        return [
            "--user", "--collect", "--quiet", "--unit=\(unit)",
            "--description=Puts your proxy settings back if Reqly quits while capturing",
        ] + passed.map { "--setenv=\($0)" } + ["--"]
    }

    // MARK: - The watcher's and the login entry's runs

    /// Runs the watcher or the login entry, when `arguments`, the program's after its name, ask
    /// for either, and returns the exit status for `main`. Returns `nil` for any other arguments,
    /// and the app starts as usual.
    public static func run(arguments: [String]) -> Int32? {
        if arguments.count == 3, arguments[0] == watcherArgument {
            guard let pid = pid_t(arguments[1]), pid > 0 else { return 2 }
            let restoreFile = URL(filePath: arguments[2])
            return watch(pid: pid, restoreFile: restoreFile, loginEntry: LoginEntry()) {
                try UserProxySwitch.restoreLeftBehind(settings: DesktopProxyStore(), restoreFile: restoreFile)
            }
        }
        if arguments.count == 2, arguments[0] == loginArgument {
            let restoreFile = URL(filePath: arguments[1])
            return restoreAtLogin(restoreFile: restoreFile, loginEntry: LoginEntry()) {
                try UserProxySwitch.restoreLeftBehind(settings: DesktopProxyStore(), restoreFile: restoreFile)
            }
        }
        return nil
    }

    /// The watcher: waits for Reqly, process `pid`, to end, then puts your settings back with
    /// `restore`, and removes `loginEntry` once the restore file is gone. It quits without doing
    /// anything once the restore file goes, or another takes its place, since capture stopped as
    /// it should, or a newer watcher has it. Checks once a second.
    static func watch(
        pid: pid_t, restoreFile: URL, loginEntry: LoginEntry? = nil, restore: () throws -> Bool
    ) -> Int32 {
        func restoreAndTidy() -> Int32 {
            let status = restoreNow(restore)
            if status == 0, fileIdentity(restoreFile) == nil {
                loginEntry?.remove()
            }
            return status
        }
        let pidfd = reqly_pidfd_open(pid)
        if pidfd == -ESRCH {
            // Reqly has already gone.
            return restoreAndTidy()
        }
        defer {
            if pidfd >= 0 {
                close(pidfd)
            }
        }
        guard let watched = fileIdentity(restoreFile) else { return 0 }
        while true {
            let ended: Bool
            switch pidfd >= 0 ? reqly_pidfd_wait(pidfd, 1000) : -1 {
            case 1: ended = true
            case 0: ended = false
            default:
                // Without a pidfd, a reused process ID could keep it waiting, but it still quits
                // when the restore file goes.
                Thread.sleep(forTimeInterval: 1)
                ended = kill(pid, 0) != 0 && errno == ESRCH
            }
            if ended {
                return restoreAndTidy()
            }
            if fileIdentity(restoreFile) != watched {
                return 0
            }
        }
    }

    /// The login entry's run: unless Reqly is running, which keeps it, puts your settings back,
    /// with `restore` in the tests, then removes the entry.
    static func restoreAtLogin(
        restoreFile: URL, loginEntry: LoginEntry, appName: String = appName, restore: () throws -> Bool
    ) -> Int32 {
        if (try? SessionBus.nameHasOwner(appName)) == true {
            return 0
        }
        let status = restoreNow(restore)
        if status == 0 {
            loginEntry.remove()
        }
        return status
    }

    private static func restoreNow(_ restore: () throws -> Bool) -> Int32 {
        do {
            if try restore() {
                log("put back the proxy settings Reqly left")
            }
            return 0
        } catch {
            log("couldn't put back the proxy settings: \(error)")
            return 1
        }
    }

    /// Which file is at `url`, by its device and inode, or `nil` when there's none.
    private static func fileIdentity(_ url: URL) -> [UInt64]? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return [UInt64(status.st_dev), UInt64(status.st_ino)]
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("Reqly: \(message)\n".utf8))
    }
}

/// Your desktop's proxy switch: the core's ``UserProxySwitch`` over GNOME's and KDE's settings,
/// with a ``ProxyGuard`` that puts them back if Reqly can't.
public actor DesktopProxySwitch: SystemProxySwitch {
    private let proxySwitch: UserProxySwitch<DesktopProxyStore>
    public nonisolated let guardian: ProxyGuard

    public init(store: DesktopProxyStore = DesktopProxyStore(), guardian: ProxyGuard) {
        proxySwitch = UserProxySwitch(settings: store, restoreFile: guardian.restoreFile)
        self.guardian = guardian
    }

    public func enable(port: Int) async throws {
        try await proxySwitch.enable(port: port)
        guardian.captureStarted()
    }

    public func disable() async throws {
        try await proxySwitch.disable()
        guardian.captureStopped()
    }

    /// Puts back settings a Reqly that quit unexpectedly left, as Reqly starts, and removes their
    /// login entry. Returns whether it put any back.
    public static func restoreLeftBehind(
        store: DesktopProxyStore = DesktopProxyStore(), guardian: ProxyGuard
    ) throws -> Bool {
        let restored = try UserProxySwitch.restoreLeftBehind(settings: store, restoreFile: guardian.restoreFile)
        guardian.captureStopped()
        return restored
    }
}
