import AppKit
import Capture
import HAR
import ReqlyModel
import SwiftUI
import TrafficStore
import UniformTypeIdentifiers

extension UTType {
    /// A session saved by Reqly.
    static let reqlySession = UTType(exportedAs: "net.reqly.session", conformingTo: .data)
    /// An HTTP Archive, which browsers and other tools save.
    static let har = UTType(importedAs: "net.reqly.har", conformingTo: .json)
}

/// A saved session or a HAR file, opened as a session of its own for a window. Its copy of the
/// traffic is deleted when the window closes; the file stays as it was.
@MainActor
final class OpenedFile {
    let url: URL
    let traffic: TrafficListModel
    let store: TrafficStore

    private init(url: URL, store: TrafficStore) {
        self.url = url
        self.store = store
        traffic = TrafficListModel(session: CaptureSession(store: store))
    }

    deinit {
        store.discard()
    }

    static func open(_ url: URL, in folder: URL) async throws -> OpenedFile {
        let store: TrafficStore
        if url.pathExtension.lowercased() == "har" {
            let entries = try await Task.detached {
                try HARReader.entries(from: try Data(contentsOf: url))
            }.value
            var messages: [ExchangeID: [WebSocketMessage]] = [:]
            for entry in entries where !entry.messages.isEmpty {
                messages[entry.exchange.id] = entry.messages
            }
            store = try await TrafficStore.newSession(in: folder, with: entries.map(\.exchange), messages: messages)
        } else {
            store = try await TrafficStore.openSession(url, in: folder)
        }
        let file = OpenedFile(url: url, store: store)
        await file.traffic.showStoredTraffic()
        return file
    }

    /// A sentence about why a file didn't open.
    static func explain(_ error: any Error) -> String {
        switch error {
        case SessionFileError.notASession: "This file isn't a session that Reqly saved."
        case SessionFileError.savedByNewerReqly: "A newer version of Reqly saved this session. Update Reqly to open it."
        case HARError.unreadable(let reason): reason
        default: error.localizedDescription
        }
    }
}

/// The window for a file you opened: its traffic, in the same layout as the session being
/// captured.
struct OpenedFileWindow: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var file: OpenedFile?
    @State private var problem: String?

    var body: some View {
        Group {
            if let file {
                MainWindow()
                    .environment(file.traffic)
                    .environment(\.trafficFile, url)
            } else if let problem {
                ContentUnavailableView(
                    "Reqly Couldn't Open “\(url.lastPathComponent)”",
                    systemImage: "exclamationmark.triangle",
                    description: Text(problem)
                )
                .navigationTitle(url.lastPathComponent)
            } else {
                ProgressView("Opening “\(url.lastPathComponent)”…")
                    .navigationTitle(url.lastPathComponent)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .task(id: url) {
            do {
                let opened = try await OpenedFile.open(url, in: model.sessionsFolder)
                model.rememberOpened(opened.store)
                file = opened
            } catch {
                problem = OpenedFile.explain(error)
            }
        }
    }
}

/// Saving a window's traffic as a session file.
enum SessionSaving {
    /// Asks where to save, then saves. Secrets stay in the file unless you choose to hide them.
    @MainActor
    static func save(_ traffic: TrafficListModel, named suggestedName: String? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.reqlySession]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName ?? "Reqly Session \(Format.fileStamp(Date()))"
        let options = SecretsOption(key: "hidesSecretsInSessions", defaultValue: false)
        panel.accessoryView = NSHostingView(rootView: SecretsToggle(option: options).padding(12))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let hidesSecrets = options.isOn
        Task {
            do {
                try await traffic.saveSession(to: url, hidingSecrets: hidesSecrets)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Reqly couldn't save the session."
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

/// Whether to hide authorization headers and cookies, remembered between saves.
@Observable
final class SecretsOption {
    private let key: String
    var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: key) }
    }

    init(key: String, defaultValue: Bool) {
        self.key = key
        isOn = UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}

struct SecretsToggle: View {
    @Bindable var option: SecretsOption

    var body: some View {
        Toggle("Hide authorization headers and cookies", isOn: $option.isOn)
    }
}

extension EnvironmentValues {
    /// The file a window shows, or `nil` for the session being captured.
    @Entry var trafficFile: URL?
}
