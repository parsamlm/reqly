import AppKit
import ReqlyModel
import SwiftUI

extension FocusedValues {
    /// The traffic in the window in front, for the menus to act on.
    @Entry var traffic: TrafficListModel?
    /// Puts the focus in the window's request search.
    @Entry var findRequests: (() -> Void)?
    /// The detail pane's section, and the sections the shown request has.
    @Entry var inspectorTab: Binding<InspectorView.Tab>?
    @Entry var inspectorTabs: [InspectorView.Tab]?
}

/// Find… in the Edit menu: a text editor's find bar when one has the focus, such as the script
/// editor's, and otherwise the window's request search.
struct EditCommands: Commands {
    @FocusedValue(\.findRequests) private var findRequests

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") {
                if let editor = findBarEditor {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    editor.performTextFinderAction(item)
                } else {
                    findRequests?()
                }
            }
            .keyboardShortcut("f")
            .disabled(findRequests == nil && findBarEditor == nil)
        }
    }

    private var findBarEditor: NSTextView? {
        (NSApp.keyWindow?.firstResponder as? NSTextView).flatMap { $0.usesFindBar ? $0 : nil }
    }
}

/// The View menu's sections of the detail pane, each with a shortcut, for the keyboard alone.
struct ViewCommands: Commands {
    @FocusedValue(\.inspectorTab) private var tab
    @FocusedValue(\.inspectorTabs) private var tabs

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(InspectorView.Tab.shortcutOrder.enumerated()), id: \.element) { index, section in
                Toggle(
                    section.rawValue,
                    isOn: Binding(
                        get: { tab?.wrappedValue == section },
                        set: { if $0 { tab?.wrappedValue = section } }
                    )
                )
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(!(tabs ?? []).contains(section))
            }
        }
    }
}

/// The app menu's update check, under About Reqly.
struct AppCommands: Commands {
    let updates: UpdatesModel
    let settings: SettingsNavigation
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                // Sparkle shows what it finds in a window of its own; otherwise Settings does.
                if !updates.installsUpdates {
                    settings.open(.general, with: openSettings)
                }
                Task { await updates.check() }
            }
            .disabled(updates.status == .checking)
        }
    }
}

/// The File menu: new requests, opening files, saving sessions and exporting HAR files.
struct FileCommands: Commands {
    let model: AppModel
    @FocusedValue(\.traffic) private var traffic
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Request") {
                openWindow(id: "composer", value: model.composer.newDraft())
            }
            .keyboardShortcut("n")
            Button("Open…") {
                open()
            }
            .keyboardShortcut("o")
        }
        // Below Close. Replacing the Save group would remove Close, and a window group's own
        // Save group drops anything added to it.
        CommandGroup(replacing: .importExport) {
            Button("Save Session…") {
                if let traffic {
                    SessionSaving.save(traffic)
                }
            }
            .keyboardShortcut("s")
            .disabled(traffic?.isEmpty ?? true)
            Button("Export as HAR…") {
                traffic?.harExport = HARExportRequest(selected: traffic?.selection)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(traffic?.isEmpty ?? true)
        }
    }

    /// Opens saved sessions and HAR files, each in a window of its own.
    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.reqlySession, .har]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            openWindow(id: "file", value: url)
        }
    }
}

/// The Window menu's Reqly, which brings the main window back after it's closed. Reqly lists it
/// itself: removing the window groups' commands takes away the item SwiftUI would make.
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .singleWindowList) {
            Button("Reqly") {
                openWindow(id: "main")
            }
            .keyboardShortcut("0")
        }
    }
}

/// The Help menu. Reqly Help shows the website, the version and the license. Sponsor Reqly opens
/// the GitHub Sponsors page.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Reqly Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)
            Button("Welcome to Reqly") {
                openWindow(id: "welcome")
            }
            Divider()
            Button("Report a Problem…") {
                NSWorkspace.shared.open(CrashReporter.problemURL)
            }
            Button("Sponsor Reqly") {
                NSWorkspace.shared.open(AppInfo.sponsor)
            }
        }
    }
}

/// The Request menu: what you can do with the request selected in the window in front, in the
/// same groups as a request's own menu: copying, sending again, marking, and how Reqly treats
/// requests like it.
struct RequestCommands: Commands {
    let model: AppModel
    @FocusedValue(\.traffic) private var traffic
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Request") {
            let selected = traffic?.selectedSummary
            let isReadable = selected?.kind == .http
            Button("Copy URL") {
                actions?.copyURL(selected!.id)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(selected == nil)
            Button("Copy as cURL") {
                actions?.copyCurl(selected!.id)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!isReadable)
            Button("Copy Response Body") {
                actions?.copyResponseBody(selected!.id)
            }
            .disabled(!isReadable || selected?.status == nil)

            Divider()

            Button("Resend") {
                actions?.resend(selected!.id)
            }
            .disabled(!isReadable)
            Button("Edit and Resend…") {
                actions?.editAndResend(selected!.id)
            }
            .disabled(!isReadable)

            Divider()

            Button(selected?.annotation.isPinned == true ? "Unpin Request" : "Pin Request") {
                traffic?.togglePin(selected!.id)
            }
            .disabled(selected == nil)
            Button("Unpin All Requests") {
                traffic?.unpinAll()
            }
            .disabled((traffic?.pinnedCount ?? 0) == 0)
            Picker("Color", selection: color(of: selected)) {
                Text("None").tag(MarkColor?.none)
                Divider()
                ForEach(MarkColor.allCases, id: \.self) { color in
                    Label {
                        Text(color.title)
                    } icon: {
                        if let dot = color.menuImage {
                            Image(nsImage: dot)
                        }
                    }
                    .tag(Optional(color))
                }
            }
            .disabled(selected == nil)
            Button(selected?.annotation.comment == nil ? "Add Comment…" : "Edit Comment…") {
                traffic?.editComment(of: selected!.id)
            }
            .disabled(selected == nil)

            Divider()

            Menu("Add Rule") {
                ForEach(RuleKind.rules, id: \.self) { kind in
                    Button(kind.menuTitle) {
                        actions?.addRule(kind, for: selected!.id)
                    }
                    // An encrypted connection shows only its host, so all a rule can do is block it.
                    .disabled(!isReadable && kind != .block)
                }
            }
            .disabled(selected == nil)
            // What's decrypted applies to capturing, so only the main window offers it.
            if let selected, selected.scheme == "https", traffic === model.traffic {
                Button(
                    model.https.isDecrypting(selected.host)
                        ? "Stop Decrypting \(selected.host)" : "Decrypt \(selected.host)"
                ) {
                    model.https.toggleDecryption(selected.host)
                }
            }
        }
    }

    private func color(of selected: ExchangeSummary?) -> Binding<MarkColor?> {
        Binding(
            get: { selected?.annotation.color },
            set: { color in
                if let selected {
                    traffic?.setColor(color, for: selected.id)
                }
            }
        )
    }

    private var actions: RequestActions? {
        traffic.map { RequestActions(traffic: $0, model: model, openWindow: openWindow) }
    }
}
