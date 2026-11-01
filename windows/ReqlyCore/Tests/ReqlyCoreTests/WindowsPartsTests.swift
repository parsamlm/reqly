import CertificateAuthority
import Foundation
import ProxyEngine
import ReqlyCore
import ReqlyModel
import Testing
import WindowsSystem

@testable import CoreInterface

/// Sessions with Windows' own parts, through the stand-ins test runs of the app ask for, so the
/// computer's proxy settings and certificate stores are never touched.
@Suite struct WindowsPartsTests {
    /// The whole switch, from the session down, on a stand-in for Windows' proxy settings.
    @Test func switchesTheProxyEachTimeCapturingStarts() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let standIn = folder.appending(path: "Windows proxy settings.json")
        let restore = folder.appending(path: "ProxyRestore.json")
        let options = OpenOptions(
            sessionsFolder: folder.appending(path: "Sessions").path, setsSystemProxy: true,
            proxyRestoreFile: restore.path, proxySettingsStandIn: standIn.path, findsApps: false)
        let host = try await SessionHost.open(options, send: { _ in })
        let windows = FileProxySettings<ProxySettings>(file: standIn)
        for round in 0..<3 {
            let started = try result(await call(host, #"{"call":"startCapturing","port":0}"#))
            let port = try #require(started["port"] as? Int, "round \(round)")
            #expect(try windows.read().pointsAtReqly(port: port))
            #expect(FileManager.default.fileExists(atPath: restore.path))
            _ = try result(await call(host, #"{"call":"stopCapturing"}"#))
            #expect(try windows.read() == ProxySettings())
            #expect(!FileManager.default.fileExists(atPath: restore.path))
        }
        await host.close()
    }

    /// The Devices window gets this PC's network addresses from Windows, and a device that asks is
    /// told apart by its hardware address when Windows' table of neighbors has it. Nothing listens
    /// on the network: the session doesn't capture.
    @Test func asksAboutADeviceWithWindowsAddresses() async throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EventLog()
        let host = try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), send: log.record)
        let file = folder.appending(path: "Devices.json").path(percentEncoded: false)
        let opening = try JSONSerialization.data(withJSONObject: ["call": "openDevices", "path": file])
        let devices = try result(await host.reply(to: opening))
        let addresses = try #require(devices["addresses"] as? [[String: String]])
        #expect(addresses == NetworkAddresses.current().map { ["interface": $0.interface, "address": $0.address] })
        for address in addresses.compactMap({ $0["address"] }) {
            #expect(address.split(separator: ".").count == 4 && !address.hasPrefix("127."), "\(address)")
        }

        // 192.0.2.1 is kept for examples, so no network has it and Windows knows no hardware
        // address for it.
        #expect(NetworkNeighbors.hardwareAddress(of: "192.0.2.1") == nil)
        _ = try result(await call(host, #"{"call":"setAllowsNetworkDevices","isOn":true}"#))
        let asking = Task { await host.admit(ClientAddress(ip: "192.0.2.1", port: 50_000)) }
        let event = try #require(await log.wait { $0["event"] as? String == "deviceWaiting" })
        #expect(event["id"] as? String == "ip:192.0.2.1")
        _ = try result(await call(host, #"{"call":"decideDevice","device":"ip:192.0.2.1","allow":true}"#))
        #expect(await asking.value == true)
        await host.close()
    }

    /// A test run's secrets go in a plain file; the app's go in one Windows encrypts.
    @Test func keepsSecretsInTheSecretsFile() throws {
        let file = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)/Secrets.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let plain = try #require(SystemParts.windows.secrets(file, false) as? SecretFile)
        #expect(plain.file == file && !plain.isProtected)
        let secrets = ["Reqly Upstream Proxy/password": Data("hunter2".utf8)]
        try plain.save(secrets)
        #expect(try SystemParts.windows.secrets(file, false).load() == secrets)
        #expect((SystemParts.windows.secrets(file, true) as? SecretFile)?.isProtected == true)
    }

    /// Uninstalling a test run removes its stand-in certificate, through the C function.
    @Test func removesAStandInCertificate() throws {
        let file = URL.temporaryDirectory.appending(path: "ReqlyRootRemoval-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        try FileRootStore(file: file).save(RootIdentity.create())
        let path = file.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        #expect(reqlyRemoveRoot(path, 1) == RootRemoval.removed.rawValue)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(reqlyRemoveRoot(path, 1) == RootRemoval.nothing.rawValue)
    }
}
