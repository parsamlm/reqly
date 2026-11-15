import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

// Stand-ins the self-check's parts run Reqly with, so nothing real is touched: a program in adb's
// place, and a folder on another file system than the scratch folder's, for saving across them.

extension SelfCheck {
    /// A stand-in for adb, a shell script in `folder`, which a copy of Reqly runs with
    /// `--adb-stand-in`, so a real adb never runs. It lists one emulator, `emulator-5554`, named
    /// Pixel 9 Pro, whose proxy it keeps in `folder/proxy` (none at first), and writes every
    /// command but the ones that only read to `folder/calls`, a line each, as Use Reqly, Stop
    /// Using Reqly and Copy Certificate run them. Each run leaves a child behind for 30 s that
    /// keeps the script's output and errors open, as adb's server might keep the first call's:
    /// Reqly mustn't wait for it.
    static func adbStandIn(in folder: URL) throws -> URL {
        let adb = folder.appending(path: "adb")
        try Data(
            """
            #!/bin/sh
            here=$(dirname "$0")
            sleep 30 &
            case "$*" in
            "devices -l") printf 'List of devices attached\\nemulator-5554 device model:sdk_gphone64 transport_id:1\\n' ;;
            *"emu avd name") printf 'Pixel_9_Pro\\nOK\\n' ;;
            *"settings get global http_proxy") cat "$here/proxy" 2>/dev/null || echo null ;;
            *"settings put global http_proxy "*)
                echo "$*" >> "$here/calls"
                proxy=${*##* }
                if [ "$proxy" = ":0" ]; then rm -f "$here/proxy"; else echo "$proxy" > "$here/proxy"; fi ;;
            *) echo "$*" >> "$here/calls" ;;
            esac

            """.utf8
        ).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        return adb
    }

    /// A new folder in `/dev/shm`, a file system of its own in the container, apart from the
    /// scratch folder's, as a tmpfs `/tmp` is on Debian 13 and Ubuntu 26.04, for a copy of Reqly's
    /// `TMPDIR` when it saves over a file in the scratch folder. Fails when the two are on the same
    /// device, rather than let a part pass without testing anything. Only that copy gets it:
    /// `/dev/shm` doesn't let programs run from it. Delete it once the part is done.
    func otherFileSystemFolder() throws -> URL {
        let folder = URL(filePath: "/dev/shm").appending(path: "reqly-self-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var shm = stat()
        var here = stat()
        guard stat(folder.path, &shm) == 0, stat(scratch.path, &here) == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw Failure("couldn't read the devices of \(folder.path) and \(scratch.path)")
        }
        guard shm.st_dev != here.st_dev else {
            try? FileManager.default.removeItem(at: folder)
            throw Failure("\(folder.path) is on the scratch folder's file system, so saving across them tests nothing")
        }
        return folder
    }
}

extension SelfCheck {
    /// The stand-ins' own check, run only by name, and its two halves, each in a copy of Reqly.
    static let standInParts: [Part] = [
        Part(name: "stand-ins", seconds: 120) { try await $0.checkStandIns() },
        Part(name: "adb-stand-in", seconds: 30) { try await $0.checkTheAdbStandIn() },
        Part(name: "save-elsewhere", seconds: 30) { try await $0.checkSavingElsewhere() },
    ]

