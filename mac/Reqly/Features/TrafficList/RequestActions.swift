import AppKit
import BodyKit
import HAR
import ReqlyModel
import SwiftUI

/// What you can do with one request: copy it, send it again, or export it. The request list's
/// menu, the Request menu and the detail pane all use these.
@MainActor
struct RequestActions {
    /// The traffic the request belongs to: the session being captured, or a file's.
    let traffic: TrafficListModel
    let model: AppModel
    let openWindow: OpenWindowAction

    func copyURL(_ id: ExchangeID) {
        guard let url = traffic.summary(id)?.url else { return }
        Pasteboard.copy(url.absoluteString)
    }

    func copyCurl(_ id: ExchangeID) {
        Task {
            guard let exchange = await traffic.exchange(id), exchange.kind == .http else { return }
            Pasteboard.copy(CurlCommand.make(exchange.request, body: exchange.requestBody))
        }
    }

    /// The body unpacked: as text when it's text, as an image when it's an image.
    func copyResponseBody(_ id: ExchangeID) {
        Task {
            guard let exchange = await traffic.exchange(id), let response = exchange.response else { return }
            let encoding = response.headers["Content-Encoding"]
            let body =
                encoding.flatMap { BodyDecoder.decode(exchange.responseBody, contentEncoding: $0) }
                ?? exchange.responseBody
            if let text = BodyText.decode(body, contentType: response.headers["Content-Type"]) {
                Pasteboard.copy(text)
            } else if let image = NSImage(data: body) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            } else {
                Pasteboard.copy(body.prefix(1 << 20).map { String(format: "%02X", $0) }.joined(separator: " "))
            }
        }
    }

    /// Sends the request again from the session being captured, and shows it there.
    func resend(_ id: ExchangeID) {
        Task {
            guard let exchange = await traffic.exchange(id) else { return }
            model.resend(exchange)
            if traffic !== model.traffic {
                openWindow(id: "main")
            }
        }
    }

    func editAndResend(_ id: ExchangeID) {
        Task {
            guard let exchange = await traffic.exchange(id) else { return }
            openWindow(id: "composer", value: model.composer.newDraft(from: exchange))
        }
    }

    func exportHAR(_ id: ExchangeID?) {
        traffic.harExport = HARExportRequest(selected: id)
    }

    /// Opens the Rules window on a new rule for the request's host, path and method.
    func addRule(_ kind: RuleKind, for id: ExchangeID) {
        guard let summary = traffic.summary(id) else { return }
        model.rules.newRule(kind, from: summary)
        openWindow(id: "rules")
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
