import Presentation
import ReqlyModel
import SwiftUI

/// The Upstream Proxy pane of Settings: another proxy that Reqly sends its own traffic
/// through. Changes apply when you click Apply, since they reconnect what's open.
struct UpstreamProxySettings: View {
    @Environment(ConnectionsModel.self) private var connections
    @Environment(CaptureModel.self) private var capture
    @State private var draft = UpstreamProxyDraft()
    @State private var hasLoaded = false

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

    private var saved: UpstreamProxyDraft {
        UpstreamProxyDraft(connections.upstreamProxy, isOn: connections.usesUpstreamProxy)
    }

    private var hasChanges: Bool { draft != saved }

    /// What's wrong with the settings, while the proxy is on.
    private var validation: String? {
        draft.problem(proxyPort: capture.port)
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
