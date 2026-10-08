import AppKit
import SwiftUI

@main
struct ReqlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(DefaultsKey.showsMenuBarItem) private var showsMenuBarItem = true

    var body: some Scene {
        let model = appDelegate.model
        Window("Reqly", id: "main") {
            MainWindow()
                .environment(model)
                .environment(model.capture)
                .environment(model.traffic)
                .environment(model.https)
                .environment(model.rules)
                .environment(model.devices)
                .environment(model.protobuf)
                .environment(model.connections)
                .environment(model.settings)
        }
        .defaultSize(width: 1360, height: 860)
        // Reqly's other windows open from the menus their work belongs to, so the Window menu
        // doesn't list them too: their scenes' commands are removed.
        .commands {
            AppCommands(updates: model.updates, settings: model.settings)
            FileCommands(model: model)
            EditCommands()
            SidebarCommands()
            ViewCommands()
            CaptureCommands(capture: model.capture, traffic: model.traffic, settings: model.settings)
            RequestCommands(model: model)
            RulesCommands(rules: model.rules, traffic: model.traffic)
            WindowCommands()
            HelpCommands()
        }

        MenuBarExtra("Reqly", image: "MenuBarIcon", isInserted: $showsMenuBarItem) {
            MenuBarPanel()
                .environment(model.capture)
                .environment(model.traffic)
                .environment(model.rules)
                .environment(model.https)
                .environment(model.updates)
                .environment(model.settings)
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
            // The menu-bar item's panel in a window, for checking it without clicking.
            Window("Menu Bar Panel", id: "menu-bar-panel") {
                MenuBarPanel()
                    .environment(model.capture)
                    .environment(model.traffic)
                    .environment(model.rules)
                    .environment(model.https)
                    .environment(model.updates)
                    .environment(model.settings)
            }
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)
            .commandsRemoved()
        #endif

        // The first-run guide.
        Window("Welcome to Reqly", id: "welcome") {
            WelcomeWindow()
                .environment(model.capture)
                .environment(model.https)
                .environment(model.settings)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Reqly Quit Unexpectedly", id: "crash-report") {
            CrashReportWindow()
                .environment(model.crashes)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // A saved session or a HAR file, opened from the File menu or from Finder.
        WindowGroup("Saved Traffic", id: "file", for: URL.self) { $url in
            if let url {
                OpenedFileWindow(url: url)
                    .environment(model)
                    .environment(model.capture)
                    .environment(model.https)
                    .environment(model.rules)
                    .environment(model.devices)
                    .environment(model.protobuf)
                    .environment(model.connections)
                    .environment(model.settings)
            }
        }
        .defaultSize(width: 1360, height: 860)
        .commandsRemoved()

        // The rules for the traffic being captured, which the live list's requests count against.
        Window("Rules", id: "rules") {
            RulesWindow()
                .environment(model.rules)
                .environment(model.traffic)
        }
        .defaultSize(width: 860, height: 640)
        .commandsRemoved()

        Window("Devices", id: "devices") {
            DevicesWindow()
                .environment(model.devices)
                .environment(model.simulators)
                .environment(model.emulators)
                .environment(model.capture)
                .environment(model.https)
        }
        .defaultSize(width: 880, height: 680)
        .commandsRemoved()

        Window("Reqly Help", id: "help") {
            HelpWindow()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        WindowGroup("New Request", id: "composer", for: UUID.self) { $draft in
            ComposerWindow(draftID: draft)
                .environment(model)
                .environment(model.capture)
                .environment(model.traffic)
                .environment(model.https)
                .environment(model.rules)
                .environment(model.devices)
                .environment(model.protobuf)
                .environment(model.connections)
                .environment(model.settings)
        }
        .defaultSize(width: 1180, height: 760)
        .commandsRemoved()

        Settings {
            SettingsWindow()
                .environment(model.settings)
                .environment(model.protobuf)
                .environment(model.connections)
                .environment(model.capture)
                .environment(model.https)
                .environment(model.updates)
        }
    }
}

/// The Capture menu: starting and clearing, then what Reqly can capture: HTTPS contents, and
/// other devices' traffic. Its shortcuts work from anywhere in the app.
struct CaptureCommands: Commands {
    let capture: CaptureModel
    let traffic: TrafficListModel
    let settings: SettingsNavigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandMenu("Capture") {
            Button(capture.isCapturing ? "Stop Capturing" : "Start Capturing") {
                capture.toggle()
            }
            .keyboardShortcut("r")
            .disabled(capture.isBusy)
            Button("Clear Traffic") {
                traffic.clear()
            }
            .keyboardShortcut("k")
            .disabled(!traffic.canClear)

            Divider()

            Button("Decrypt HTTPS…") {
                settings.open(.https, with: openSettings)
            }
            Button("Devices…") {
                openWindow(id: "devices")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
