import AppSetup
import CoreInterface
import Dispatch
import Foundation

/// A window's session: the live one, which the app keeps (``AppModel/live``), or a saved session
/// or HAR file, opened in a window of its own, with a copy in the sessions folder that goes as the
/// window closes. The window's features read it, rather than the app's model, and hear of each
/// change through ``observe(_:)``, the app's changes included, and of each of the session's events
/// through ``listen(_:)``.
///
/// Events wait until the window has been made and calls ``startEvents()``, as Windows' sessions
/// do: a file's session hands over its sidebar and its rows as it opens, and the live window may be
/// made long after the live session opened, as when Reqly started to show a file.
@MainActor
final class SessionModel {
    unowned let app: AppModel
    /// The file the session was opened from, or `nil` for the live session.
    let file: URL?
    /// The session, once it's open.
    private(set) var session: SessionHost?
    /// Why a file's session couldn't be opened, in the core's words.
    private(set) var problem: String?
    /// Whether a file's session is still opening.
    private(set) var isOpening: Bool
    /// Whether ``close()`` has finished.
    private(set) var isClosed = false
    /// The latest `exportProgress` event: how many of the requests a HAR export has written.
    private(set) var exportProgress: (done: Int, total: Int)?

    private var observers: [@MainActor () -> Void] = []
    private var listeners: [@MainActor (Event) -> Void] = []
    /// The events that came before the window listened, until ``startEvents()``.
    private var waiting: [Event]? = []
    private var opening: Task<Void, Never>?
    /// The app model's observer of this session, which goes with it.
    private var appObserver: Int?

    init(app: AppModel, file: URL?) {
        self.app = app
        self.file = file
        isOpening = file != nil
        appObserver = app.observe { [weak self] in self?.changed() }
    }

    isolated deinit {
        if let appObserver {
            app.stopObserving(appObserver)
        }
    }

    /// Whether it's the live session.
    var isLive: Bool { file == nil }

    /// Whether it shows a saved session rather than live traffic: a file's, or the one a test run
    /// opens in place of the live session with `--smoke-session`.
    var isSaved: Bool { file != nil || app.options.smokeSession != nil }

    /// The file's name, as its window's title shows it.
    var fileName: String? { file?.lastPathComponent }

    // MARK: - The app's, as the window reads it

    var options: Options { app.options }
    var settings: AppSettings { app.settings }

    func changeSettings(_ change: (inout AppSettings) -> Void) throws {
        try app.changeSettings(change)
    }

    var https: HTTPSModel { app.https }
    /// Whether this session captures: only the live one does.
    var isCapturing: Bool { isLive && app.isCapturing }
    /// The port capturing listens on, or starts on.
    var port: Int { app.port }

    // MARK: - Changes and events

    /// Runs `body` after each change to the session's state, or to the app's.
    func observe(_ body: @escaping @MainActor () -> Void) {
        observers.append(body)
    }

    /// Hands `body` each of the session's events, in order, once the window has started them.
    func listen(_ body: @escaping @MainActor (Event) -> Void) {
        listeners.append(body)
    }

    /// Tells the observers that the state changed.
    func changed() {
        for observer in observers {
            observer()
        }
    }

    /// The window is made and listens: the events that waited go to it, in order, and the ones
    /// after it as they come.
    func startEvents() {
        guard let events = waiting else { return }
        waiting = nil
        for event in events {
            deliver(event)
        }
    }

    /// One of the session's events, on the main queue, in the session's order.
    func receive(_ event: Event) {
        if case .exportProgress(let done, let total) = event {
            exportProgress = (done, total)
        }
        if waiting != nil {
            waiting?.append(event)
        } else {
            deliver(event)
        }
    }

    private func deliver(_ event: Event) {
        for listener in listeners {
            listener(event)
        }
    }

    // MARK: - Opening and closing

    /// The live session, which the app's model opened.
    func opened(_ session: SessionHost) {
        self.session = session
        changed()
    }

    /// Opens the file's session, in the sessions folder. A file that isn't a session or a HAR
    /// file, a damaged one, or one a newer Reqly saved, leaves ``problem`` saying so.
    func openFile() {
        guard let file, opening == nil else { return }
        opening = Task { await open(file) }
    }

    private func open(_ file: URL) async {
        defer {
            isOpening = false
            changed()
        }
        do {
            try app.folders.makeSessionsFolder()
        } catch {
            problem = "Reqly couldn't make the folder for its sessions, \(app.folders.sessionsFolder.path)."
            return
        }
        do {
            session = try await SessionHost.open(
                app.folders.openOptions(file: file.path, options), system: options.systemParts
            ) { [weak self] event in
                // The main queue runs its work in the order it's queued, so the events stay in the
                // session's order, as rows events need.
                DispatchQueue.main.async { self?.receive(event) }
            }
        } catch {
            problem = error.message
        }
    }

    /// Closes the session, which deletes its copy in the sessions folder, once it has opened.
    func close() async {
        defer { isClosed = true }
        await opening?.value
        guard let session else { return }
        await session.close()
        self.session = nil
    }
}