    /// The test server's WebSocket and protobuf body through Reqly, as a live window captures them;
    /// a copy of Reqly running the adb stand-in, whose calls come back at once, though each leaves
    /// a child that keeps its output open; and a copy whose `TMPDIR` is on another file system
    /// saving its session over a file in the scratch folder, which leaves nothing else beside it.
    func checkStandIns() async throws {
        let session = try await emptyTheList()
        let traffic = try await startTraffic()
        defer { traffic.server.stop() }
        let messages = try await traffic.client.webSocket(traffic.server.url(.webSocket), sending: ["Rain tomorrow?"])
        let expected: [ProxyClient.WebSocketMessage] = [
            .text(TestServer.webSocketGreeting), .binary(TestServer.webSocketBytes), .text("Echo: Rain tomorrow?"),
        ]
        try require(messages == expected, "through Reqly, the WebSocket said \(messages)")
        let forecast = try await traffic.client.send(traffic.server.url(.protobuf))
        try require(forecast.body == TestServer.protobufBody, "through Reqly, the protobuf body is \(forecast.body)")
        try await until("the WebSocket's and the protobuf's rows", seconds: 5) { self.window.list.total == 2 }
        let summaries = await session.rows(await session.rowIDs().ids)
        try require(
            summaries.contains { $0.isWebSocket }, "the session has no WebSocket: \(summaries.map(\.path))")
        // What a server sends right behind its 101 doesn't reach the app through Reqly: noted,
        // not failed, as the parts' WebSockets don't rely on it.
        let together = try? await traffic.client.webSocket(traffic.server.url(.webSocket, "together"), sending: [])
        try await stopTraffic()
        note("through Reqly: the WebSocket's greeting, bytes and echo, and the Forecast in protobuf")
        note(
            "a greeting sent right behind the 101 "
                + (together == nil ? "doesn't come through Reqly" : "comes through Reqly too"))

        let folder = try scratchFolder("adb")
        let adb = try Self.adbStandIn(in: folder)
        for line in try await runInCopy(["adb-stand-in"], options: ["--adb-stand-in", adb.path])
        where !line.hasSuffix("parts passed") {
            note("in a copy: \(line.trimmingCharacters(in: .whitespaces))")
        }
        let elsewhere = try otherFileSystemFolder()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        for line in try await runInCopy(
            ["save-elsewhere"], options: [], environment: ["TMPDIR": elsewhere.path])
        where !line.hasSuffix("parts passed") {
            note("in a copy: \(line.trimmingCharacters(in: .whitespaces))")
        }
        _ = try await emptyTheList()
    }

    /// In a copy with `--adb-stand-in`: the emulator it lists, its proxy set and taken back, each
    /// call back within 2 s, as adb's own child may keep its output open.
    func checkTheAdbStandIn() async throws {
        let session = try await session()
        let adb = try present(app.options.adbStandIn.map { URL(filePath: $0) }, "the copy has no adb stand-in")
        let started = monotonicMicroseconds()
        let emulators = await session.emulators(port: 9090)
        let listed = (monotonicMicroseconds() - started) / 1000
        try require(
            emulators.hasAdb && emulators.emulators.map(\.emulator.name) == ["Pixel 9 Pro"],
            "the stand-in's emulators are \(emulators)")
        try require(listed < 2000, "listing the emulators took \(listed) ms")
        let on = monotonicMicroseconds()
        _ = try await session.setEmulatorUsesReqly(serial: "emulator-5554", isOn: true, port: 9090)
        let set = (monotonicMicroseconds() - on) / 1000
        try require(set < 2000, "Use Reqly took \(set) ms")
        let after = await session.emulators(port: 9090)
        try require(after.emulators.first?.usesReqly == true, "the emulator doesn't use Reqly: \(after)")
        _ = try await session.setEmulatorUsesReqly(serial: "emulator-5554", isOn: false, port: 9090)
        let calls = try String(contentsOf: adb.deletingLastPathComponent().appending(path: "calls"), encoding: .utf8)
        let expected =
            "-s emulator-5554 shell settings put global http_proxy 10.0.2.2:9090\n"
            + "-s emulator-5554 shell settings put global http_proxy :0\n"
        try require(calls == expected, "the stand-in was called with \(calls)")
        note("the adb stand-in: Pixel 9 Pro listed in \(listed) ms, Use Reqly in \(set) ms, then taken back")
    }

    /// In a copy whose `TMPDIR` is on another file system than the scratch folder: a session saved
    /// over a file there opens again, keeps the file's mode, and leaves nothing else in its folder.
    func checkSavingElsewhere() async throws {
        let session = try await session()
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
        try require(temporary.hasPrefix("/dev/shm/"), "the copy's TMPDIR is \(temporary), not in /dev/shm")
        // Nothing listens on port 9, so the request fails at once, without leaving the computer.
        _ = try await session.send(RequestDraft(url: "http://127.0.0.1:9/elsewhere"))
        let folder = try scratchFolder("saved")
        let file = folder.appending(path: "Weatherly.reqly")
        try Data("an older file".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        do {
            try await session.saveSession(to: file, hidingSecrets: false)
        } catch {
            throw Failure("saving over the file failed: \(error.message)")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        try require(left == ["Weatherly.reqly"], "beside the saved file: \(left)")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        try require(mode == 0o640, "the saved file's mode is \(String(mode, radix: 8)), not 640")
        let header = try FileHandle(forReadingFrom: file).read(upToCount: 16) ?? Data()
        try require(header == Data("SQLite format 3\0".utf8), "the saved file isn't a session")
        note("saved over a file on another file system than TMPDIR (\(temporary)): nothing else beside it, mode 640")
    }
}
