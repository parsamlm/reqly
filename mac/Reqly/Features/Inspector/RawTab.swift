import BodyKit
import ReqlyModel
import SwiftUI

/// The request and the response as text, the way HTTP/1.1 writes them: the first line, the
/// headers, and the body when it's text.
struct RawTab: View {
    let exchange: Exchange
    /// Secrets such as cookies stay hidden here too, until you choose to show them.
    @State private var showsSecrets = false

    var body: some View {
        if hasSecrets {
            HStack(spacing: 8) {
                Text(
                    showsSecrets
                        ? "Cookies and authorization headers are showing."
                        : "Cookies and authorization headers are hidden."
                )
                .foregroundStyle(.secondary)
                Button(showsSecrets ? "Hide Them" : "Show Them") { showsSecrets.toggle() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
        RawSection(
            title: "Request", id: [AnyHashable(exchange.id), "request", AnyHashable(showsSecrets)],
            message: RawMessage(request: exchange.request, body: exchange.requestBody, hidingSecrets: !showsSecrets))
        if let response = exchange.response {
            RawSection(
                title: "Response", id: [AnyHashable(exchange.id), "response", AnyHashable(showsSecrets)],
                message: RawMessage(
                    response: response, body: exchange.responseBody, trailers: exchange.responseTrailers,
                    hidingSecrets: !showsSecrets))
        } else {
            DetailSection("Response") {
                Text(exchange.kind == .tunnel ? "Reqly doesn't decrypt this host." : "No response yet.")
                    .foregroundStyle(.secondary)
            }
        }
        if exchange.request.version == "HTTP/2" {
            Text(
                "HTTP/2 sends these as binary frames. Reqly writes them the way HTTP/1.1 does, so they're easy to read."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

extension RawTab {
    private var hasSecrets: Bool {
        exchange.request.headers.contains(where: \.isSecret)
            || exchange.response?.headers.contains(where: \.isSecret) == true
    }
}

private struct RawSection: View {
    @Environment(\.bodyViewerHeight) private var maxHeight
    let title: String
    let id: AnyHashable
    let message: RawMessage

    var body: some View {
        DetailSection(title) {
            // Long lines, such as cookies, wrap.
            CodeView(
                id: id, text: message.text, tokens: message.tokens, isCode: false,
                accessibilityName: "Raw \(title.lowercased())"
            )
            .frame(
                height: min(
                    CGFloat(message.rowCount) * CodeStyle.lineHeight + 2 * CodeStyle.inset.height, maxHeight)
            )
            .background(Color("CodeBackground"), in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityLabel("Raw \(title.lowercased())")
        }
        .overlay(alignment: .topTrailing) {
            Button("Copy Raw \(title)", systemImage: "doc.on.doc") {
                Pasteboard.copy(message.text)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy Raw \(title)")
        }
    }
}

/// A message as text, with its header names marked for coloring.
struct RawMessage {
    private(set) var text = ""
    private(set) var tokens: [SyntaxToken] = []

    /// About how many rows the text takes, with lines longer than 100 characters wrapping.
    var rowCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().reduce(0) {
            $0 + max(1, ($1.count + 99) / 100)
        }
    }

    /// Bodies longer than this show only their start.
    static let textLimit = 256 * 1024

    /// Whether secret header values, such as cookies, show as dots.
    private let hidesSecrets: Bool

    init(request: RequestHead, body: Data, hidingSecrets: Bool) {
        hidesSecrets = hidingSecrets
        append(line: "\(request.method) \(request.target) \(request.version)")
        append(request.headers)
        append(body: body, headers: request.headers, tab: "Request")
    }

    init(response: ResponseHead, body: Data, trailers: Headers?, hidingSecrets: Bool) {
        hidesSecrets = hidingSecrets
        append(line: "\(response.version) \(response.status) \(response.reason)".trimmingCharacters(in: .whitespaces))
        append(response.headers)
        append(body: body, headers: response.headers, tab: "Response")
        if let trailers, !trailers.isEmpty {
            append(line: "")
            append(trailers)
        }
    }

    private mutating func append(line: String) {
        text += line + "\n"
    }

    private mutating func append(_ headers: Headers) {
        for field in headers {
            let start = (text as NSString).length
            tokens.append(SyntaxToken(kind: .key, location: start, length: (field.name as NSString).length))
            let value = hidesSecrets && field.isSecret ? String(repeating: "•", count: 8) : field.value
            append(line: "\(field.name): \(value)")
        }
    }

    /// The body as text, or a line about it when it isn't text. Its own tab shows it in full.
    private mutating func append(body: Data, headers: Headers, tab: String) {
        guard !body.isEmpty else { return }
        append(line: "")
        let encoding = headers["Content-Encoding"].flatMap { $0.lowercased() == "identity" ? nil : $0 }
        let size = Format.size(Int64(body.count))
        if let encoding {
            note("\(size) of \(encoding)-compressed data. The \(tab) tab shows it unpacked.")
            return
        }
        let kind = BodyKind.detect(body, contentType: headers["Content-Type"])
        switch kind {
        case .image, .protobuf, .grpc, .binary:
            note("\(size) of \(kind == .binary ? "binary" : kind.name) data. The \(tab) tab shows it.")
        default:
            let shown = body.prefix(Self.textLimit)
            // A cut can fall inside a character, so up to three bytes may need to go.
            guard
                let decoded = (0...3).lazy.compactMap({
                    BodyText.decode(shown.dropLast($0), contentType: headers["Content-Type"])
                }).first
            else {
                note("\(size) of binary data. The \(tab) tab shows it.")
                return
            }
            text += decoded.hasSuffix("\n") ? decoded : decoded + "\n"
            if body.count > shown.count {
                append(line: "")
                note("Shows the first \(Format.size(Int64(shown.count))) of \(size).")
            }
        }
    }

    /// A line about the body, in place of bytes that aren't text.
    private mutating func note(_ words: String) {
        let start = (text as NSString).length
        let line = "‹\(words)›"
        tokens.append(SyntaxToken(kind: .comment, location: start, length: (line as NSString).length))
        append(line: line)
    }
}
