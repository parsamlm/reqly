import CoreInterface
import DeviceBridge
import Foundation
import ReqlyModel
import Testing

/// The typed helpers the Linux app calls, which the Mac's and Windows' apps don't need: adb and
/// the lowest port from the system's parts, the proxy port's check, the rows to export, Map Local's
/// response file, a draft's body as text and a script's problem with its line.
@Suite struct SessionHelpersTests {
    static func open(_ folder: URL, system: SystemParts = .standIns) async throws -> SessionHost {
        try await SessionHost.open(
            OpenOptions(sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false), system: system,
            events: { _ in })
    }

    static func openConnections(_ host: SessionHost, in folder: URL) async -> ConnectionsState {
        await host.openConnections(
            folder.appending(path: "Connections.json"), secrets: folder.appending(path: "Secrets.json"),
            protectsSecrets: false)
    }

    /// A system with no adb, which keeps ports below 1024 for administrators, as Linux does.
    @Test func takesAdbAndTheLowestPortFromTheSystemsParts() async throws {
        let folder = SessionAPITests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var system = SystemParts.standIns
        system.findAdb = { nil }
        system.lowestPort = { 1024 }
        let host = try await Self.open(folder, system: system)
        let emulators = await host.emulators(port: 9090)
        #expect(emulators == Emulators(hasAdb: false, emulators: [], problem: AndroidDebugBridge.missing))
        await #expect(throws: Problem(.notAvailable, AndroidDebugBridge.missing)) {
            try await host.setEmulatorUsesReqly(serial: "emulator-5554", isOn: true, port: 9090)
        }

        _ = await Self.openConnections(host, in: folder)
        var draft = await host.newReverseProxy(proxyPort: 9090)
        draft.serverURL = "staging.weatherly.dev"
        draft.port = "80"
        let words = "Linux lets only administrators use ports below 1024. Choose 1024 or above."
        #expect(await host.checkReverseProxy(draft, proxyPort: 9090).problem == words)
        await #expect(throws: Problem(.badRequest, words)) {
            try await host.saveReverseProxy(draft, proxyPort: 9090)
        }
        // A port that isn't one is still told so.
        draft.port = "0"
        #expect(await host.checkReverseProxy(draft, proxyPort: 9090).problem == "The port is a number from 1 to 65535.")
        draft.port = "1024"
        #expect(await host.checkReverseProxy(draft, proxyPort: 9090).problem == nil)
        // Capturing is off, so nothing listens.
        #expect(try await host.saveReverseProxy(draft, proxyPort: 9090).reverseProxies.count == 1)
        await host.close()
    }

    /// Where the system lets an app use any port, as the Mac and Windows do, port 80 is fine.
    @Test func letsAReverseProxyUseAnyPortByDefault() async throws {
        let folder = SessionAPITests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SystemParts.standIns.lowestPort() == 1)
        let host = try await Self.open(folder)
        _ = await Self.openConnections(host, in: folder)
        var draft = await host.newReverseProxy(proxyPort: 9090)
        draft.serverURL = "staging.weatherly.dev"
        draft.port = "80"
        #expect(await host.checkReverseProxy(draft, proxyPort: 9090).problem == nil)
        await host.close()
    }

    #if !os(Windows)
        /// The adb the system's parts find is the one that runs: here a stand-in that knows one
        /// emulator, which sends its traffic through Reqly.
        @Test func runsTheAdbTheSystemsPartsFind() async throws {
            let folder = SessionAPITests.folder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let adb = folder.appending(path: "adb")
            try Data(
                """
                #!/bin/sh
                case "$*" in
                "devices -l") printf 'List of devices attached\\nemulator-5554 device model:sdk_gphone64 transport_id:1\\n' ;;
                *"emu avd name") printf 'Pixel_9_Pro\\nOK\\n' ;;
                *"get global http_proxy") printf '10.0.2.2:9090\\n' ;;
                *) echo "$*" >> "$(dirname "$0")/calls" ;;
                esac

                """.utf8
            ).write(to: adb)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: adb.path(percentEncoded: false))
            var system = SystemParts.standIns
            system.findAdb = { AndroidDebugBridge(executable: adb) }
            let host = try await Self.open(folder, system: system)
            let emulators = await host.emulators(port: 9090)
            #expect(emulators.hasAdb && emulators.problem == nil)
            #expect(emulators.emulators.map(\.emulator.name) == ["Pixel 9 Pro"])
            #expect(emulators.emulators.map(\.usesReqly) == [true])
            let stopped = try await host.setEmulatorUsesReqly(serial: "emulator-5554", isOn: false, port: 9090)
            #expect(stopped == CheckResult())
            let calls = try String(contentsOf: folder.appending(path: "calls"), encoding: .utf8)
            #expect(calls == "-s emulator-5554 shell settings put global http_proxy :0\n")
            await host.close()
        }
    #endif
}
