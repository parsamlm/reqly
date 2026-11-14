import CoreInterface
import DeviceBridge
import Foundation
import Presentation
import ProxyEngine
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

    /// The sessions the core's tests open, saved by Reqly for Mac 1.0, on Windows and on Linux.
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "core/Tests/TrafficStoreTests/Sessions")

    /// Opens a saved session from the core's tests, and waits until its list shows its rows.
    static func openSample(
        _ name: String, in folder: URL, events: @escaping @Sendable (Event) -> Void = { _ in }
    ) async throws -> SessionHost {
        let options = OpenOptions(
            sessionsFolder: folder.appending(path: "Sessions").path,
            file: samples.appending(path: name).path(percentEncoded: false))
        let host = try await SessionHost.open(options, system: .standIns, events: events)
        _ = try await rows(of: host) { !$0.isEmpty }
        return host
    }

    /// Waits up to five seconds for the list's rows to be as `wanted` says, and gives them.
    static func rows(of host: SessionHost, _ wanted: ([ExchangeID]) -> Bool) async throws -> [ExchangeID] {
        for _ in 0..<500 {
            let ids = await host.rowIDs().ids
            if wanted(ids) {
                return ids
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The rows never were as wanted: \(await host.rowIDs().ids)")
        return []
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

    /// Settings' port, as the Mac checks it: from 1024 to 65535, and no reverse proxy's.
    @Test func checksTheProxyPortAgainstTheReverseProxies() async throws {
        let folder = SessionAPITests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await Self.open(folder)
        _ = await Self.openConnections(host, in: folder)
        let fine = await host.checkProxyPort(" 9090 ")
        #expect(fine.port == 9090 && fine.problem == nil)
        for text in ["80", "1023", "65536", "", "port"] {
            let refused = await host.checkProxyPort(text)
            #expect(refused.port == nil && refused.problem == "Enter a port from 1024 to 65535.", "\(text)")
        }
        var draft = await host.newReverseProxy(proxyPort: 9090)
        draft.serverURL = "staging.weatherly.dev"
        draft.port = "8081"
        draft.isOn = false
        _ = try await host.saveReverseProxy(draft, proxyPort: 9090)
        // Even one that's off.
        let taken = await host.checkProxyPort("8081")
        #expect(taken.port == nil && taken.problem == "A reverse proxy listens on port 8081. Choose another port.")
        await host.close()
    }

    /// What Export as HAR counts and writes: the rows that show, without encrypted connections.
    @Test func exportsTheRowsThatShowAndStopsWhenCancelled() async throws {
        let folder = SessionAPITests.folder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = SessionEvents()
        let host = try await Self.openSample("Mac 1.0.reqly", in: folder, events: events.record)
        // The sample's sixth exchange is an encrypted connection.
        let tunnel = ExchangeID(rawValue: 6)
        let all = try await Self.rows(of: host) { $0.count == 16 }
        var rows = await host.exportRows()
        #expect(rows.readable == all.filter { $0 != tunnel } && rows.encrypted == 1)
        // Only the rows that show.
        var posts = TrafficFilter()
        posts.method = "POST"
        await host.setFilter(posts)
        let shown = try await Self.rows(of: host) { $0.count < 16 }
        rows = await host.exportRows()
        #expect(!shown.isEmpty && rows.readable == shown && rows.encrypted == 0)
        await host.setFilter(TrafficFilter())
        _ = try await Self.rows(of: host) { $0.count == 16 }
        rows = await host.exportRows()

        // Its progress counts the rows it's given.
        let file = folder.appending(path: "Weatherly.har")
        #expect(try await host.exportHAR(to: file, ids: rows.readable, creatorVersion: "5.0") == 15)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        let progress = await events.wait { event -> Int? in
            if case .exportProgress(0, let total) = event { total } else { nil }
        }
        #expect(progress == 15)

        // Cancelled, it stops and deletes the file it began.
        let cancelled = folder.appending(path: "Cancelled.har")
        let export = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await host.exportHAR(to: cancelled, ids: rows.readable, creatorVersion: "5.0")
        }
        await #expect(throws: Problem(.failed, "The export was cancelled.")) { try await export.value }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path(percentEncoded: false)))
        await host.close()
    }

    /// Map Local's "Save the Response as a File…": the body unpacked, a name with the extension
    /// Map Local would answer with that type, and the status and type to answer with.
    @Test func givesAResponseAsAFile() async throws {
        let folder = SessionAPITests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await Self.openSample("Mac 1.0.reqly", in: folder)
        let forecast = try await host.responseFile(ExchangeID(rawValue: 1))
        #expect(forecast.suggestedName == "forecast.json" && forecast.status == 200)
        #expect(forecast.contentType == "application/json")
        #expect(forecast.data == Data(#"{"city":"Lisbon","days":[{"sky":"clear"},{"sky":"rain"}]}"#.utf8))
        // Packed with gzip as it came, and saved unpacked.
        let greeting = try await host.responseFile(ExchangeID(rawValue: 3))
        #expect(greeting.suggestedName == "greeting.txt" && greeting.data == Data("hello, Reqly".utf8))
        #expect(greeting.contentType == "text/plain; charset=utf-8")
        // A name with an extension keeps it.
        #expect(try await host.responseFile(ExchangeID(rawValue: 4)).suggestedName == "radar.json")
        #expect(try await host.responseFile(ExchangeID(rawValue: 5)).suggestedName == "sun.png")
        await #expect(throws: Problem(.notAvailable, "An encrypted connection has no request to copy.")) {
            try await host.responseFile(ExchangeID(rawValue: 6))
        }
        await #expect(throws: Problem(.notAvailable, "This request has no response yet.")) {
            try await host.responseFile(ExchangeID(rawValue: 7))
        }
        await host.close()

        // The extensions are the ones Map Local answers by, the other way round.
        let types = [
            "application/json", "text/html; charset=utf-8", "text/javascript", "image/jpeg", "image/svg+xml",
            "font/woff2",
        ]
        for type in types {
            let fileExtension = try #require(LocalFileTypes.fileExtension(forType: type))
            #expect(LocalFileTypes.contentType(forFile: "answer.\(fileExtension)") == type)
        }
        #expect(LocalFileTypes.fileExtension(forType: "Text/HTML ; charset=UTF-8") == "html")
        #expect(LocalFileTypes.fileExtension(forType: "image/jpeg") == "jpg")
        #expect(LocalFileTypes.fileExtension(forType: "application/x-weather") == nil)
        #expect(LocalFileTypes.contentType(forFile: "~/answers/Sun.JPEG") == "image/jpeg")
        #expect(LocalFileTypes.contentType(forFile: "answer") == "application/octet-stream")
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
