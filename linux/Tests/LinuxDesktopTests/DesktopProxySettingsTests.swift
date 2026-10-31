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

        // You changed GNOME's since: it stays, and KDE's goes back.
        var gnomeChanged = capturing
        gnomeChanged.gnome?.mode = .set("none")
        #expect(
            gnomeChanged.restoring(Self.yours, port: 9090)
                == DesktopProxySettings(gnome: gnomeChanged.gnome, kde: Self.yours.kde))

        // You changed KDE's since: it stays, and GNOME's goes back.
        var kdeChanged = capturing
        kdeChanged.kde?.proxyType = "0"
        #expect(
            kdeChanged.restoring(Self.yours, port: 9090)
                == DesktopProxySettings(gnome: Self.yours.gnome, kde: kdeChanged.kde))

        // Neither is Reqly's any more, or not for this port: nothing to do.
        #expect(Self.yours.restoring(Self.yours, port: 9090) == nil)
        #expect(capturing.restoring(Self.yours, port: 9091) == nil)
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
