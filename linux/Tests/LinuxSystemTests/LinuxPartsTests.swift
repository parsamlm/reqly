import CoreInterface
import Foundation
import LinuxApps
import LinuxDesktop
import LinuxSystem
import LinuxTrust
import ReqlyModel
import Testing

/// Sessions with Linux's own parts, through the stand-ins test runs of the app ask for, so the
/// computer's proxy settings, certificates and keyring are never touched.
@Suite struct LinuxPartsTests {
    /// Settings someone had before Reqly: GNOME through their office's proxy, and KDE's file.
    static let yours = DesktopProxySettings(
        gnome: GNOMEProxy(
            mode: .set("manual"), httpHost: .set("proxy.office.example"), httpPort: .set(3128),
            httpsHost: .set("proxy.office.example"), httpsPort: .set(3128)),
        kde: KDEProxy(fileExists: true, proxyType: "1", httpProxy: "http://proxy.office.example 3128"))

    /// The whole of it, as a test run of the app goes: the session points the stand-in for your
    /// desktop's proxy setting at Reqly, a request from this process goes through Reqly to a
    /// server on this computer, the app lookup names this process as what sent it, and stopping
    /// puts your settings back as they were.
    @Test func capturesARequestNamesThisProcessAndPutsYourSettingsBack() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let standIn = folder.appending(path: "Desktop proxy settings.json")
        let restore = folder.appending(path: "State/ProxyRestore.json")
        let desktop = DesktopProxyStandIn(file: standIn)
        try desktop.write(Self.yours)
        let server = try OkServer()
        defer { server.stop() }

        let log = EventLog()
        let options = OpenOptions(
            sessionsFolder: folder.appending(path: "Sessions").path, setsSystemProxy: true,
            proxyRestoreFile: restore.path, proxySettingsStandIn: standIn.path, findsApps: true,
            rootStandIn: folder.appending(path: "Root.plist").path)
        let host = try await SessionHost.open(options, system: .linux, send: log.record)
        let started = try result(await call(host, #"{"call":"startCapturing","port":0}"#))
        let port = try #require(started["port"] as? Int)
        let pointed = try desktop.read()
        #expect(pointed.pointsAtReqly(port: port))
        #expect(pointed.gnome?.mode.value == "manual" && pointed.gnome?.httpHost.value == GNOMEProxy.reqlyHost)
        #expect(pointed.kde?.httpProxy == KDEProxy.reqlyProxy(port: port))
        #expect(FileManager.default.fileExists(atPath: restore.path))

        // The connection stays open, as an app's to its proxy does, since the kernel names a
        // socket's owner only while it's open.
        let client = try await onOwnThread { try Loopback.connect(to: port) }
        defer { close(client) }
        let origin = "127.0.0.1:\(server.port)"
        let answer = await onOwnThread {
            Loopback.write("GET http://\(origin)/forecast HTTP/1.1\r\nHost: \(origin)\r\n\r\n", to: client)
            return Loopback.read(from: client) { $0.hasSuffix("\r\n\r\nok") }
        }
        #expect(answer.hasPrefix("HTTP/1.1 200") && answer.hasSuffix("ok"), "\(answer.prefix(300))")

        let id = try #require(
            await log.wait { event in
                (event["steps"] as? [[String: Any]])?.contains { $0["inserted"] != nil } == true
            }.flatMap { event in
                (event["steps"] as? [[String: Any]])?.compactMap { $0["inserted"] as? [[String: Any]] }.first?
                    .first?["id"] as? Int
            })
        // The app shows once the connection's owner is found, and the response once it's in.
        var row: [String: Any]?
        for _ in 0..<100 {
            let rows = try result(await call(host, #"{"call":"rows","ids":[\#(id)]}"#))["rows"] as? [[String: Any]]
            if let first = rows?.first, first["app"] != nil, first["status"] as? Int == 200 {
                row = first
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let found = try #require(row, "The request wasn't recorded with its app and response.")
        let program = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #expect(found["appPath"] as? String == program)
        #expect(found["app"] as? String == URL(filePath: program).lastPathComponent)
        #expect(found["host"] as? String == "127.0.0.1" && found["port"] as? Int == server.port)
        #expect(found["target"] as? String == "/forecast")

        _ = try result(await call(host, #"{"call":"stopCapturing"}"#))
        #expect(try desktop.read() == Self.yours)
        #expect(!FileManager.default.fileExists(atPath: restore.path))
        await host.close()
    }

    /// Without a stand-in, the switch is the desktop's own, with the guard that puts your
    /// settings back if Reqly ends while it captures. Making it changes nothing.
    @Test func switchesTheDesktopsOwnSettingsWithTheGuard() throws {
        let restore = URL(filePath: "/nowhere/ProxyRestore.json")
        let own = try #require(SystemParts.linux.proxySwitch(restore, nil) as? DesktopProxySwitch)
        #expect(own.guardian.restoreFile == restore)
        #expect(
            SystemParts.linux.proxySwitch(restore, URL(filePath: "/nowhere/standIn.json"))
                is UserProxySwitch<DesktopProxyStandIn>)
    }

    /// The certificate's key goes in the keyring, or the file the session names, with its other
    /// files beside it; the helper is the installed one unless a development build names its own.
    @Test func keepsTheCertificateBesideTheFileTheSessionNames() throws {
        let file = LinuxFolders(environment: ["HOME": "/home/ana"]).rootFile
        #expect(file.path == "/home/ana/.local/share/reqly/Certificate.dat")
        let store = try #require(SystemParts.linux.rootStore?(file) as? LinuxRootStore)
        #expect(store.file == file && store.keys.file == file)
        #expect(store.pemFile.path == "/home/ana/.local/share/reqly/Reqly CA.pem")
        #expect(store.helper.path == TrustHelper.installedPath)
        let development = try #require(
            SystemParts.linux(trustHelper: "/src/linux/packaging/reqly-trust").rootStore?(file) as? LinuxRootStore)
        #expect(development.helper.path == "/src/linux/packaging/reqly-trust")
    }

    /// A test run's secrets go in a plain file, in the same JSON as Windows'; the app's go in the
    /// keyring, or in a file only you can read.
    @Test func keepsSecretsInTheKeyringOrTheirFile() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Secrets.json")
        let secrets = ["Reqly Upstream Proxy/password": Data("hunter2".utf8)]
        let plain = try #require(SystemParts.linux.secrets(file, false) as? KeyringSecrets)
        #expect(plain.file == file && !plain.isProtected)
        try plain.save(secrets)
        #expect(try SystemParts.linux.secrets(file, false).load() == secrets)
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"Reqly Upstream Proxy/password":"aHVudGVyMg=="}"#)

        let protected = try #require(SystemParts.linux.secrets(file, true) as? KeyringSecrets)
        #expect(protected.isProtected)
        #expect((protected.keyring as? SecretServiceKeyring)?.item == .secrets)
    }

    /// The Devices window gets this computer's addresses from LinuxApps. 192.0.2.1 is kept for
    /// examples, so no network has it, and no neighbor's hardware address is known for it.
    @Test func givesThisComputersAddresses() {
        let addresses = SystemParts.linux.networkAddresses()
        #expect(addresses == NetworkAddresses.current().map { .init(interface: $0.interface, address: $0.address) })
        for address in addresses {
            #expect(address.address.split(separator: ".").count == 4 && !address.address.hasPrefix("127."))
        }
        #expect(SystemParts.linux.hardwareAddress("192.0.2.1") == nil)
    }
}
