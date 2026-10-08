import AppKit
import ReqlyModel
import SwiftUI

/// The HTTPS pane of Settings: Reqly's certificate, and the hosts it decrypts.
struct HTTPSSettings: View {
    @Environment(HTTPSModel.self) private var https
    @State private var selection: HostPattern?
    /// The host being typed into the list, while adding one.
    @State private var newHost: String?
    @State private var addProblem: String?
    @FocusState private var isTypingHost: Bool

    var body: some View {
        Form {
            Section("Certificate") {
                CertificateStatusRow()
                if https.hasCertificate {
                    Button("Remove Certificate…", role: .destructive) {
                        https.removeAfterConfirming()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(https.isWorking)
                }
            }

            Section {
                if https.hosts.entries.isEmpty, newHost == nil {
                    Text("No hosts yet. Add one with the + button, or choose Decrypt in a request's menu.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                ForEach(https.hosts.entries, id: \.pattern) { entry in
                    HostRow(entry: entry, isSelected: selection == entry.pattern)
                        .contentShape(.rect)
                        .onTapGesture { selection = entry.pattern }
                        .accessibilityAction(named: "Remove") { remove(entry.pattern) }
                        .selectedRow(selection == entry.pattern)
                        .contextMenu {
                            Button("Remove") { remove(entry.pattern) }
                        }
                }
                if newHost != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "New host",
                            text: Binding(get: { newHost ?? "" }, set: { newHost = $0 }),
                            prompt: Text("api.example.com or *.example.com")
                        )
                        .labelsHidden()
                        .font(.body.monospaced())
                        .focused($isTypingHost)
                        .onSubmit(add)
                        .onExitCommand { cancelAdding() }
                        if let addProblem {
                            Text(addProblem)
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                HStack(spacing: 0) {
                    ListBarButton("Add Host", systemImage: "plus") {
                        addProblem = nil
                        newHost = ""
                        isTypingHost = true
                    }
                    ListBarButton("Remove Host", systemImage: "minus") {
                        if let selection { remove(selection) }
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
            } header: {
                Text("Decrypt HTTPS for these hosts")
            } footer: {
                Text(
                    https.hosts.includesEveryHost
                        ? "Reqly decrypts every host except the ones switched off here. Use * to include subdomains, like *.weatherly.dev."
                        : "Traffic to other hosts passes through Reqly still encrypted. Use * to include subdomains, like *.weatherly.dev."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: { https.hosts.includesEveryHost }, set: { https.setDecryptsEveryHost($0) })
                ) {
                    Text("Decrypt all hosts")
                    Text("Not recommended. Some apps stop working when their traffic is decrypted.")
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .onDeleteCommand {
            if let selection { remove(selection) }
        }
    }

    private func add() {
        guard let text = newHost else { return }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            cancelAdding()
        } else if let problem = https.addHost(text) {
            addProblem = problem
        } else {
            selection = HostPattern(rawValue: text)
            cancelAdding()
        }
    }

    private func cancelAdding() {
        newHost = nil
        addProblem = nil
    }

    private func remove(_ pattern: HostPattern) {
        https.removeHosts([pattern])
        if selection == pattern {
            selection = nil
        }
    }
}

/// A host on the list, with its switch.
private struct HostRow: View {
    @Environment(HTTPSModel.self) private var https
    let entry: DecryptedHosts.Entry
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(entry.pattern.rawValue)
                .font(.body.monospaced())
            Spacer()
            Toggle(
                "Decrypt \(entry.pattern.rawValue)",
                isOn: Binding(get: { entry.isOn }, set: { https.setDecrypts($0, entry.pattern) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Whether the certificate is set up and trusted, with what to do next.
struct CertificateStatusRow: View {
    @Environment(HTTPSModel.self) private var https

    var body: some View {
        HStack(spacing: 12) {
            switch https.status {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking Reqly's certificate…")
                    .foregroundStyle(.secondary)
                Spacer()
            case .working(let step):
                ProgressView().controlSize(.small)
                Text(step)
                    .foregroundStyle(.secondary)
                Spacer()
            case .trusted:
                badge("checkmark", tint: .accentColor)
                details(
                    "The Reqly certificate is installed and trusted",
                    https.certificateDetails.map {
                        "Created \($0.created.formatted(date: .abbreviated, time: .omitted)) · It never leaves this Mac"
                    } ?? "It never leaves this Mac")
                Spacer()
                if let keychainAccess {
                    Button("Show in Keychain Access") {
                        NSWorkspace.shared.openApplication(at: keychainAccess, configuration: .init())
                    }
                    .help(
                        https.certificateDetails.map { "Look for “\($0.name)” under Certificates." }
                            ?? "Opens Keychain Access.")
                }
            case .notTrusted:
                badge("exclamationmark", tint: .orange)
                details(
                    "macOS doesn't trust the Reqly certificate",
                    "Reqly decrypts nothing until it does. macOS asks for your password.")
                Spacer()
                Button("Trust Certificate…") { Task { await https.setUp() } }
            case .notSetUp:
                badge("lock", tint: .secondary)
                details(
                    "HTTPS isn't set up",
                    "To read HTTPS traffic, your Mac needs to trust a certificate that Reqly creates just for you. It never leaves this Mac."
                )
                Spacer()
                Button("Install Certificate…") { Task { await https.setUp() } }
            case .failed(let problem):
                badge("exclamationmark", tint: .red)
                details("HTTPS isn't set up", problem)
                Spacer()
                Button("Try Again") { Task { await https.setUp() } }
            }
        }
    }

    private var keychainAccess: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess")
    }

    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint, in: .circle)
            .accessibilityHidden(true)
    }

    private func details(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
