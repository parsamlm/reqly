import CLinux
import Foundation
import ReqlyModel
import Testing

@testable import LinuxDesktop

/// GNOME's settings through GSettings' memory back end, which `gsettings-desktop-schemas`'
/// schema describes, as on a desktop, and KDE's in a file of the test's own. GSettings keeps one
/// memory for the process, so these run one at a time, each from GNOME's defaults.
@Suite(.serialized) struct DesktopProxyStoreTests {
    init() throws {
        TestEnvironment.prepare()
        try #require(GNOMEProxyStore.isInstalled)
        try GNOMEProxyStore().write(GNOMEProxy())
    }

    @Test func readsGNOMEsDefaults() throws {
        let read = try #require(try GNOMEProxyStore().read())
        #expect(read == GNOMEProxy())
        #expect(read.mode == GSettingsValue("none", isDefault: true))
        #expect(read.httpPort == GSettingsValue(8080, isDefault: true))
    }

    @Test func pointsGNOMEAtReqlyAndReadsItBack() throws {
        let store = GNOMEProxyStore()
        let capturing = try #require(try store.read()).capturing(port: 9090)
        try store.write(capturing)
        let read = try #require(try store.read())
        #expect(read == capturing)
        #expect(read.pointsAtReqly(port: 9090))
        #expect(!read.pointsAtReqly(port: 9091))
        #expect(read.httpHost == .set("127.0.0.1"))
        #expect(read.httpsPort == .set(9090))
    }

    /// A key you set to its default value is still yours, and stays set; keys that were at
    /// their defaults are reset, so they follow the default again.
    @Test func remembersWhichKeysWereYours() throws {
        let store = GNOMEProxyStore()
        let yours = GNOMEProxy(mode: .set("none"), httpHost: .set("proxy.corp"), httpPort: .set(3128))
        try store.write(yours)
        #expect(try store.read() == yours)

        try store.write(yours.capturing(port: 9090))
        try store.write(yours)
        let back = try #require(try store.read())
        #expect(back == yours)
        #expect(!back.mode.isDefault)
        #expect(back.httpsHost.isDefault && back.httpsPort.isDefault)
    }

    @Test func leavesKeysItDoesntChange() throws {
        let store = GNOMEProxyStore()
        try store.write(GNOMEProxy(httpHost: .set("proxy.corp")))
        // Only the mode differs, so only the mode is written.
        try store.write(GNOMEProxy(mode: .set("auto"), httpHost: .set("proxy.corp")))
        #expect(try store.read() == GNOMEProxy(mode: .set("auto"), httpHost: .set("proxy.corp")))
    }

    /// Each change to KDE's file tells running apps, with KIO's signal.
    @Test func switchesGNOMEAndKDEAndPutsThemBack() async throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let signals = try KDESignals(folder: folder)
        let rc = folder.appending(path: "kioslaverc")
        let original = "[Proxy Settings]\nNoProxyFor=localhost\nProxyType=0\n"
        try Data(original.utf8).write(to: rc)
        let kde = KDEProxyStore(file: rc)
        let store = DesktopProxyStore(
            gnome: GNOMEProxyStore(), kde: kde, desktop: SessionDesktop(currentDesktop: "KDE"))
        let restoreFile = folder.appending(path: "ProxyRestore.json")
        let proxy = UserProxySwitch(settings: store, restoreFile: restoreFile)

