import CGtk
import Foundation
import GtkBinding
import LinuxDesktop

/// The files a copy of Reqly that a part starts keeps, in a folder of its own: its own settings
/// and stand-ins, as the self-check has, and its log.
struct ChildFiles {
    let folder: URL

    init(_ name: String, in scratch: URL) throws {
        folder = scratch.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var standIn: URL { folder.appending(path: "ProxySettings.json") }
    var restoreFile: URL { folder.appending(path: "ProxyRestore.json") }
    /// The restore file Reqly keeps beside the stand-in when the command line names none.
    var standInsOwnRestoreFile: URL { folder.appending(path: "ProxySettings-Restore.json") }
    var sessions: URL { folder.appending(path: "Sessions") }

    /// Its command line: its files and stand-ins, with its log unless `logs` is false, so its
    /// standard error stays where it was started with, and with ``restoreFile`` unless
    /// `namesRestoreFile` is false.
    func arguments(logs: Bool = true, namesRestoreFile: Bool = true) -> [String] {
        func file(_ name: String) -> String { folder.appending(path: name).path }
        return [
            "--settings-file", file("Settings.json"), "--rules-file", file("Rules.json"),
            "--connections-file", file("Connections.json"), "--protobuf-file", file("Protobuf.json"),
            "--devices-file", file("Devices.json"), "--sessions-folder", sessions.path,
            "--crash-reports-folder", file("Crashes"), "--proxy-settings-stand-in", standIn.path,
            "--root-stand-in", file("Root.dat"), "--root-file", file("Certificate.dat"),
            "--secrets-stand-in", file("Secrets.json"), "--allows-network-devices", "no",
            "--checks-for-updates", "no", "--has-seen-welcome", "yes",
        ] + (namesRestoreFile ? ["--proxy-restore-file", restoreFile.path] : [])
            + (logs ? ["--log-file", file("Reqly.log")] : [])
    }
}

/// A copy of Reqly that a part starts, through GIO, which closes the self-check's descriptors in
/// it, and waits for without holding up the window.
@MainActor
final class ChildRun {
    private let process: OpaquePointer
    /// Its process ID.
    let identifier: String

    /// Starts Reqly with `arguments`, and its standard error going to the file at `standardError`,
    /// such as `/dev/full`, or the self-check's own, with the self-check's environment and
    /// `environment`.
    init(_ arguments: [String], standardError: String? = nil, environment: [String: String] = [:]) throws {
        let launcher = g_subprocess_launcher_new(GSubprocessFlags(rawValue: 0))!
        defer { g_object_unref(raw(launcher)) }
        if let standardError {
            g_subprocess_launcher_set_stderr_file_path(launcher, standardError)
        }
        for (name, value) in environment {
            g_subprocess_launcher_setenv(launcher, name, value, 1)
        }
        var error: UnsafeMutablePointer<GError>?
        let started = withCStrings([ProxyGuard.currentExecutable] + arguments) {
            g_subprocess_launcher_spawnv(launcher, $0, &error)
        }
        guard let started else { throw SelfCheck.Failure("Reqly didn't start: \(message(error))") }
        process = started
        identifier = string(g_subprocess_get_identifier(started)) ?? "?"
    }

    isolated deinit {
        g_object_unref(raw(process))
    }

    func send(_ signal: Int32) {
        g_subprocess_send_signal(process, signal)
    }

    /// Ends it, unless it has ended.
    func stop() {
        g_subprocess_force_exit(process)
    }

    /// Waits for it to end, and returns its exit status, or `nil` when a signal ended it.
    func wait() async -> Int32? {
        await withCheckedContinuation { done in
            let (callback, context) = whenReady { [process] _, result in
                _ = g_subprocess_wait_finish(process, result, nil)
                done.resume(
                    returning: g_subprocess_get_if_exited(process) != 0 ? g_subprocess_get_exit_status(process) : nil)
            }
            g_subprocess_wait_async(process, nil, callback, context)
        }
    }
}

extension SelfCheck {
    /// The session the Mac saved, as Reqly for Mac 1.0 wrote it: 16 requests, among them JSON, a
    /// picture, a body packed with gzip, a secret Authorization header, a WebSocket and an
    /// encrypted connection (core/Tests/TrafficStoreTests/SessionSample.swift).
    static func macSession() throws -> URL {
        try checkoutFile("core/Tests/TrafficStoreTests/Sessions/Mac 1.0.reqly")
    }

    /// Runs `parts` of the self-check in a copy of Reqly with files and stand-ins of its own, a
    /// port of its own, and `options`, such as `--smoke-session` or `--session-limit`, and gives
    /// back its report's lines after the first, once it ends. A part sees it's in the copy by
    /// those options, as `tools` does. The copy shares this run's bus and screen, with
    /// accessibility off unless `accessible`. Fails unless every part passed.
    func runInCopy(
        _ parts: [String], options: [String], seconds: Int = 60, accessible: Bool = false
    ) async throws -> [String] {
        let files = try ChildFiles("copy", in: scratch)
        try JSONEncoder().encode(Self.yourProxySettings).write(to: files.standIn)
        // In the scratch folder, which has the home and XDG folders, as the self-check needs.
        let report = scratch.appending(path: "copy-\(UUID().uuidString).txt")
        let copy = try ChildRun(
            files.arguments() + ["--smoke", report.path, "--smoke-parts", parts.joined(separator: ","), "--port", "0"]
                + options,
            environment: accessible ? [:] : ["GTK_A11Y": "none"])
        defer { copy.stop() }
        let limit = TimeLimit()
        let source = timeout(UInt32(seconds * 1000)) {
            limit.passed = true
            copy.stop()
            return false
        }
        let status = await copy.wait()
        if !limit.passed {
            g_source_remove(source)
        }
        let lines = ((try? String(contentsOf: report, encoding: .utf8)) ?? "").split(separator: "\n").dropFirst()
            .map(String.init)
        guard status == 0 else {
            let ending = status.map { "status \($0)" } ?? "a signal, or its time limit of \(seconds) s"
            let log = (try? String(contentsOf: files.folder.appending(path: "Reqly.log"), encoding: .utf8)) ?? ""
            throw Failure(
                "the copy of Reqly, \(copy.identifier), ended with \(ending): "
                    + (lines + log.split(separator: "\n").suffix(5).map(String.init)).joined(separator: " | "))
        }
        return lines
    }
}
