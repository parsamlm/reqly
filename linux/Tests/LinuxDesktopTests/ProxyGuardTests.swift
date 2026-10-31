import Foundation
import Synchronization
import Testing

@testable import LinuxDesktop

@Suite struct ProxyGuardTests {
    /// A restore file, as ``UserProxySwitch`` leaves one while capturing.
    static func restoreFile(in folder: URL) throws -> URL {
        let file = folder.appending(path: "ProxyRestore.json")
        try Data(#"{"yours":{},"port":9090}"#.utf8).write(to: file)
        return file
    }

    /// Runs the watcher for `pid` on a thread of its own and returns its exit status and whether
    /// it restored, once it quits.
    static func watch(pid: pid_t, restoreFile: URL) async -> (status: Int32, restored: Bool) {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let restored = Atomic(false)
                let status = ProxyGuard.watch(pid: pid, restoreFile: restoreFile) {
                    restored.store(true, ordering: .relaxed)
                    return true
                }
                continuation.resume(returning: (status, restored.load(ordering: .relaxed)))
            }
            thread.start()
        }
    }

    @Test func restoresWhenReqlyEnds() async throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.restoreFile(in: folder)
        // Reqly, as a process that ends after a moment.
        let reqly = try Programs.start("/bin/sleep", ["1"], environment: [:])
        let started = ContinuousClock.now
        let (status, restored) = await Self.watch(pid: reqly, restoreFile: file)
        #expect(status == 0)
        #expect(restored)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(Programs.wait(for: reqly, seconds: 1) == 0)
    }

    @Test func quitsQuietlyWhenTheRestoreFileGoes() async throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.restoreFile(in: folder)
        let reqly = try Programs.start("/bin/sleep", ["30"], environment: [:])
        defer {
            kill(reqly, SIGKILL)
            _ = Programs.wait(for: reqly, seconds: 5)
        }
        let started = ContinuousClock.now
        _ = Task {
            try await Task.sleep(for: .milliseconds(300))
            // Capture stopped as it should.
            try FileManager.default.removeItem(at: file)
        }
        let (status, restored) = await Self.watch(pid: reqly, restoreFile: file)
        #expect(status == 0)
        #expect(!restored)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func leavesANewerRestoreFileToANewerWatcher() async throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.restoreFile(in: folder)
        let reqly = try Programs.start("/bin/sleep", ["30"], environment: [:])
        defer {
            kill(reqly, SIGKILL)
            _ = Programs.wait(for: reqly, seconds: 5)
        }
        _ = Task {
            try await Task.sleep(for: .milliseconds(300))
            // Capture stopped and started again, which writes a new file in its place.
            try Data(#"{"yours":{},"port":9091}"#.utf8).write(to: file, options: .atomic)
        }
        let (status, restored) = await Self.watch(pid: reqly, restoreFile: file)
        #expect(status == 0)
        #expect(!restored)
    }

    @Test func restoresAtOnceWhenReqlyIsAlreadyGone() async throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.restoreFile(in: folder)
        let reqly = try Programs.start("/bin/true", [], environment: [:])
        #expect(Programs.wait(for: reqly, seconds: 5) == 0)
        let (status, restored) = await Self.watch(pid: reqly, restoreFile: file)
        #expect(status == 0)
        #expect(restored)
    }

    /// Once your settings are back and the restore file is gone, the login entry goes too.
    @Test func removesTheLoginEntryOnceItRestores() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.restoreFile(in: folder)
        let entry = LoginEntry(file: folder.appending(path: "autostart/entry.desktop"))
        try entry.write(executable: "/usr/bin/reqly", restoreFile: file)
        let reqly = try Programs.start("/bin/true", [], environment: [:])
        #expect(Programs.wait(for: reqly, seconds: 5) == 0)
        // Putting them back fails, so the file and the entry stay for the next try.
        #expect(
            ProxyGuard.watch(pid: reqly, restoreFile: file, loginEntry: entry) { throw CocoaError(.fileLocking) } == 1)
        #expect(entry.exists)
        let status = ProxyGuard.watch(pid: reqly, restoreFile: file, loginEntry: entry) {
            try FileManager.default.removeItem(at: file)
            return true
        }
        #expect(status == 0)
        #expect(!entry.exists)
    }

    /// After an upgrade replaced Reqly's file, the watcher and the login entry run the new one.
    @Test func runsTheProgramAtItsPath() {
        #expect(ProxyGuard.programPath("/usr/lib/reqly/reqly (deleted)") == "/usr/lib/reqly/reqly")
        #expect(ProxyGuard.programPath("/usr/lib/reqly/reqly") == "/usr/lib/reqly/reqly")
        #expect(ProxyGuard.currentExecutable.hasPrefix("/"))
    }

    @Test func runsOnlyForItsOwnArguments() {
        #expect(ProxyGuard.run(arguments: []) == nil)
        #expect(ProxyGuard.run(arguments: ["Session.reqly"]) == nil)
        #expect(ProxyGuard.run(arguments: ["--restore-proxy-after", "not a process", "/tmp/x"]) == 2)
    }

    @Test func writesTheLoginEntry() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = LoginEntry(environment: ["HOME": "/home/ana", "XDG_CONFIG_HOME": folder.path])
        #expect(entry.file.path == folder.path + "/autostart/net.reqly.Reqly-restore-proxy.desktop")
        #expect(
            LoginEntry(environment: ["HOME": "/home/ana"]).file.path
                == "/home/ana/.config/autostart/net.reqly.Reqly-restore-proxy.desktop")
        let restoreFile = URL(filePath: "/home/ana/.local/state/reqly/ProxyRestore.json")
        try entry.write(executable: "/usr/lib/reqly/reqly", restoreFile: restoreFile)
        #expect(
            try String(contentsOf: entry.file, encoding: .utf8) == """
                [Desktop Entry]
                Type=Application
                Name=Reqly
                Comment=Puts your proxy settings back if Reqly quit while capturing
                TryExec=/usr/lib/reqly/reqly
                Exec="/usr/lib/reqly/reqly" --restore-proxy "/home/ana/.local/state/reqly/ProxyRestore.json"
                NoDisplay=true
                X-GNOME-Autostart-enabled=true
                X-GNOME-AutoRestart=false

                """)
        entry.remove()
        #expect(!entry.exists)
    }

    @Test func quotesTheLoginEntrysCommand() {
        // A dollar sign, a quote and a percent sign, as in a name someone gave a folder.
        #expect(LoginEntry.quoted(#"/home/ana/My "$5" 100%/reqly"#) == #""/home/ana/My \\"\\$5\\" 100%%/reqly""#)
        #expect(LoginEntry.quoted("/opt/Reqly App/reqly") == #""/opt/Reqly App/reqly""#)
    }

    @Test func restoresAtLoginAndRemovesTheEntry() throws {
        TestEnvironment.prepare()
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = LoginEntry(file: folder.appending(path: "autostart/entry.desktop"))
        try entry.write(executable: "/usr/bin/reqly", restoreFile: folder.appending(path: "ProxyRestore.json"))
        let restored = Atomic(false)
        // No Reqly holds the name on the tests' bus.
        let status = ProxyGuard.restoreAtLogin(
            restoreFile: folder.appending(path: "ProxyRestore.json"), loginEntry: entry,
            appName: "net.reqly.Reqly.Tests"
        ) {
            restored.store(true, ordering: .relaxed)
            return true
        }
        #expect(status == 0)
        let didRestore = restored.load(ordering: .relaxed)
        #expect(didRestore)
        #expect(!entry.exists)
    }

    @Test func leavesItAllToARunningReqly() throws {
        try #require(TestEnvironment.sessionBus != nil)
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = LoginEntry(file: folder.appending(path: "autostart/entry.desktop"))
        try entry.write(executable: "/usr/bin/reqly", restoreFile: folder.appending(path: "ProxyRestore.json"))
        let restored = Atomic(false)
        // The bus's own name stands for a running Reqly's.
        let status = ProxyGuard.restoreAtLogin(
            restoreFile: folder.appending(path: "ProxyRestore.json"), loginEntry: entry, appName: "org.freedesktop.DBus"
        ) {
            restored.store(true, ordering: .relaxed)
            return true
        }
        #expect(status == 0)
        let didRestore = restored.load(ordering: .relaxed)
        #expect(!didRestore)
        #expect(entry.exists)
    }

    @Test func startsTheWatcherAsAUserService() {
        let arguments = ProxyGuard.systemdRunArguments(
            unit: "net.reqly.Reqly-restore-4242",
            environment: ["XDG_CURRENT_DESKTOP": "KDE", "XDG_CONFIG_HOME": "/c", "PATH": "/usr/bin"])
        #expect(
            arguments == [
                "--user", "--collect", "--quiet", "--unit=net.reqly.Reqly-restore-4242",
                "--description=Puts your proxy settings back if Reqly quits while capturing",
                "--setenv=XDG_CURRENT_DESKTOP", "--setenv=XDG_CONFIG_HOME", "--",
            ])
    }

    /// Without `systemd-run`, as in the tests' container, the watcher runs as Reqly's child, and
    /// quits once its restore file goes.
    @Test func startsTheWatcherAsAChildWithoutSystemd() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.restoreFile(in: folder)
        let marker = folder.appending(path: "started")
        // A stand-in for Reqly that notes its arguments.
        let program = folder.appending(path: "reqly")
        try Data("#!/bin/sh\necho \"$@\" > '\(marker.path)'\n".utf8).write(to: program)
        chmod(program.path, 0o755)
        let guardian = ProxyGuard(
            restoreFile: file, environment: ["PATH": folder.path, "HOME": folder.path], executable: program.path)
        try guardian.startWatcher()
        var waited = 0
        while !FileManager.default.fileExists(atPath: marker.path) && waited < 50 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        let written = try String(contentsOf: marker, encoding: .utf8)
        #expect(written == "--restore-proxy-after \(getpid()) \(file.path)\n")
    }
}
