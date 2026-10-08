import ReqlyModel
import SwiftUI

/// The messages of a connection that switched to WebSocket, in the order they went, with the
/// selected one below them. New messages join the list while the connection is open.
struct MessagesTab: View {
    @Environment(TrafficListModel.self) private var traffic
    @Environment(\.bodyViewerHeight) private var maxHeight
    let exchange: Exchange
    @State private var messages: [WebSocketMessage] = []
    @State private var hasLoaded = false
    @State private var selection: Int?
    @State private var direction: DirectionFilter = .all
    @State private var filter = ""

    private static let rowHeight: CGFloat = 24

    enum DirectionFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case sent = "Sent"
        case received = "Received"

        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !hasLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if messages.isEmpty {
                Text(exchange.state == .open ? "No messages yet." : "The connection didn't carry any messages.")
                    .foregroundStyle(.secondary)
            } else {
                list
                if let selection, messages.indices.contains(selection) {
                    MessageDetail(exchange: exchange, number: selection, message: messages[selection])
                        .padding(.top, 16)
                }
            }
        }
        .task(id: exchange.messageCount) {
            // Only the messages that are new since last time.
            let more = await traffic.messages(of: exchange.id, from: messages.count)
            guard !Task.isCancelled else { return }
            messages += more
            hasLoaded = true
            #if DEBUG
                let place = UserDefaults.standard.integer(forKey: DefaultsKey.selectMessage)
                if selection == nil, place > 0, place <= messages.count {
                    selection = place - 1
                }
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Messages").font(.headline)
            Text(messages.count.formatted())
                .foregroundStyle(.secondary)
            Spacer()
            if !messages.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Filter messages", text: $filter)
                        .textFieldStyle(.plain)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .frame(width: 180, height: 22)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                Picker("Direction", selection: $direction) {
                    ForEach(DirectionFilter.allCases) { direction in
                        Text(direction.rawValue).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    /// The messages that pass the filters, by their numbers.
    private var shown: [Int] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return messages.indices.filter { index in
            let message = messages[index]
            switch direction {
            case .all: break
            case .sent: if message.direction != .sent { return false }
            case .received: if message.direction != .received { return false }
            }
            guard !query.isEmpty else { return true }
            return message.text?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var list: some View {
        let shown = shown
        return List(shown, id: \.self, selection: $selection) { index in
            MessageRow(message: messages[index], started: exchange.timing.started)
                .contextMenu {
                    Button("Copy Message") { copy(messages[index]) }
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .frame(height: min(max(CGFloat(shown.count) * Self.rowHeight + 8, 96), max(160, maxHeight * 0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .overlay {
            if shown.isEmpty {
                Text("No messages match.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ message: WebSocketMessage) {
        if let text = message.text {
            Pasteboard.copy(text)
        } else {
            Pasteboard.copy(message.data.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
    }
}

/// One message: which way it went, its kind, the start of what it says, its size and when.
private struct MessageRow: View {
    let message: WebSocketMessage
    let started: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.direction == .sent ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(message.direction == .sent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 14)
                .help(message.direction == .sent ? "Sent by the app" : "Received from the server")
            Text(message.kind.title)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(preview)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.size(Int64(message.size)))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text("+" + Format.duration(max(0, message.time.timeIntervalSince(started))))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
                .help(message.time.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
        }
        .font(.callout)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(message.direction == .sent ? "Sent" : "Received") \(message.kind.title.lowercased()), \(preview)")
    }

    /// The start of the message: its text, a close's code and reason, or bytes as hex.
    private var preview: String {
        if message.kind == .close {
            let code =
                message.closeCode.map { code in
                    let meaning = WebSocketMessage.closeReason(code)
                    return meaning.isEmpty ? String(code) : "\(code) \(meaning)"
                } ?? "No code"
            let reason = message.text.flatMap { $0.isEmpty ? nil : $0 }
            return reason.map { "\(code) · \($0)" } ?? code
        }
        if let text = message.text ?? readableControlText {
            let line = text.prefix(300).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty && !text.isEmpty ? "⏎" : line
        }
        return message.data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// What a ping or pong says, when it's text, as it often is.
    private var readableControlText: String? {
        guard message.kind == .ping || message.kind == .pong,
            let text = String(data: message.data, encoding: .utf8),
            !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return text
    }
}

/// The selected message, with a viewer that suits what it holds, as for a body.
private struct MessageDetail: View {
    let exchange: Exchange
    let number: Int
    let message: WebSocketMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Message \((number + 1).formatted()) · \(message.direction == .sent ? "Sent" : "Received") · \(message.kind.title) · \(message.time.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if message.size > message.data.count {
                Text("Reqly kept the first \(Format.bytes(message.data.count)) of \(Format.bytes(message.size)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            BodySection(
                id: BodyID(exchange: exchange.id, part: "message \(number)", size: message.data.count),
                data: message.data,
                headers: [
                    "Content-Type": message.kind == .binary ? "application/octet-stream" : "text/plain; charset=utf-8"
                ],
                emptyText: message.kind == .close ? "This close message has no reason." : "This message is empty.",
                rootLabel: "Message", url: exchange.request.url)
        }
    }
}

extension WebSocketMessage.Kind {
    var title: String {
        switch self {
        case .text: "Text"
        case .binary: "Binary"
        case .close: "Close"
        case .ping: "Ping"
        case .pong: "Pong"
        }
    }
}

extension WebSocketMessage {
    /// What a close code means, in a few words.
    static func closeReason(_ code: Int) -> String {
        switch code {
        case 1000: "Normal"
        case 1001: "Going away"
        case 1002: "Protocol error"
        case 1003: "Unsupported data"
        case 1005: "No status"
        case 1006: "Closed abnormally"
        case 1007: "Invalid data"
        case 1008: "Policy violation"
        case 1009: "Too big"
        case 1010: "Extension needed"
        case 1011: "Server error"
        case 1012: "Restarting"
        case 1013: "Try again later"
        case 1015: "TLS failed"
        default: ""
        }
    }
}
