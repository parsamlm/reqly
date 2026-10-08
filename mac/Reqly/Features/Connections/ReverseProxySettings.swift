import ReqlyModel
import SwiftUI

/// The Reverse Proxy pane of Settings: local addresses that send every request on to a
/// server, for apps that can't use a proxy.
struct ReverseProxySettings: View {
    @Environment(ConnectionsModel.self) private var connections
    @Environment(CaptureModel.self) private var capture
    @State private var selection: ReverseProxy.ID?
    @State private var editing: ReverseProxy?

    var body: some View {
        Form {
            Section {
                if connections.reverseProxies.isEmpty {
                    Text("No reverse proxies yet. Add one with the + button.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(connections.reverseProxies) { proxy in
                        ReverseProxyRow(
                            proxy: proxy, problem: connections.reverseProxyProblems[proxy.id],
                            isCapturing: capture.isCapturing
                        )
                        .contentShape(.rect)
                        .gesture(TapGesture(count: 2).onEnded { editing = proxy })
                        .simultaneousGesture(TapGesture().onEnded { selection = proxy.id })
                        .selectedRow(selection == proxy.id)
                        .accessibilityAddTraits(selection == proxy.id ? .isSelected : [])
                        .contextMenu {
                            Button("Edit…") { editing = proxy }
                            Divider()
                            Button("Remove") { remove(proxy.id) }
                        }
                    }
                }
                HStack(spacing: 0) {
                    ListBarButton("Add Reverse Proxy", systemImage: "plus") {
                        editing = ReverseProxy(localPort: suggestedPort, serverURL: "")
                    }
                    ListBarButton("Remove Reverse Proxy", systemImage: "minus") {
                        if let selection { remove(selection) }
                    }
                    .disabled(selection == nil)
                    Spacer()
                    Button("Edit…") {
                        editing = connections.reverseProxies.first { $0.id == selection }
                    }
                    .controlSize(.small)
                    .disabled(selection == nil)
                }
            } header: {
                Text("Reverse Proxies")
            } footer: {
                Text(
                    "Point an app that can't use a proxy at a local address, such as `http://localhost:8080`. Reqly sends its requests on to the server and records them. Reverse proxies listen while Reqly captures, and only this Mac can reach them."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDeleteCommand {
            if let selection { remove(selection) }
        }
        .sheet(item: $editing) { proxy in
            ReverseProxyEditor(proxy: proxy, isNew: !connections.reverseProxies.contains { $0.id == proxy.id })
        }
        .task(id: capture.isCapturing) {
            await connections.refreshReverseProxyProblems()
        }
    }

    /// A port no reverse proxy uses yet, from 8080 up.
    private var suggestedPort: Int {
        let used = Set(connections.reverseProxies.map(\.localPort))
        return (8080...8999).first { !used.contains($0) && $0 != capture.port } ?? 8080
    }

    private func remove(_ id: ReverseProxy.ID) {
        connections.removeReverseProxy(id)
        if selection == id {
            selection = nil
        }
    }
}

private struct ReverseProxyRow: View {
    @Environment(ConnectionsModel.self) private var connections
    let proxy: ReverseProxy
    let problem: String?
    let isCapturing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                "Use This Reverse Proxy",
                isOn: Binding(get: { proxy.isOn }, set: { connections.setReverseProxy(proxy.id, on: $0) })
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(proxy.localAddress)
                        .font(.callout.monospaced())
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("to")
                    Text(proxy.server?.url ?? proxy.serverURL)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                status
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(proxy.isOn ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        if !proxy.isOn {
            Text("Off").foregroundStyle(.secondary)
        } else if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if isCapturing {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color("StatusSuccess"))
                    .frame(width: 6, height: 6)
                Text("Listening")
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Listens once you start capturing").foregroundStyle(.secondary)
        }
    }
}

/// Adds a reverse proxy, or changes one.
private struct ReverseProxyEditor: View {
    @Environment(ConnectionsModel.self) private var connections
    @Environment(CaptureModel.self) private var capture
    @Environment(\.dismiss) private var dismiss
    @State private var proxy: ReverseProxy
    @State private var port: String
    let isNew: Bool

    init(proxy: ReverseProxy, isNew: Bool) {
        _proxy = State(initialValue: proxy)
        _port = State(initialValue: String(proxy.localPort))
        self.isNew = isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Local port", text: $port, prompt: Text("8080"))
                    TextField("Server", text: $proxy.serverURL, prompt: Text("https://api.example.com"))
                    Toggle(isOn: $proxy.rewritesRedirects) {
                        Text("Keep redirects on this address")
                        Text("Redirects to the server point back at localhost, so the app keeps going through Reqly.")
                    }
                } header: {
                    Text(isNew ? "New Reverse Proxy" : "Reverse Proxy")
                } footer: {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if let server = proxy.server, let number = Int(port) {
                        Text("Apps that use http://localhost:\(String(number)) reach \(server.url).")
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
                Button(isNew ? "Add" : "Save") {
                    if let number = Int(port.trimmingCharacters(in: .whitespaces)) {
                        proxy.localPort = number
                    }
                    connections.saveReverseProxy(proxy)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500)
    }

    private var problem: String? {
        guard let number = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(number) else {
            return "The port is a number from 1 to 65535."
        }
        if number == capture.port {
            return "Port \(String(number)) is the one Reqly's proxy uses."
        }
        if connections.reverseProxies.contains(where: { $0.id != proxy.id && $0.localPort == number }) {
            return "Another reverse proxy uses port \(String(number))."
        }
        if proxy.serverURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the server that requests go to."
        }
        if proxy.server == nil {
            return "The server is an address such as https://api.example.com."
        }
        return nil
    }
}
