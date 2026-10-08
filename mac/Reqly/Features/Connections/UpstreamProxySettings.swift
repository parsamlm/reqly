import ReqlyModel
import SwiftUI

/// The Upstream Proxy pane of Settings: another proxy that Reqly sends its own traffic
/// through. Changes apply when you click Apply, since they reconnect what's open.
struct UpstreamProxySettings: View {
    @Environment(ConnectionsModel.self) private var connections
    @Environment(CaptureModel.self) private var capture
    @State private var draft = Draft()
    @State private var hasLoaded = false

    struct Draft: Equatable {
        var isOn = false
        var host = ""
        var port = ""
        var username = ""
        var password = ""
        var bypass = ""
        var bypassesLocalAddresses = true

        init() {}

        init(_ proxy: UpstreamProxy?, isOn: Bool) {
            self.isOn = isOn
            guard let proxy else { return }
            host = proxy.host
            port = String(proxy.port)
            username = proxy.username ?? ""
            password = proxy.password ?? ""
            bypass = proxy.bypass.map(\.rawValue).joined(separator: ", ")
            bypassesLocalAddresses = proxy.bypassesLocalAddresses
        }

        /// The patterns in the bypass list, and the entries that aren't hosts.
        var patterns: (valid: [HostPattern], invalid: [String]) {
            let entries = bypass.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
                .map(String.init).filter { !$0.isEmpty }
            return (
                entries.compactMap(HostPattern.init(rawValue:)), entries.filter { HostPattern(rawValue: $0) == nil }
            )
        }

        var proxy: UpstreamProxy? {
            let host = host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, let port = Int(port.trimmingCharacters(in: .whitespaces)) else { return nil }
            let username = username.trimmingCharacters(in: .whitespaces)
            return UpstreamProxy(
                host: host, port: port, username: username.isEmpty ? nil : username,
                password: username.isEmpty || password.isEmpty ? nil : password, bypass: patterns.valid,
                bypassesLocalAddresses: bypassesLocalAddresses)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $draft.isOn) {
                    Text("Use an upstream proxy")
                    Text("For networks that reach the internet only through another proxy, as many offices do.")
                }
                .toggleStyle(.switch)
            }
            Section("Proxy") {
                TextField("Server", text: $draft.host, prompt: Text("proxy.example.com"))
                TextField("Port", text: $draft.port, prompt: Text("8080"))
                TextField("User name", text: $draft.username, prompt: Text("Optional"))
                SecureField("Password", text: $draft.password, prompt: Text("Optional"))
                    .disabled(draft.username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(!draft.isOn)
            Section {
                TextField(
                    "Hosts", text: $draft.bypass, prompt: Text("intranet.example.com, *.corp.example.com"),
                    axis: .vertical
                )
                .lineLimit(1...4)
                Toggle(isOn: $draft.bypassesLocalAddresses) {
                    Text("Addresses on the local network")
                    Text("Such as 192.168.1.20 and printer.local")
                }
            } header: {
                Text("Reach Directly")
            } footer: {
                Text("This Mac is always reached directly.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(!draft.isOn)
            Section {
                if let problem = validation {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let problem = connections.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Revert") { load() }
                        .disabled(!hasChanges)
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges || validation != nil)
                }
            } footer: {
                Text(
                    "HTTPS, WebSocket and encrypted connections go through tunnels the proxy opens, and plain HTTP requests go to it with their whole address. Reqly keeps the password in your Keychain."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !hasLoaded {
                load()
                hasLoaded = true
            }
        }
    }

    private var saved: Draft {
        Draft(connections.upstreamProxy, isOn: connections.usesUpstreamProxy)
    }

    private var hasChanges: Bool { draft != saved }

    /// What's wrong with the settings, while the proxy is on.
    private var validation: String? {
        guard draft.isOn else { return nil }
        let host = draft.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            return "Enter the proxy's server."
        }
        if host.contains(where: \.isWhitespace) || host.contains("/") {
            return "The server is a host name or an address, without http:// or a path."
        }
        guard let port = Int(draft.port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            return "The port is a number from 1 to 65535."
        }
        if HostScope.isThisMac(host), port == capture.port {
            return "That's Reqly's own address. Enter the other proxy's."
        }
        if let invalid = draft.patterns.invalid.first {
            return "“\(invalid)” isn't a host name or a pattern such as *.example.com."
        }
        return nil
    }

    private func load() {
        draft = saved
    }

    private func apply() {
        let proxy = draft.proxy
        connections.setUpstreamProxy(proxy, isOn: draft.isOn && proxy != nil)
        load()
    }
}
