import CGtk
import CoreInterface
import Foundation
import GtkBinding

/// The self-check, `--smoke <report>`: runs its parts one after another on the main loop, each
/// within its time limit, or only the ones `--smoke-parts` names, and writes PASS or FAIL for
/// each to the report, with what it found. Then Reqly quits, with status 0 when every part
/// passed and 1 when any failed. linux/scripts/app.sh's `self-check` runs it headless, with
/// stand-ins for your settings.
///
/// Each feature lists its own parts, in a file of its own beside this one; ``parts`` puts the
/// lists in order.
@MainActor
final class SelfCheck {
    /// One check, by name.
    struct Part {
        var name: String
        /// How long it may take before it fails, in seconds.
        var seconds = 30
        var run: @MainActor (SelfCheck) async throws -> Void
    }

    /// Why a part failed.
    struct Failure: Error, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// Every part, in the order they run.
    static var parts: [Part] { windowParts + captureParts + httpsParts }

    let app: App
    let report: URL
    private let names: [String]?
    private var output: FileHandle?
    /// What the part found so far.
    private var notes: [String] = []
    /// What the part waits for now, for the line a part that runs out of time writes.
    private var waitingFor: String?
    /// When the part runs out of time, in monotonic microseconds.
    private var deadline = 0
    /// How many frames the window has painted, and when it painted the latest.
    private var paints = 0
    private var lastPaint = 0

    init(app: App, report: URL, names: [String]?) {
        self.app = app
        self.report = report
        self.names = names
    }

    var window: MainWindow { app.window! }
    var model: AppModel { app.model }

    // MARK: - Running

    func run() async {
        try? FileManager.default.createDirectory(
            at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: report.path, contents: nil),
            let output = FileHandle(forWritingAtPath: report.path)
        else {
            AppLog.write("couldn't write the self-check's report to \(report.path)")
            app.exitStatus = 1
            app.quit()
            return
        }
        self.output = output
        if let clock = gtk_widget_get_frame_clock(window.window) {
            connect(clock, "after-paint") { [weak self] in
                self?.paints += 1
                self?.lastPaint = monotonicMicroseconds()
            }
        }
        let display = gdk_display_get_default().map { typeName(raw($0)) } ?? "no display"
        say("Reqly \(App.version), GTK \(LibraryVersion.gtk), libadwaita \(LibraryVersion.adwaita), \(display)")
        let chosen: [(name: String, part: Part?)] =
            names.map { names in names.map { name in (name, Self.parts.first { $0.name == name }) } }
            ?? Self.parts.map { ($0.name, $0) }
        var passed = 0
        for (name, part) in chosen {
            guard let part else {
                say("FAIL \(name): there's no such part")
                continue
            }
            let started = monotonicMicroseconds()
            let failure = await outcome(of: part)
            let seconds = String(format: "%.1f", Double(monotonicMicroseconds() - started) / 1_000_000)
            if let failure {
                say("FAIL \(name) (\(seconds) s): \(failure)")
            } else {
                say("PASS \(name) (\(seconds) s)")
                passed += 1
            }
            for note in notes {
                say("    \(note)")
            }
        }
        say("\(passed) of \(chosen.count) parts passed")
        try? output.close()
        app.exitStatus = passed == chosen.count ? 0 : 1
        app.quit()
    }

    /// Runs a part, and says why it failed, or `nil` when it passed.
    private func outcome(of part: Part) async -> String? {
        notes = []
        waitingFor = nil
        deadline = monotonicMicroseconds() + part.seconds * 1_000_000
        let result = Outcome()
        let running = Task {
            do {
                try await part.run(self)
                result.give(nil)
            } catch {
                result.give("\(error)")
            }
        }
        let limit = timeout(UInt32(part.seconds * 1000)) { [weak self] in
            result.limitPassed = true
            running.cancel()
            let waiting = self?.waitingFor.map { ", waiting for \($0)" } ?? ""
            result.give("gave up after \(part.seconds) s\(waiting)")
            return false
        }
        let failure = await result.failure()
        if !result.limitPassed {
            g_source_remove(limit)
        }
        return failure
    }

    private func say(_ line: String) {
        output?.write(Data((line + "\n").utf8))
    }

    // MARK: - What parts use

    /// Notes what the part found, for the report.
    func note(_ line: String) {
        notes.append(line)
    }

    /// Fails the part, saying `failure`, unless `condition` holds.
    func require(_ condition: Bool, _ failure: @autoclosure () -> String) throws {
        if !condition {
            throw Failure(failure())
        }
    }

    /// Waits until `condition` holds, looking every 10 ms, for at most `seconds`, or as long as
    /// the part has left.
    func until(_ what: String, seconds: Int? = nil, _ condition: () -> Bool) async throws {
        waitingFor = what
        defer { waitingFor = nil }
        let limit = min(deadline, seconds.map { monotonicMicroseconds() + $0 * 1_000_000 } ?? deadline)
        while !condition() {
            if Task.isCancelled || monotonicMicroseconds() >= limit {
                throw Failure("gave up waiting for \(what)")
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits for the window to settle, as a dialog's opening ends: for its next frame, then for
    /// 300 ms with none. At most 5 s.
    func settle() async {
        let start = monotonicMicroseconds()
        let paintsBefore = paints
        while monotonicMicroseconds() - start < 5_000_000 {
            let now = monotonicMicroseconds()
            if paints > paintsBefore || now - start > 1_000_000, now - lastPaint >= 300_000 {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The live session, once it's open.
    func session() async throws -> SessionHost {
        try await until("the session to open") { model.session != nil || model.problem != nil }
        guard let session = model.session else { throw Failure(model.problem ?? "the session didn't open") }
        return session
    }

    /// Runs one of the app's actions, as its menu entry does.
    func activate(_ action: String) {
        g_action_group_activate_action(cast(app.application), action, nil)
    }
}

/// How a part went: passed, or why it failed, from the part or from its time limit, whichever
/// says first.
@MainActor
private final class Outcome {
    private var given: String??
    private var waiting: CheckedContinuation<String?, Never>?
    /// Whether the part's time limit has passed, and its source has gone.
    var limitPassed = false

    func give(_ failure: String?) {
        guard given == nil else { return }
        given = failure
        waiting?.resume(returning: failure)
        waiting = nil
    }

    func failure() async -> String? {
        if let given {
            return given
        }
        return await withCheckedContinuation { waiting = $0 }
    }
}
