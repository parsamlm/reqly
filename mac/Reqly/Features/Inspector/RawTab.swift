import BodyKit
import Presentation
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
