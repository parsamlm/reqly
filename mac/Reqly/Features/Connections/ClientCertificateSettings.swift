import AppKit
import ProxyEngine
import ReqlyModel
import SwiftUI
import UniformTypeIdentifiers

/// The Client Certificates pane of Settings: the certificates Reqly presents to servers that
/// ask apps to identify themselves.
struct ClientCertificateSettings: View {
    @Environment(ConnectionsModel.self) private var connections
    @State private var selection: ClientCertificate.ID?
    @State private var isAdding = false
    @State private var editing: ClientCertificate?

    var body: some View {
        Form {
            Section {
                if connections.clientCertificates.isEmpty {
                    Text("No client certificates yet. Add one with the + button.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(connections.clientCertificates) { certificate in
                        ClientCertificateRow(
                            certificate: certificate,
                            isMissing: connections.missingCertificates.contains(certificate.id)
                        )
                        .contentShape(.rect)
                        .gesture(TapGesture(count: 2).onEnded { editing = certificate })
                        .simultaneousGesture(TapGesture().onEnded { selection = certificate.id })
                        .selectedRow(selection == certificate.id)
                        .accessibilityAddTraits(selection == certificate.id ? .isSelected : [])
                        .contextMenu {
                            Button("Edit Hosts…") { editing = certificate }
                            Divider()
                            Button("Remove") { remove(certificate.id) }
                        }
                    }
                }
                HStack(spacing: 0) {
                    ListBarButton("Add Client Certificate", systemImage: "plus") {
                        isAdding = true
                    }
                    ListBarButton("Remove Client Certificate", systemImage: "minus") {
                        if let selection { remove(selection) }
                    }
                    .disabled(selection == nil)
                    Spacer()
                    Button("Edit Hosts…") {
                        editing = connections.clientCertificates.first { $0.id == selection }
                    }
                    .controlSize(.small)
                    .disabled(selection == nil)
                }
            } header: {
                Text("Client Certificates")
            } footer: {
                Text(
                    "Reqly presents a certificate to the servers that ask apps to identify themselves, for the hosts you choose. It keeps certificates and their private keys in your Keychain."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let problem = connections.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .onDeleteCommand {
            if let selection { remove(selection) }
        }
        .sheet(isPresented: $isAdding) {
            ClientCertificateAdder()
        }
        .sheet(item: $editing) { certificate in
            HostsEditor(certificate: certificate)
        }
    }

    private func remove(_ id: ClientCertificate.ID) {
        connections.removeClientCertificate(id)
        if selection == id {
            selection = nil
        }
    }
}

private struct ClientCertificateRow: View {
    @Environment(ConnectionsModel.self) private var connections
    let certificate: ClientCertificate
    let isMissing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                "Use This Certificate",
                isOn: Binding(
                    get: { certificate.isOn }, set: { connections.setClientCertificate(certificate.id, on: $0) })
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(certificate.name)
                    .lineLimit(1)
                Text(certificate.hosts.map(\.rawValue).joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                details
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(certificate.isOn ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var details: some View {
        if isMissing {
            Label(
                "The Keychain no longer has this certificate's key. Remove it and add it again.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        } else {
            let issuer = certificate.issuer.isEmpty ? "" : "Issued by \(certificate.issuer)"
            if let expires = certificate.expires {
                let date = expires.formatted(date: .abbreviated, time: .omitted)
                if certificate.hasExpired() {
                    Text([issuer, "Expired on \(date)"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.red)
                } else {
                    Text([issuer, "Expires on \(date)"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(issuer).foregroundStyle(.secondary)
            }
        }
    }
}

/// Reads a client certificate from its files: a `.p12` or `.pfx` file, or PEM files with the
/// certificate and its private key.
private struct ClientCertificateAdder: View {
    @Environment(ConnectionsModel.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var hosts = ""
    @State private var files: [URL] = []
    @State private var password = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Hosts", text: $hosts, prompt: Text("api.example.com, *.example.com"))
                    LabeledContent("Certificate") {
                        HStack {
                            Text(files.isEmpty ? "None" : files.map(\.lastPathComponent).joined(separator: ", "))
                                .foregroundStyle(files.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") { choose() }
                        }
                    }
                    SecureField("Password", text: $password, prompt: Text("If the file is locked"))
                } header: {
                    Text("New Client Certificate")
                } footer: {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(
                            "Choose a .p12 or .pfx file, as Keychain Access exports, or PEM files with the certificate and its private key."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || patterns.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .onChange(of: password) { problem = nil }
        .onChange(of: hosts) { problem = nil }
    }

    private var patterns: [HostPattern] {
        hosts.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { HostPattern(rawValue: String($0)) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose a .p12 or .pfx file, or PEM files with a certificate and its private key."
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["p12", "pfx", "pem", "crt", "cer", "key"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        files = panel.urls
        problem = nil
    }

    private func add() {
        let invalid = hosts.split(whereSeparator: { $0 == "," || $0 == " " }).first {
            HostPattern(rawValue: String($0)) == nil
        }
        if let invalid {
            problem = "“\(invalid)” isn't a host name or a pattern such as *.example.com."
            return
        }
        do {
            try connections.addClientCertificate(from: files, password: password, hosts: patterns)
            dismiss()
        } catch {
            problem = error.message
        }
    }
}

/// Changes which hosts a client certificate is for.
private struct HostsEditor: View {
    @Environment(ConnectionsModel.self) private var connections
    @Environment(\.dismiss) private var dismiss
    let certificate: ClientCertificate
    @State private var hosts: String

    init(certificate: ClientCertificate) {
        self.certificate = certificate
        _hosts = State(initialValue: certificate.hosts.map(\.rawValue).joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Hosts", text: $hosts, prompt: Text("api.example.com, *.example.com"))
                } header: {
                    Text(certificate.name)
                } footer: {
                    if let invalid {
                        Label(
                            "“\(invalid)” isn't a host name or a pattern such as *.example.com.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    connections.setHosts(patterns, of: certificate.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(patterns.isEmpty || invalid != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }

    private var entries: [String] {
        hosts.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    }

    private var patterns: [HostPattern] { entries.compactMap(HostPattern.init(rawValue:)) }

    private var invalid: String? { entries.first { HostPattern(rawValue: $0) == nil } }
}