        try await proxy.enable(port: 9090)
        let capturing = try store.read()
        #expect(capturing.gnome?.pointsAtReqly(port: 9090) == true)
        #expect(capturing.kde?.pointsAtReqly(port: 9090) == true)
        #expect(
            try String(contentsOf: rc, encoding: .utf8)
                == "[Proxy Settings]\nNoProxyFor=localhost\nProxyType=1\nhttpProxy=http://127.0.0.1 9090\nhttpsProxy=http://127.0.0.1 9090\n"
        )
        #expect(signals.wait(for: 1))

        try await proxy.disable()
        #expect(try store.read().gnome == GNOMEProxy())
        #expect(try String(contentsOf: rc, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: restoreFile.path))
        #expect(signals.wait(for: 2))
        // No more come.
        try await Task.sleep(for: .milliseconds(300))
        #expect(signals.count == 2)
    }

    /// You turned GNOME's proxy off yourself while Reqly captured: that stays, and KDE's, still
    /// Reqly's, goes back.
    @Test func putsBackOnlyThePartStillPointingAtReqly() async throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var kde = KDEProxyStore(file: folder.appending(path: "kioslaverc"))
        kde.tellsApps = false
        let gnome = GNOMEProxyStore()
        let store = DesktopProxyStore(gnome: gnome, kde: kde, desktop: SessionDesktop(currentDesktop: "KDE"))
        let restoreFile = folder.appending(path: "ProxyRestore.json")
        let proxy = UserProxySwitch(settings: store, restoreFile: restoreFile)
        try await proxy.enable(port: 9090)
        let yoursSince = GNOMEProxy(mode: .set("none"), httpHost: .set("127.0.0.1"), httpPort: .set(9090))
        try gnome.write(yoursSince)

        // As after a crash.
        #expect(try UserProxySwitch.restoreLeftBehind(settings: store, restoreFile: restoreFile))
        #expect(try gnome.read() == yoursSince)
        // Reqly made kioslaverc, so it's gone again.
        #expect(!kde.fileExists)
        #expect(try store.read().kde == KDEProxy(fileExists: false))
    }

    @Test func leavesKDEOutAwayFromKDEWithNoFile() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var kde = KDEProxyStore(file: folder.appending(path: "kioslaverc"))
        kde.tellsApps = false
        let store = DesktopProxyStore(
            gnome: GNOMEProxyStore(), kde: kde, desktop: SessionDesktop(currentDesktop: "ubuntu:GNOME"))
        #expect(!store.usesKDE)
        let settings = try store.read()
        #expect(settings.kde == nil)
        try store.write(settings.capturing(port: 9090))
        #expect(!kde.fileExists)
        #expect(try store.read().pointsAtReqly(port: 9090))
    }

    @Test func emitsKDEsSignalAndAsksWhoOwnsAName() throws {
        try #require(TestEnvironment.sessionBus != nil)
        try SessionBus.emit(
            path: "/KIO/Scheduler", interface: "org.kde.KIO.Scheduler", member: "reparseSlaveConfiguration", string: "")
        // The bus itself always has its name.
        #expect(try SessionBus.nameHasOwner("org.freedesktop.DBus"))
        #expect(try !SessionBus.nameHasOwner(ProxyGuard.appName))
        #expect(ProxyGuard.isRunning(appName: "org.freedesktop.DBus"))
        #expect(!ProxyGuard.isRunning())
    }

    /// The session says what went wrong with each error's localized description, which on Linux
    /// says only "The operation could not be completed" unless the error says more.
    @Test func saysWhatWentWrongInSentences() {
        #expect(
            GNOMEProxyStore.Locked(keys: ["org.gnome.system.proxy mode"]).localizedDescription
                == "An administrator has locked your proxy settings (org.gnome.system.proxy mode).")
        #expect(GLibError(message: "There's no session bus").localizedDescription == "There's no session bus.")
        #expect(
            TimeLimit.Exceeded(what: "changing GNOME's proxy setting", seconds: 10).localizedDescription
                == "Changing GNOME's proxy setting took longer than 10 seconds, so Reqly stopped waiting.")
        #expect(
            Programs.Failure(program: "/usr/bin/ptyxis", code: ENOENT).localizedDescription
                == "Reqly couldn't start /usr/bin/ptyxis: No such file or directory.")
    }

    /// When KDE's setting can't be changed, capturing doesn't start: your settings stay as they
    /// were, the login entry goes again, and the reason reads as a sentence.
    @Test func leavesNoLoginEntryWhenTheSettingCantChange() async throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A file where KDE's folder should be.
        let blocked = folder.appending(path: "config")
        try Data().write(to: blocked)
        var kde = KDEProxyStore(file: blocked.appending(path: "kioslaverc"))
        kde.tellsApps = false
        let store = DesktopProxyStore(gnome: nil, kde: kde, desktop: SessionDesktop(currentDesktop: "KDE"))
        let guardian = ProxyGuard(
            restoreFile: folder.appending(path: "ProxyRestore.json"),
            environment: ["HOME": folder.path, "XDG_CONFIG_HOME": folder.path], executable: "/bin/false")
        let proxySwitch = DesktopProxySwitch(store: store, guardian: guardian)
        do {
            try await proxySwitch.enable(port: 9090)
            Issue.record("Capturing started with a setting that can't change.")
        } catch {
            #expect(error.localizedDescription == "Reqly couldn't make the folder for \(kde.file.path).")
        }
        #expect(!guardian.loginEntry.exists)
        #expect(!FileManager.default.fileExists(atPath: guardian.restoreFile.path))
    }
}

/// KIO's signal on the tests' session bus, as dbus-monitor hears it: path `/KIO/Scheduler`,
/// interface `org.kde.KIO.Scheduler`, member `reparseSlaveConfiguration`, and one empty string.
final class KDESignals {
    private let monitor: pid_t
    private let file: URL

    static let heard = """
        path=/KIO/Scheduler; interface=org.kde.KIO.Scheduler; member=reparseSlaveConfiguration
           string ""
        """

    /// Starts listening, with dbus-monitor's output in `folder`, and returns once it listens.
    init(folder: URL) throws {
        let bus = try #require(TestEnvironment.sessionBus)
        file = folder.appending(path: "signals.txt")
        let output = open(file.path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o600)
        try #require(output >= 0)
        defer { close(output) }
        // Started as Reqly starts programs, so it gets signals as usual and none of the tests'
        // descriptors but its output.
        let arguments = ["/usr/bin/dbus-monitor", "--session", "type='signal',interface='org.kde.KIO.Scheduler'"]
        let copies = arguments.map { strdup($0) } + [nil]
        let environment = [strdup("DBUS_SESSION_BUS_ADDRESS=\(bus)"), nil]
        defer { (copies + environment).forEach { free($0) } }
        monitor = reqly_spawn_detached(arguments[0], copies, environment, output)
        try #require(monitor > 0)
        // The bus tells it once it's a monitor.
        try #require(wait { $0.contains("member=NameLost") }, "dbus-monitor didn't start listening.")
    }

    deinit {
        stop()
    }

    /// How many signals it heard.
    var count: Int {
        text.components(separatedBy: Self.heard).count - 1
    }

    /// Waits up to five seconds for `count` signals.
    func wait(for count: Int) -> Bool {
        wait { $0.components(separatedBy: Self.heard).count - 1 >= count }
    }

    func stop() {
        kill(monitor, SIGKILL)
        _ = Programs.wait(for: monitor, seconds: 5)
    }

    private var text: String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private func wait(until done: (String) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !done(text) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}
