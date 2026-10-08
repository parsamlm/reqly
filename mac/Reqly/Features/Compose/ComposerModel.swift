import Foundation
import Observation
import ProxyEngine
import ReqlyModel

/// The requests being written in composer windows, one draft for each window.
@Observable
final class ComposerModel {
    private var drafts: [UUID: ComposerDraft] = [:]

    /// A new draft, blank or filled in from a captured exchange, for a new window to show.
    func newDraft(from exchange: Exchange? = nil) -> UUID {
        let draft = ComposerDraft()
        if let exchange {
            draft.fill(from: exchange)
        }
        drafts[draft.id] = draft
        return draft.id
    }

    /// The draft for a window. A window that outlived its draft, such as one macOS restored
    /// after Reqly restarted, gets a blank one.
    func draft(_ id: UUID?) -> ComposerDraft {
        if let id, let draft = drafts[id] {
            return draft
        }
        let draft = ComposerDraft(id: id ?? UUID())
        drafts[draft.id] = draft
        return draft
    }

    func close(_ id: UUID) {
        drafts[id] = nil
    }
}

/// A request as you write it, before it's sent.
@Observable
final class ComposerDraft: Identifiable {
    let id: UUID
    var method = "GET"
    var url = "https://"
    var headers: [EditableHeader] = []
    var body = ""
    /// A body that isn't text. It's sent as it was, unless you remove it.
    var binaryBody: Data?
    /// The exchange the last Send recorded.
    var sent: ExchangeID?
    /// Why the request can't be sent as it is.
    var problem: String?

    init(id: UUID = UUID()) {
        self.id = id
    }

    /// Reqly sets these itself when it sends the request, from the URL and the body, and leaves
    /// out the ones meant for a proxy.
    static let framingHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "proxy-connection", "proxy-authorization",
    ]

    func fill(from exchange: Exchange) {
        method = exchange.request.method
        url = exchange.request.url?.absoluteString ?? ""
        headers = exchange.request.headers
            .filter { !Self.framingHeaders.contains($0.name.lowercased()) }
            .map { EditableHeader(name: $0.name, value: $0.value) }
        if let text = String(data: exchange.requestBody, encoding: .utf8) {
            body = text
        } else {
            binaryBody = exchange.requestBody
        }
    }

    /// The request to send, or `nil` with ``problem`` saying what to fix.
    func request() -> OutgoingRequest? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host(), !host.isEmpty
        else {
            problem = "Enter a URL that starts with http:// or https://."
            return nil
        }
        problem = nil
        let fields = headers.compactMap { header -> HeaderField? in
            let name = header.name.trimmingCharacters(in: .whitespaces)
            return header.isOn && !name.isEmpty ? HeaderField(name: name, value: header.value) : nil
        }
        return OutgoingRequest(method: method, url: url, headers: Headers(fields), body: binaryBody ?? Data(body.utf8))
    }
}

struct EditableHeader: Identifiable, Hashable {
    let id = UUID()
    /// Whether to send it. Turning a header off keeps it for later.
    var isOn = true
    var name: String
    var value: String
}
