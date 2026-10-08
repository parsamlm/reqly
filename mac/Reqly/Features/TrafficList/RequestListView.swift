import ReqlyModel
import SwiftUI

/// The middle column: the live request list, or what to do when there's nothing to show.
struct RequestListView: View {
    @Environment(AppModel.self) private var model
    @Environment(TrafficListModel.self) private var traffic
    @Environment(HTTPSModel.self) private var https
    @Environment(\.trafficFile) private var file
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if traffic.isEmpty {
                if let file {
                    ContentUnavailableView(
                        "No Requests", systemImage: "doc",
                        description: Text("“\(file.lastPathComponent)” has no requests in it."))
                } else {
                    EmptyTrafficView()
                }
            } else {
                VStack(spacing: 0) {
                    FilterBar()
                    Divider()
                    RequestRows(actions: rowActions)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar()
        }
        .sheet(isPresented: settingUpHTTPS) {
            HTTPSSetupSheet()
        }
    }

    private var rowActions: RequestTableView.RowActions {
        let actions = RequestActions(traffic: traffic, model: model, openWindow: openWindow)
        return RequestTableView.RowActions(
            copyURL: actions.copyURL,
            copyCurl: actions.copyCurl,
            copyResponseBody: actions.copyResponseBody,
            resend: actions.resend,
            editAndResend: actions.editAndResend,
            exportHAR: actions.exportHAR,
            togglePin: { traffic.togglePin($0) },
            setColor: { traffic.setColor($0, for: $1) },
            editComment: { traffic.editComment(of: $0) },
            addRule: actions.addRule,
            // What's decrypted applies to capturing, so a file's window leaves it out.
            decryption: file == nil
                ? RequestTableView.Decryption(isDecrypting: https.isDecrypting, toggle: https.toggleDecryption) : nil
        )
    }

    private var settingUpHTTPS: Binding<Bool> {
        Binding(
            get: { file == nil && https.isShowingSetup },
            set: { if !$0 { https.cancelSetup() } }
        )
    }
}

/// The table, with No Matches in its place while the search or the filters leave nothing to
/// list. It's the only view that updates with every change to the rows.
private struct RequestRows: View {
    @Environment(TrafficListModel.self) private var traffic
    let actions: RequestTableView.RowActions

