import BodyKit
import ReqlyModel
import SwiftUI

/// The detail pane for the selected request, or for one request, as the composer shows the one
/// it sent.
struct InspectorView: View {
    @Environment(TrafficListModel.self) private var traffic
    /// The exchange to show, or `nil` for the list's selection.
    var exchangeID: ExchangeID?
    @State private var exchange: Exchange?
    @State private var tab = Self.firstTab

    private static var firstTab: Tab {
        #if DEBUG
            if let name = UserDefaults.standard.string(forKey: DefaultsKey.inspectorTab),
                let tab = Tab(rawValue: name.capitalized)
            {
                return tab
            }
        #endif
        return .overview
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case request = "Request"
        case response = "Response"
        /// For connections that switched to WebSocket.
        case messages = "Messages"
        case raw = "Raw"
        case timing = "Timing"

        var id: Self { self }

        /// The View menu's order, which gives each section the same shortcut, ⌘1 to ⌘6, whether
        /// or not the request has messages.
        static let shortcutOrder: [Tab] = [.overview, .request, .response, .raw, .timing, .messages]
    }

    /// The tabs for an exchange. Only WebSocket connections have messages.
    private static func tabs(for summary: ExchangeSummary) -> [Tab] {
        summary.isWebSocket ? Tab.allCases : Tab.allCases.filter { $0 != .messages }
    }

    private var summary: ExchangeSummary? {
        if let exchangeID {
            return traffic.summary(exchangeID)
        }
        return traffic.selectedSummary
    }

