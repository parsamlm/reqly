import AppKit
import SwiftUI

/// The General pane of Settings: the proxy port, how Reqly starts, its helper, and updates.
struct GeneralSettings: View {
    @Environment(CaptureModel.self) private var capture
    @Environment(ConnectionsModel.self) private var connections
    @Environment(UpdatesModel.self) private var updates
    @AppStorage(DefaultsKey.startCapturingOnLaunch) private var startsCapturing = false
    @AppStorage(DefaultsKey.showsMenuBarItem) private var showsMenuBarItem = true
    @AppStorage(DefaultsKey.checksForUpdates) private var checksForUpdates = true
    @State private var port = ""
    @State private var portProblem: String?
    @FocusState private var isEditingPort: Bool

    var body: some View {
        Form {
            Section("Capturing") {
                LabeledContent {
                    TextField("Proxy port", text: $port, prompt: Text(String(CaptureModel.defaultPort)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .focused($isEditingPort)
                        .onSubmit(savePort)
                } label: {
                    Text("Proxy port")
                    if let portProblem {
                        Text(portProblem).foregroundStyle(.orange)
                    } else {
                        Text("Reqly listens on this port on your Mac. Change it if another app already uses it.")
                    }
                }
                if capture.isOnOldPort {
                    HStack {
                        Text("Reqly uses port \(String(capture.port)) the next time you start capturing.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Capturing") {
                            Task { await capture.restart() }
                        }
                        .disabled(capture.isBusy)
                    }
                }
                Toggle("Start capturing when Reqly opens", isOn: $startsCapturing)
                Toggle("Show Reqly in the menu bar", isOn: $showsMenuBarItem)
            }
            .toggleStyle(.switch)

            Section("Your network settings") {
                HStack(spacing: 12) {
                    Image(systemName: capture.setsSystemProxy ? "checkmark.shield" : "network")
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .background(.tint.opacity(0.14), in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if capture.setsSystemProxy {
                            Text("Always restored")
                            Text(
                                "Reqly puts your proxy settings back when you stop capturing, even if it quits unexpectedly."
                            )
                            .foregroundStyle(.secondary)
                        } else {
                            Text("Left alone")
                            Text(
                                "This copy of Reqly doesn't change your proxy settings, so it captures only the apps you point at 127.0.0.1, port \(String(capture.port))."
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if capture.setsSystemProxy {
                    LabeledContent {
                        Button("Remove Helper…") {
                            confirmRemovingHelper()
                        }
                        .disabled(capture.isCapturing || capture.isBusy)
                    } label: {
                        Text("Reqly's helper")
                        Text(
                            capture.isCapturing
                                ? "It sets your proxy while Reqly captures. Stop capturing to remove it."
                                : "It sets your proxy while Reqly captures. Reqly sets it up again the next time you start capturing."
                        )
                    }
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    .toggleStyle(.switch)
                    .onChange(of: checksForUpdates) { updates.setChecksAutomatically(checksForUpdates) }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reqly \(updates.version)")
                        Text(updateStatus)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    if let available = updates.updateAvailable {
                        Button(
                            updates.installsUpdates
                                ? "Install Reqly \(available.version.description)…"
                                : "Download Reqly \(available.version.description)"
                        ) { updates.download() }
                    } else {
                        Button("Check Now") {
                            Task { await updates.check() }
                        }
                        .disabled(updates.status == .checking)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { port = String(capture.port) }
        .onChange(of: isEditingPort) {
            if !isEditingPort {
                savePort()
            }
        }
    }

    private var updateStatus: String {
        switch updates.status {
        case .checking: "Checking…"
        case .upToDate: "You're up to date."
        case .available(let version, _): "Reqly \(version) is available."
        case .failed(let problem): problem
        case .notChecked:
            updates.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." }
                ?? "Reqly looks for updates on GitHub."
        }
    }

    private func confirmRemovingHelper() {
        let alert = NSAlert()
        alert.messageText = "Remove Reqly's helper?"
        alert.informativeText =
            "The helper sets your Mac's proxy while Reqly captures. Reqly sets it up again the next time you start capturing, and macOS may ask you to allow it."
        alert.addButton(withTitle: "Remove Helper")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let outcome = await capture.removeHelper()
            let result = NSAlert()
            switch outcome {
            case .removed:
                result.messageText = "Reqly's helper is removed"
                result.informativeText =
                    "It no longer runs on your Mac. Reqly sets it up again the next time you start capturing."
            case .wasNotInstalled:
                result.messageText = "Reqly's helper isn't set up"
                result.informativeText =
                    "There's nothing to remove. Reqly sets the helper up the next time you start capturing."
            case .notNow:
                result.messageText = "Stop capturing first"
                result.informativeText = "The helper guards your proxy settings while Reqly captures."
            case .failed(let reason):
                result.alertStyle = .warning
                result.messageText = "Reqly couldn't remove its helper"
                result.informativeText =
                    "\(reason) You can also turn it off in System Settings, under General, then Login Items & Extensions."
            }
            result.runModal()
        }
    }

    private func savePort() {
        let text = port.trimmingCharacters(in: .whitespaces)
        guard let number = Int(text), CaptureModel.ports.contains(number) else {
            portProblem = "Enter a port from 1024 to 65535."
            return
        }
        if connections.reverseProxies.contains(where: { $0.localPort == number }) {
            portProblem = "A reverse proxy listens on port \(String(number)). Choose another port."
            return
        }
        portProblem = nil
        port = String(number)
        capture.setPort(number)
    }
}