    var body: some View {
        @Bindable var traffic = traffic
        ZStack {
            RequestTableView(
                traffic: traffic, rowsVersion: traffic.rowsVersion, isHidden: traffic.nothingMatches,
                selection: $traffic.selection, actions: actions)
            if traffic.nothingMatches {
                NoMatchesView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Shown when the search or the filters leave nothing to list.
struct NoMatchesView: View {
    @Environment(TrafficListModel.self) private var traffic

    var body: some View {
        if traffic.filter.isActive {
            ContentUnavailableView {
                Label(
                    traffic.query.isEmpty ? "No Matching Requests" : "No Results for “\(traffic.query)”",
                    systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(
                    traffic.query.isEmpty
                        ? "No requests match the filters." : "No requests match both the search and the filters.")
            } actions: {
                Button("Clear Filters") {
                    traffic.clearFilters()
                }
            }
        } else {
            ContentUnavailableView.search(text: traffic.query)
        }
    }
}

/// Shown before the first request arrives.
struct EmptyTrafficView: View {
    @Environment(CaptureModel.self) private var capture
    @Environment(HTTPSModel.self) private var https

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(.quaternary, in: .circle)
            if capture.isCapturing {
                Text("Waiting for traffic")
                    .font(.title2)
                if capture.setsSystemProxy {
                    Text("Use an app that goes online, such as Safari. Its requests show up here.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Reqly isn't setting your Mac's proxy, so point apps at it yourself, for example:")
                        .foregroundStyle(.secondary)
                    Text("curl -x 127.0.0.1:\(String(capture.port)) http://example.com")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                }
            } else {
                Text("No traffic yet")
                    .font(.title2)
                Text(
                    capture.setsSystemProxy
                        ? "Start capturing to see what your Mac apps send and receive. While capturing, Reqly is your Mac's proxy. Your network settings come back when you stop."
                        : "Start capturing to see what your apps send and receive."
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                Button {
                    capture.toggle()
                } label: {
                    Text("Start Capturing")
                        .readableOnAccent()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(capture.isBusy)
                Text("or press ⌘R")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !https.isTrusted, https.status != .checking {
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                    Text("HTTPS traffic stays encrypted until you set up HTTPS.")
                    Button("Set Up HTTPS…") { https.showSetup() }
                        .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .padding(.top, 20)
            }
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The line under the request list: whether Reqly is capturing, and how many requests there are.
struct StatusBar: View {
    @Environment(CaptureModel.self) private var capture
    @Environment(DevicesModel.self) private var devices
    @Environment(ConnectionsModel.self) private var connections
    @Environment(TrafficListModel.self) private var traffic
    @Environment(\.trafficFile) private var file

    var body: some View {
        HStack(spacing: 6) {
            if let file {
                Image(systemName: "doc")
                Text(file.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                captureStatus
            }
            Spacer()
            if !traffic.isEmpty {
                RequestCount()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: capture.isCapturing) {
            // Reverse proxies start listening with capturing.
            await connections.refreshReverseProxyProblems()
        }
    }

    /// How many requests the list shows, out of how many there are. It's a view of its own, as
    /// it changes with every batch of traffic and the rest of the bar doesn't.
    private struct RequestCount: View {
        @Environment(TrafficListModel.self) private var traffic

        var body: some View {
            Text(
                traffic.visibleCount == traffic.totalCount
                    ? Format.requests(traffic.totalCount)
                    : "\(traffic.visibleCount.formatted()) of \(Format.requests(traffic.totalCount))"
            )
            .monospacedDigit()
        }
    }

    private var listeningReverseProxies: [ReverseProxy] {
        connections.reverseProxies.filter { $0.isOn && connections.reverseProxyProblems[$0.id] == nil }
    }

    /// How many reverse proxies listen, such as " · 1 reverse proxy".
    private var reverseProxyNote: String {
        switch listeningReverseProxies.count {
        case 0: ""
        case 1: " · 1 reverse proxy"
        case let count: " · \(count) reverse proxies"
        }
    }

    /// The upstream proxy and the reverse proxies in full, for the tooltip.
    private var connectionsHelp: String {
        var sentences: [String] = []
        if let proxy = connections.activeUpstreamProxy {
            sentences.append("Traffic goes through the upstream proxy at \(proxy.address).")
        }
        for proxy in listeningReverseProxies {
            sentences.append(
                "A reverse proxy on \(proxy.localAddress) sends requests to \(proxy.server?.url ?? proxy.serverURL).")
        }
        return sentences.joined(separator: " ")
    }

    @ViewBuilder
    private var captureStatus: some View {
        Group {
            switch capture.status {
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            case .capturing(let port):
                if let warning = capture.warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(warning)
                } else {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Color("StatusSuccess"))
                        .accessibilityHidden(true)
                    Text(
                        (capture.setsSystemProxy
                            ? "Capturing on port \(String(port))"
                            : "Capturing on port \(String(port)) · Mac proxy not set")
                            + (devices.allowsNetworkDevices ? " · Devices can connect" : "")
                            + (connections.activeUpstreamProxy.map { " · Via \($0.address)" } ?? "")
                            + reverseProxyNote
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(connectionsHelp)
                }
            case .starting:
                Text("Starting…")
            case .waitingForApproval:
                Text("Waiting for you to allow Reqly's helper…")
            case .stopping:
                Text("Stopping…")
            case .stopped:
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Not capturing · Port \(String(capture.port))")
            }
        }
    }
}
