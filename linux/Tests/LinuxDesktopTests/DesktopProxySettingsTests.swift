import Foundation
import ReqlyModel
import Testing

@testable import LinuxDesktop

@Suite struct DesktopProxySettingsTests {
    /// Someone's settings: a company proxy in GNOME's, and KDE's off, in a file they had.
    static let yours = DesktopProxySettings(
        gnome: GNOMEProxy(mode: .set("manual"), httpHost: .set("proxy.corp"), httpPort: .set(3128)),
        kde: KDEProxy(fileExists: true, proxyType: "0"))

    @Test func pointsEachPartAtReqly() {
        let capturing = Self.yours.capturing(port: 9090)
        #expect(capturing.gnome?.pointsAtReqly(port: 9090) == true)
        #expect(capturing.kde?.pointsAtReqly(port: 9090) == true)
        #expect(capturing.kde?.httpsProxy == "http://127.0.0.1 9090")
        #expect(capturing.kde?.fileExists == true)
        #expect(capturing.pointsAtReqly(port: 9090))
        #expect(!capturing.pointsAtReqly(port: 9091))
        #expect(!Self.yours.pointsAtReqly(port: 9090))
        // Parts that aren't there stay out.
        #expect(
            DesktopProxySettings(gnome: nil, kde: nil).capturing(port: 9090)
                == DesktopProxySettings(gnome: nil, kde: nil))
    }

    @Test func knowsKDEsWaysOfWritingReqly() {
        #expect(
            KDEProxy(
                fileExists: true, proxyType: "1", httpProxy: "http://127.0.0.1:9090",
                httpsProxy: "http://127.0.0.1 9090"
            )
            .pointsAtReqly(port: 9090))
        #expect(
            !KDEProxy(
                fileExists: true, proxyType: "0", httpProxy: "http://127.0.0.1 9090",
                httpsProxy: "http://127.0.0.1 9090"
            )
            .pointsAtReqly(port: 9090))
        #expect(
            !KDEProxy(fileExists: true, proxyType: "1", httpProxy: "http://127.0.0.1 9090").pointsAtReqly(port: 9090))
    }

    @Test func putsBackEachPartOnItsOwn() {
        let capturing = Self.yours.capturing(port: 9090)
        // Both still Reqly's: both go back.
        #expect(capturing.restoring(Self.yours, port: 9090) == Self.yours)

        // You changed GNOME's mode since: it stays, Reqly's hosts there go back, and KDE's goes back.
        var gnomeChanged = capturing
        gnomeChanged.gnome?.mode = .set("none")
        var gnomeOff = Self.yours.gnome
        gnomeOff?.mode = .set("none")
        #expect(
            gnomeChanged.restoring(Self.yours, port: 9090) == DesktopProxySettings(gnome: gnomeOff, kde: Self.yours.kde)
        )

        // You changed KDE's type since: it stays, and the rest goes back.
        var kdeChanged = capturing
        kdeChanged.kde?.proxyType = "2"
        var kdeScript = Self.yours.kde
        kdeScript?.proxyType = "2"
        #expect(
            kdeChanged.restoring(Self.yours, port: 9090)
                == DesktopProxySettings(gnome: Self.yours.gnome, kde: kdeScript))

        // Neither is Reqly's any more, or not for this port: nothing to do.
        #expect(Self.yours.restoring(Self.yours, port: 9090) == nil)
        #expect(capturing.restoring(Self.yours, port: 9091) == nil)
    }

    /// You changed one key while Reqly captured, the HTTP proxy's port: it stays, with manual mode,
    /// which it needs, and Reqly's HTTPS host and port go back, so none points at Reqly's port
    /// once it's closed.
    @Test func putsBackEachKeyStillReqlys() throws {
        let yours = GNOMEProxy()
        var changed = yours.capturing(port: 9090)
        changed.httpPort = .set(3128)
        let restored = try #require(changed.restoring(yours, port: 9090))
        #expect(restored.mode == .set("manual"))
        #expect(restored.httpHost == .set("127.0.0.1") && restored.httpPort == .set(3128))
        #expect(restored.httpsHost == yours.httpsHost && restored.httpsPort == yours.httpsPort)
        // Only the mode left of Reqly's, since you changed both proxies: it stays too.
        var both = changed
        both.httpsHost = .set("proxy.corp")
        #expect(both.restoring(yours, port: 9090) == nil)

        // KDE's, the same way.
        let kde = KDEProxy(fileExists: true, proxyType: "0")
        var kdeChanged = kde.capturing(port: 9090)
        kdeChanged.httpProxy = "http://proxy.corp 3128"
        #expect(
            kdeChanged.restoring(kde, port: 9090)
                == KDEProxy(fileExists: true, proxyType: "1", httpProxy: "http://proxy.corp 3128"))
        // Reqly's proxy written with a colon, as KDE also reads it, is still Reqly's.
        var colon = kde.capturing(port: 9090)
        colon.httpsProxy = "http://127.0.0.1:9090"
        #expect(colon.restoring(kde, port: 9090) == kde)
    }

    /// A SOCKS or FTP proxy you left behind with another mode, which manual mode would switch
    /// on, is cleared while Reqly captures, and comes back after. One you use, in manual mode,
    /// stays.
    @Test func clearsDormantSOCKSAndFTPProxiesWhileCapturing() throws {
        let dormant = GNOMEProxy(socksHost: .set("socks.example.test"), ftpHost: .set("ftp.example.test"))
        let capturing = dormant.capturing(port: 9090)
        #expect(capturing.socksHost == GSettingsValue("", isDefault: true))
        #expect(capturing.ftpHost == GSettingsValue("", isDefault: true))
        #expect(capturing.restoring(dormant, port: 9090) == dormant)
        let used = GNOMEProxy(mode: .set("manual"), socksHost: .set("socks.example.test"))
        #expect(used.capturing(port: 9090).socksHost == .set("socks.example.test"))

        let kde = KDEProxy(
            fileExists: true, proxyType: "0", others: .init(ftp: "ftp://ftp.example.test 21", socks: ""))
        let kdeCapturing = kde.capturing(port: 9090)
        #expect(kdeCapturing.others == .init(ftp: "", socks: ""))
        #expect(kdeCapturing.restoring(kde, port: 9090) == kde)
        #expect(
            KDEProxy(fileExists: true, proxyType: "1", others: .init(socks: "socks://s 1080")).capturing(port: 9090)
                .others == .init(socks: "socks://s 1080"))
    }

    /// A restore file an earlier Reqly wrote has no SOCKS, FTP or other proxies: they're left as
    /// they are, and the rest goes back.
    @Test func readsAnEarlierReqlysRestoreFile() throws {
        let earlier = Data(
            #"""
            {"gnome":{"mode":{"value":"none","isDefault":true},"httpHost":{"value":"","isDefault":true},\#
            "httpPort":{"value":8080,"isDefault":true},"httpsHost":{"value":"","isDefault":true},\#
            "httpsPort":{"value":0,"isDefault":true}},"kde":{"fileExists":true,"proxyType":"0"}}
            """#.utf8)
        let yours = try JSONDecoder().decode(DesktopProxySettings.self, from: earlier)
        #expect(yours.gnome?.socksHost == nil && yours.gnome?.ftpHost == nil && yours.kde?.others == nil)
        var now = DesktopProxySettings(
            gnome: GNOMEProxy(socksHost: .set("socks.example.test")),
            kde: KDEProxy(fileExists: true, proxyType: "0", others: .init(ftp: "ftp://f 21")))
        now = now.capturing(port: 9090)
        now.gnome?.socksHost = .set("socks.example.test")
        now.kde?.others = .init(ftp: "ftp://f 21")
        let restored = try #require(now.restoring(yours, port: 9090))
        #expect(restored.gnome?.socksHost == .set("socks.example.test"))
        #expect(restored.gnome?.mode == GSettingsValue("none", isDefault: true))
        #expect(restored.kde?.others == .init(ftp: "ftp://f 21"))
        #expect(restored.kde?.proxyType == "0")
    }

    /// Test runs keep the same settings in a file, through the same switch.
    @Test func runsTheSwitchOnTheStandIn() async throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let standIn = DesktopProxyStandIn(file: folder.appending(path: "ProxySettings.json"))
        #expect(try standIn.read() == .noProxy)
        let proxy = UserProxySwitch(settings: standIn, restoreFile: folder.appending(path: "ProxyRestore.json"))
        try await proxy.enable(port: 9090)
        #expect(try standIn.read().pointsAtReqly(port: 9090))
        try await proxy.disable()
        #expect(try standIn.read() == .noProxy)
    }

    /// The restore file holds the settings as JSON that a later Reqly reads again.
    @Test func keepsTheSettingsAsJSON() throws {
        let data = try JSONEncoder().encode(Self.yours)
        #expect(try JSONDecoder().decode(DesktopProxySettings.self, from: data) == Self.yours)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let gnome = try #require(object["gnome"] as? [String: Any])
        let mode = try #require(gnome["mode"] as? [String: Any])
        #expect(mode["value"] as? String == "manual")
        #expect(mode["isDefault"] as? Bool == false)
    }
}

@Suite struct KDEProxyStoreTests {
    static func store(in folder: URL) -> KDEProxyStore {
        var store = KDEProxyStore(file: folder.appending(path: "config/kioslaverc"))
        store.tellsApps = false
        return store
    }

    @Test func makesTheFileAndRemovesItAgain() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Self.store(in: folder)
        let yours = try store.read()
        #expect(yours == KDEProxy(fileExists: false))
        try store.write(yours.capturing(port: 9090))
        #expect(
            try String(contentsOf: store.file, encoding: .utf8)
                == "[Proxy Settings]\nProxyType=1\nhttpProxy=http://127.0.0.1 9090\nhttpsProxy=http://127.0.0.1 9090\n")
        // Only you can read a file Reqly makes, as with KDE's own.
        #expect(try Self.mode(store.file) == 0o600)
        try store.write(yours)
        #expect(!store.fileExists)
    }

    @Test func keepsAFileSomethingElseAddedTo() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Self.store(in: folder)
        try store.write(KDEProxy(fileExists: false).capturing(port: 9090))
        var text = try String(contentsOf: store.file, encoding: .utf8)
        text += "\n[Cache]\nCacheSize=1\n"
        try Data(text.utf8).write(to: store.file)
        try store.write(KDEProxy(fileExists: false))
        #expect(try String(contentsOf: store.file, encoding: .utf8) == "[Cache]\nCacheSize=1\n")
    }

    @Test func keepsTheFilesPermissions() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Self.store(in: folder)
        try FileManager.default.createDirectory(
            at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[Proxy Settings]\nProxyType=0\n".utf8).write(to: store.file)
        chmod(store.file.path, 0o640)
        try store.write(try store.read().capturing(port: 9090))
        #expect(try Self.mode(store.file) == 0o640)
        #expect(try store.read().pointsAtReqly(port: 9090))
    }

    @Test func writesThroughALink() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Self.store(in: folder)
        let real = folder.appending(path: "dotfiles-kioslaverc")
        try Data("[Proxy Settings]\nProxyType=0\n".utf8).write(to: real)
        try FileManager.default.createDirectory(
            at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: real)
        try store.write(try store.read().capturing(port: 9090))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.file.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("ProxyType=1"))
    }

    @Test func refusesALockedSetting() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var store = Self.store(in: folder)
        let system = folder.appending(path: "etc-xdg-kioslaverc")
        try Data("[Proxy Settings][$i]\nProxyType=0\n".utf8).write(to: system)
        store.systemFiles = [system]
        #expect(throws: GNOMEProxyStore.Locked.self) {
            try store.write(KDEProxy(fileExists: false).capturing(port: 9090))
        }
        #expect(!store.fileExists)
    }

    @Test func findsItsFilesFromTheEnvironment() {
        let store = KDEProxyStore(environment: ["HOME": "/home/ana", "XDG_CONFIG_DIRS": "/etc/xdg/xdg-plasma:/etc/xdg"])
        #expect(store.file.path == "/home/ana/.config/kioslaverc")
        #expect(store.systemFiles.map(\.path) == ["/etc/xdg/xdg-plasma/kioslaverc", "/etc/xdg/kioslaverc"])
        let moved = KDEProxyStore(environment: ["HOME": "/home/ana", "XDG_CONFIG_HOME": "/data/config"])
        #expect(moved.file.path == "/data/config/kioslaverc")
        #expect(moved.systemFiles.map(\.path) == ["/etc/xdg/kioslaverc"])
    }

    static func mode(_ file: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
    }
}
