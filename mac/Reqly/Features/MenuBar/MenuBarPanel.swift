import AppKit
import ReqlyModel
import SwiftUI

/// The panel that opens from Reqly's item in the menu bar: capturing at a glance, with a switch
/// to start and stop it, the toolbar's other switches, and what Reqly can capture, in the
/// Capture menu's words.
struct MenuBarPanel: View {
    @Environment(CaptureModel.self) private var capture
    @Environment(RulesModel.self) private var rules
    @Environment(HTTPSModel.self) private var https
    @Environment(UpdatesModel.self) private var updates
    @Environment(SettingsNavigation.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PanelDivider()
            TrafficSummary()
            PanelDivider()
            ruleSwitch("Breakpoints", .breakpoint)
            ruleSwitch("Slow Network", .slowNetwork)
            PanelDivider()
            PanelButton("Decrypt HTTPS…", value: decryptedHosts) {
                settings.open(.https, with: openSettings)
            }
            PanelButton("Devices…") {
                openWindow(id: "devices")
                NSApp.activate()
            }
            PanelDivider()
            PanelButton("Open Reqly", shortcut: "⌘0") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .keyboardShortcut("0")
            PanelButton("Settings…", shortcut: "⌘,") {
                settings.open(.general, with: openSettings)
            }
            .keyboardShortcut(",")
            if let update = updates.updateAvailable {
                PanelButton(
                    updates.installsUpdates
                        ? "Install Reqly \(update.version.description)…"
                        : "Download Reqly \(update.version.description)"
                ) {
                    updates.download()
                }
            }
            PanelDivider()
            PanelButton("Quit Reqly", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(6)
        .frame(width: 300)
    }

    private func ruleSwitch(_ title: String, _ kind: RuleKind) -> some View {
        PanelRow {
            Toggle(title, isOn: Binding(get: { rules.isOn(kind) }, set: { rules.setOn($0, for: kind) }))
                .toggleStyle(PanelSwitchStyle())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reqly")
                        .font(.headline)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(statusText)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Toggle(
                    "Capturing",
                    isOn: Binding(get: { capture.isCapturing }, set: { _ in capture.toggle() })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(capture.isBusy && capture.status != .waitingForApproval)
                .help(capture.isCapturing ? "Stop Capturing" : "Start Capturing")
            }
            switch capture.status {
            case .failed(let problem):
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .waitingForApproval:
                HStack {
                    Text("Allow Reqly's helper in System Settings to start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open") { capture.openApprovalSettings() }
                        .controlSize(.small)
                }
            default:
                EmptyView()
            }
            if let warning = capture.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var statusText: String {
        switch capture.status {
        case .stopped: "Not capturing"
        case .starting: "Starting…"
        case .waitingForApproval: "Waiting for you to allow the helper"
        case .capturing(let port): "Capturing on port \(String(port))"
        case .stopping: "Stopping…"
        case .failed: "Couldn't start capturing"
        }
    }

    private var statusColor: Color {
        switch capture.status {
        case .capturing: Color("StatusSuccess")
        case .failed: .red
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var decryptedHosts: String {
        guard https.isTrusted else { return "Not set up" }
        if https.hosts.includesEveryHost { return "All hosts" }
        let count = https.hosts.onCount
        return count == 1 ? "1 host" : "\(count) hosts"
    }
}

/// How many requests there are, and the newest one.
private struct TrafficSummary: View {
    @Environment(TrafficListModel.self) private var traffic
    @Environment(CaptureModel.self) private var capture

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let all = traffic.all
            Text(
                "\(Format.requests(all.count)) · \(Format.size(all.reduce(0) { $0 + $1.bytesSent + $1.bytesReceived }))"
            )
            .font(.body.weight(.medium).monospacedDigit())
            if let newest = all.last {
                HStack(spacing: 6) {
                    if let statusClass = newest.statusClass {
                        Circle()
                            .fill(statusClass.color)
                            .frame(width: 7, height: 7)
                    } else if case .failed = newest.state {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Text([newest.status.map(String.init), newest.method].compactMap { $0 }.joined(separator: " "))
                        .font(.caption.monospaced())
                    Text(newest.displayHost + (newest.kind == .http ? newest.target : ""))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Newest: \(newest.statusDescription), \(newest.method) \(newest.displayHost)")
            } else {
                Text(capture.isCapturing ? "Waiting for traffic" : "No requests yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

/// A row of the panel, as tall as a menu item.
private struct PanelRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }
}

/// An action in the panel that highlights like a menu item under the pointer.
private struct PanelButton: View {
    let title: String
    var value: String?
    var shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, value: String? = nil, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                }
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .modifier(Highlighted(isOn: isHovered))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(
                isHovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        // The title alone, so VoiceOver reads the value once, as the value.
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
    }
}

/// Text on the accent color while the pointer is over a row, in black or white, whichever reads better.
private struct Highlighted: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.readableOnAccent()
        } else {
            content.foregroundStyle(.primary)
        }
    }
}

/// A switch at the end of a row, with the label at its start.
private struct PanelSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            // The switch carries the label for VoiceOver, so it's read once.
            configuration.label
                .accessibilityHidden(true)
            Spacer()
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