    var body: some View {
        if let id = exchangeID ?? traffic.selection, traffic.paused[id] != nil {
            // Waiting at a breakpoint, maybe before its summary reaches the list.
            PausedEditor(id: id, summary: summary)
        } else if let summary {
            VStack(alignment: .leading, spacing: 0) {
                let tabs = Self.tabs(for: summary)
                // A tab the exchange doesn't have, such as Messages, stays chosen for the next one.
                let shownTab = tabs.contains(tab) ? tab : .overview
                InspectorHeader(summary: summary, reason: exchange?.response?.reason, grpcStatus: exchange?.grpcStatus)
                Picker("Section", selection: Binding(get: { shownTab }, set: { tab = $0 })) {
                    ForEach(tabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .focusedSceneValue(\.inspectorTab, Binding(get: { shownTab }, set: { tab = $0 }))
                .focusedSceneValue(\.inspectorTabs, tabs)
                Divider()
                GeometryReader { geometry in
                    ScrollView {
                        if let exchange, exchange.id == summary.id {
                            VStack(alignment: .leading, spacing: 24) {
                                switch shownTab {
                                case .overview: OverviewTab(exchange: exchange)
                                case .request:
                                    MessageTab(
                                        part: .request, headers: exchange.request.headers, data: exchange.requestBody,
                                        query: exchange.request.query, emptyBody: "This request has no body.",
                                        bodyID: BodyID(
                                            exchange: exchange.id, part: "request", size: exchange.requestBody.count),
                                        rootLabel: "Request", url: exchange.request.url)
                                case .response: ResponseTab(exchange: exchange)
                                case .messages:
                                    MessagesTab(exchange: exchange)
                                        .id(exchange.id)
                                case .raw: RawTab(exchange: exchange)
                                case .timing: TimingTab(exchange: exchange)
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // A long body scrolls inside its viewer, which is about as tall as the pane.
                    .environment(\.bodyViewerHeight, max(240, geometry.size.height - 120))
                }
            }
            .task(id: summary.ignoringAnnotation) {
                #if DEBUG
                    let started = ContinuousClock.now
                #endif
                exchange = await traffic.exchange(summary.id)
                #if DEBUG
                    PerfProbe.inspectorShowed(summary.id, took: .now - started)
                #endif
            }
            .onChange(of: traffic.commentToEdit) { _, id in
                if id != nil {
                    tab = .overview
                }
            }
        } else if exchangeID != nil {
            // Sent, and on its way into the list.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Request Selected",
                systemImage: "cursorarrow.click",
                description: Text("Select a request to see its details.")
            )
        }
    }
}

private struct InspectorHeader: View {
    let summary: ExchangeSummary
    let reason: String?
    let grpcStatus: GRPCStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.kind == .tunnel ? "CONNECT" : summary.method)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text(summary.kind == .tunnel ? summary.displayHost : summary.path)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                AnnotationButtons(summary: summary)
            }
            Text(subtitle)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatusLabel(summary: summary, reason: reason)
                if let grpcStatus {
                    Text("gRPC \(grpcStatus.name)")
                        .foregroundStyle(grpcStatus.code == 0 ? .secondary : .primary)
                        .help(grpcStatus.message ?? grpcStatus.title)
                }
                if summary.isWebSocket {
                    Text(summary.messageCount == 1 ? "1 message" : "\(summary.messageCount.formatted()) messages")
                }
                if let duration = summary.duration {
                    Text(Format.duration(duration))
                }
                Text(Format.size(summary.bytesReceived))
                Text(Format.time(summary.started))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Where the request went and what sent it, such as "api.weatherly.dev · Weatherly", and
    /// the device, such as "· iPhone 17 Pro".
    private var subtitle: String {
        let destination = summary.kind == .tunnel ? "Encrypted connection" : summary.displayHost
        return ([destination, summary.source?.name, summary.device?.name].compactMap { $0 }).joined(separator: " · ")
    }
}

/// Pins the request, marks it with a color, and starts a comment on it.
private struct AnnotationButtons: View {
    @Environment(TrafficListModel.self) private var traffic
    let summary: ExchangeSummary

    var body: some View {
        let annotation = summary.annotation
        HStack(spacing: 4) {
            Button(
                annotation.isPinned ? "Unpin Request" : "Pin Request",
                systemImage: annotation.isPinned ? "pin.fill" : "pin"
            ) {
                traffic.togglePin(summary.id)
            }
            .foregroundStyle(annotation.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help(annotation.isPinned ? "Unpin Request" : "Pin Request. Pinned requests stay when you clear traffic.")

            Menu {
                Picker("Color", selection: color) {
                    Text("None").tag(MarkColor?.none)
                    Divider()
                    ForEach(MarkColor.allCases, id: \.self) { color in
                        Label {
                            Text(color.title)
                        } icon: {
                            if let image = color.menuImage {
                                Image(nsImage: image)
                            }
                        }
                        .tag(MarkColor?.some(color))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                // A menu draws its label as a template, so the color comes from the image itself.
                if let image = annotation.color?.menuImage {
                    Label {
                        Text("Color")
                    } icon: {
                        Image(nsImage: image).renderingMode(.original)
                    }
                } else {
                    Label("Color", systemImage: "circle")
                }
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .fixedSize()
            .help("Mark with a Color")

            Button(
                annotation.comment == nil ? "Add Comment" : "Edit Comment",
                systemImage: annotation.comment == nil ? "text.bubble" : "text.bubble.fill"
            ) {
                traffic.editComment(of: summary.id)
            }
            .foregroundStyle(.secondary)
            .help(annotation.comment == nil ? "Add Comment" : "Edit Comment")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private var color: Binding<MarkColor?> {
        Binding(
            get: { summary.annotation.color },
            set: { traffic.setColor($0, for: summary.id) }
        )
    }
}

/// A status dot with the code and its reason, such as "200 OK". Failures get a warning symbol.
struct StatusLabel: View {
    let summary: ExchangeSummary
    var reason: String?

    var body: some View {
        HStack(spacing: 5) {
            if case .failed = summary.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Failed")
                    .foregroundStyle(.primary)
            } else if case .paused = summary.state {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.tint)
                Text("Paused")
                    .foregroundStyle(.primary)
            } else if let status = summary.status {
                Circle()
                    .fill(summary.statusClass?.color ?? .gray)
                    .frame(width: 7, height: 7)
                Text(String(status)).bold().foregroundStyle(.primary)
                if let reason {
                    Text(reason)
                }
            } else if summary.kind == .tunnel {
                Image(systemName: "lock.fill")
                Text(summary.state == .open ? "Open" : "Closed")
            } else {
                Text("In progress")
            }
        }
    }
}

// MARK: - Tabs

private struct OverviewTab: View {
    @Environment(TrafficListModel.self) private var traffic
    let exchange: Exchange

    var body: some View {
        // The list's copy of the annotation is the latest; the exchange's may not be saved yet.
        CommentSection(id: exchange.id, comment: traffic.summary(exchange.id)?.annotation.comment)
            .id(exchange.id)
        DecryptionCallout(
            summary: ExchangeSummaryForCallout(
                host: exchange.request.host, situation: situation, device: exchange.device?.name))
        if let url = exchange.request.url {
            DetailSection("URL") {
                Text(url.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
        }
        if case .failed(let failure) = exchange.state {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        let rules = exchange.appliedRules.joinedByRule
        if !rules.isEmpty {
            DetailSection("Rules", count: rules.count) {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    AppliedRuleRow(rule: rule)
                }
            }
        }
        if !exchange.scriptOutput.isEmpty {
            DetailSection("Script output") {
                ForEach(Array(exchange.scriptOutput.enumerated()), id: \.offset) { _, output in
                    ScriptOutputRow(output: output)
                }
            }
        }
        DetailSection("Request") {
            DetailRow("Method", exchange.request.method)
            if let device = exchange.device {
                DetailRow("Device", device.fullName)
            }
            if let source = exchange.source {
                DetailRow("App", source.name)
                if let bundleID = source.bundleID {
                    DetailRow("Bundle ID", bundleID)
                } else if let path = source.path {
                    DetailRow("Path", path)
                }
            }
            DetailRow(
                "Started",
                exchange.timing.started.formatted(
                    .dateTime.month().day().hour().minute().second().secondFraction(.fractional(3))))
            DetailRow("Sent", Format.size(exchange.bytesSent))
        }
        if exchange.kind == .tunnel {
            DetailSection("Connection") {
                DetailRow("HTTPS", exchange.tunnelEncryption)
                if let proxy = exchange.upstreamProxy {
                    DetailRow("Upstream proxy", proxy)
                }
                DetailRow("Received", Format.size(exchange.bytesReceived))
                DetailRow("Duration", Format.duration(exchange.timing.duration))
            }
        } else {
            DetailSection("Response") {
                if let response = exchange.response {
                    DetailRow("Status", "\(response.status) \(response.reason)")
                    if let status = exchange.grpcStatus {
                        DetailRow(
                            "gRPC status",
                            "\(status.code) \(status.name)\(status.message.map { ": \($0)" } ?? "")")
                    }
                    DetailRow("Received", Format.size(exchange.bytesReceived))
                    DetailRow("Content type", response.headers["Content-Type"] ?? "None")
                    DetailRow("Duration", Format.duration(exchange.timing.duration))
                } else {
                    Text("No response yet.")
                        .foregroundStyle(.secondary)
                }
            }
            DetailSection("Connection") {
                DetailRow("Protocol", exchange.request.version)
                if let serverProtocol = exchange.serverProtocol {
                    DetailRow("To the server", serverProtocol)
                }
                if exchange.summary.isWebSocket {
                    DetailRow(
                        "WebSocket",
                        exchange.messageCount == 1 ? "1 message" : "\(exchange.messageCount.formatted()) messages")
                }
                if let encryption {
                    DetailRow("HTTPS", encryption)
                }
                if let proxy = exchange.reverseProxy {
                    DetailRow("Reverse proxy", "The app sent it to \(proxy)")
                }
                if let proxy = exchange.upstreamProxy {
                    DetailRow("Upstream proxy", proxy)
                }
                if let certificate = exchange.clientCertificate {
                    DetailRow("Client certificate", certificate)
                }
            }
        }
    }

    private var situation: ExchangeSummaryForCallout.Situation {
        switch (exchange.kind, exchange.state) {
        case (.tunnel, .failed(let failure)) where failure.isDecryptionFailure: .certificateRejected
        case (.tunnel, .failed): .plain
        case (.tunnel, _): .encryptedTunnel
        case (.http, _): exchange.isDecrypted ? .decrypted : .plain
        }
    }

    /// What HTTPS took part in the exchange: Reqly decrypted it, or Reqly itself spoke TLS with the
    /// server, such as for a request a Map Remote rule sent from http to https.
    private var encryption: String? {
        if exchange.isDecrypted {
            return "Decrypted by Reqly"
        }
        if exchange.request.scheme == "https" || exchange.tlsVersion != nil {
            return "Sent over TLS by Reqly"
        }
        return nil
    }
}

/// The comment written on the request. It shows once there is one, or while you write it, and
/// saves when you press Return, click away or move to another request.
private struct CommentSection: View {
    @Environment(TrafficListModel.self) private var traffic
    let id: ExchangeID
    let comment: String?
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    /// Add Comment asked for this request's comment, and it's still being written.
    private var isEditing: Bool { traffic.commentToEdit == id }

    var body: some View {
        if comment != nil || isEditing {
            DetailSection("Comment") {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onSubmit { isFocused = false }
            }
            .onAppear {
                draft = comment ?? ""
                focusIfEditing()
            }
            .onChange(of: isEditing) {
                focusIfEditing()
            }
            .onChange(of: comment) { _, comment in
                if !isFocused {
                    draft = comment ?? ""
                }
            }
            .onChange(of: isFocused) { _, isFocused in
                guard !isFocused else { return }
                save()
                if isEditing {
                    traffic.commentToEdit = nil
                }
            }
            .onDisappear(perform: save)
        }
    }

    private func focusIfEditing() {
        guard isEditing else { return }
        // The field takes focus once it's in the window, after this update.
        Task { isFocused = true }
    }

    private func save() {
        if draft != (comment ?? "") {
            traffic.setComment(draft, for: id)
        }
    }
}

private struct ResponseTab: View {
    let exchange: Exchange

    var body: some View {
        if let response = exchange.response {
            MessageTab(
                part: .response, headers: response.headers, data: exchange.responseBody, query: nil,
                emptyBody: "This response has no body.",
                bodyID: BodyID(exchange: exchange.id, part: "response", size: exchange.responseBody.count),
                rootLabel: "Response", url: exchange.request.url)
            if let trailers = exchange.responseTrailers, !trailers.isEmpty {
                DetailSection("Trailers", count: trailers.count) {
                    ForEach(Array(trailers.enumerated()), id: \.offset) { _, field in
                        HeaderRow(field: field)
                    }
                }
            }
        } else if exchange.kind == .tunnel {
            Text("Reqly doesn't decrypt this host, so the response isn't readable.")
                .foregroundStyle(.secondary)
        } else {
            Text("No response yet.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Headers, query parameters, cookies and body of a request or a response.
private struct MessageTab: View {
    let part: MessagePart
    let headers: Headers
    let data: Data
    let query: String?
    let emptyBody: String
    let bodyID: BodyID
    let rootLabel: String
    let url: URL?

    var body: some View {
        if let query, !query.isEmpty {
            let parameters = Self.parameters(in: query)
            DetailSection("Query parameters", count: parameters.count) {
                ForEach(Array(parameters.enumerated()), id: \.offset) { _, parameter in
                    DetailRow(parameter.name, parameter.value, monospaced: true)
                }
            }
        }
        DetailSection("Headers", count: headers.count) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, field in
                HeaderRow(field: field)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !headers.isEmpty {
                Button("Copy Headers", systemImage: "doc.on.doc") {
                    Pasteboard.copy(headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy Headers")
            }
        }
        // A request sends cookies, and a response sets them.
        if part == .request {
            CookiesSection(sent: headers.requestCookies)
        } else {
            CookiesSection(set: headers.responseCookies)
        }
        BodySection(
            id: bodyID, data: data, headers: headers, emptyText: emptyBody, rootLabel: rootLabel, url: url)
    }

    private static func parameters(in query: String) -> [(name: String, value: String)] {
        query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).removingPercentEncoding ?? String($0)
            }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
    }
}

// MARK: - Building blocks

struct DetailSection<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder let content: Content

    init(_ title: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if let count {
                    Text(count.formatted()).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    init(_ label: String, _ value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension [AppliedRule] {
    /// One line for each rule. A rule that acted more than once, such as on the request and
    /// then on the response, gets everything it did on its line.
    var joinedByRule: [AppliedRule] {
        var joined: [AppliedRule] = []
        for rule in self {
            if let index = joined.firstIndex(where: { $0.name == rule.name && $0.kind == rule.kind }) {
                joined[index].detail += " " + rule.detail
            } else {
                joined.append(rule)
            }
        }
        return joined
    }
}

/// A rule that acted on the exchange: its kind, its name and what it did.
private struct AppliedRuleRow: View {
    let rule: AppliedRule

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(rule.name, systemImage: rule.kind.symbol)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
                .help("\(rule.kind.title): \(rule.name)")
            Text(rule.detail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// What one script printed with `console.log` while it ran on the request or the response.
private struct ScriptOutputRow: View {
    let output: ScriptOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "\(output.rule) · \(output.part == .request ? "onRequest" : "onResponse")",
                systemImage: RuleKind.script.symbol
            )
            .foregroundStyle(.secondary)
            Text(output.lines.joined(separator: "\n"))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        }
        .font(.callout)
        .padding(.vertical, 5)
    }
}

/// A header line. Secrets such as tokens and cookies stay hidden until you choose to show them.
private struct HeaderRow: View {
    let field: HeaderField
    @State private var isRevealed = false

    var body: some View {
        let isSecret = field.isSecret && !isRevealed
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(field.name)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(isSecret ? String(repeating: "•", count: min(max(field.value.count, 8), 16)) : field.value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isSecret {
                Button("Show") { isRevealed = true }
                    .buttonStyle(.link)
                    .accessibilityLabel("Show \(field.name)")
            }
        }
        .font(.callout.monospaced())
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider() }
    }
}
