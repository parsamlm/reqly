import CoreInterface
import Foundation
import Presentation
import ReqlyModel

/// A name and its value, as a row of the details shows them, such as "Method" and "GET".
struct DetailsRow: Hashable {
    var name: String
    var value: String
    /// Whether the value is code, such as a header's or an address, which shows in a monospace
    /// font.
    var isCode = false
}

/// A section of a page: its title, such as "Response", how many it holds, when it says, and its
/// rows, or a line in their place, such as "No response yet."
struct DetailsSection: Hashable {
    var title: String
    var count: Int?
    var rows: [DetailsRow]
    var note: String?

    /// A section of `rows`, leaving out the rows with nothing to say, rather than "None".
    init(_ title: String, count: Int? = nil, rows: [DetailsRow], note: String? = nil) {
        self.title = title
        self.count = count
        self.rows = rows.filter { !$0.value.isEmpty }
        self.note = note
    }
}

/// What Overview says of an exchange, under its comment and its decryption note, as the Mac's
/// does: the URL; why it failed; the rules that changed it and what scripts printed; then a
/// section about the request, and either the encrypted connection's or the response's and the
/// connection's.
struct OverviewWords: Hashable {
    var url: String?
    var failure: String?
    var rules: DetailsSection?
    /// Each script's lines, under the script's name and the part it ran on.
    var scripts: [DetailsRow]
    var sections: [DetailsSection]

    init(_ details: ExchangeDetails, locale: Locale = .current, timeZone: TimeZone = .current) {
        let exchange = details.exchange
        url = exchange.request.url?.absoluteString
        failure = details.failure
        let rules = details.appliedRules.map { DetailsRow(name: $0.name, value: $0.detail) }
        self.rules = rules.isEmpty ? nil : DetailsSection("Rules", count: rules.count, rows: rules)
        scripts = exchange.scriptOutput.map {
            DetailsRow(
                name: "\($0.rule) · \($0.part == .request ? "onRequest" : "onResponse")",
                value: $0.lines.joined(separator: "\n"), isCode: true)
        }

        var request = [DetailsRow(name: "Method", value: exchange.request.method)]
        if let device = details.deviceName {
            request.append(DetailsRow(name: "Device", value: device))
        }
        if let source = exchange.source {
            request.append(DetailsRow(name: "App", value: source.name))
            if let bundleID = source.bundleID {
                request.append(DetailsRow(name: "Bundle ID", value: bundleID))
            } else if let path = source.path {
                request.append(DetailsRow(name: "Path", value: path, isCode: true))
            }
        }
        request.append(
            DetailsRow(
                name: "Started",
                value: DetailsFormat.moment(exchange.timing.started, locale: locale, timeZone: timeZone)
            ))
        request.append(DetailsRow(name: "Sent", value: DetailsFormat.size(exchange.bytesSent)))
        sections = [DetailsSection("Request", rows: request)]

        let duration = DetailsFormat.duration(exchange.timing.duration, locale: locale)
        let received = DetailsFormat.size(exchange.bytesReceived)
        if exchange.kind == .tunnel {
            sections.append(
                DetailsSection(
                    "Connection",
                    rows: [
                        DetailsRow(name: "HTTPS", value: Self.tunnelEncryption(exchange)),
                        DetailsRow(name: "Upstream proxy", value: exchange.upstreamProxy ?? ""),
                        DetailsRow(name: "Received", value: received),
                        DetailsRow(name: "Duration", value: duration),
                    ]))
            return
        }
        if let response = exchange.response {
            let grpc = details.grpc.map { "\($0.code) \($0.name)\($0.message.map { ": \($0)" } ?? "")" }
            sections.append(
                DetailsSection(
                    "Response",
                    rows: [
                        DetailsRow(name: "Status", value: "\(response.status) \(response.reason)"),
                        DetailsRow(name: "gRPC status", value: grpc ?? ""),
                        DetailsRow(name: "Received", value: received),
                        DetailsRow(name: "Content type", value: response.headers["Content-Type"] ?? ""),
                        DetailsRow(name: "Duration", value: duration),
                    ]))
        } else {
            sections.append(DetailsSection("Response", rows: [], note: "No response yet."))
        }
        sections.append(
            DetailsSection(
                "Connection",
                rows: [
                    DetailsRow(name: "Protocol", value: exchange.request.version),
                    DetailsRow(name: "To the server", value: exchange.serverProtocol ?? ""),
                    DetailsRow(
                        name: "WebSocket",
                        value: details.isWebSocket ? DetailsFormat.messages(exchange.messageCount, locale: locale) : ""
                    ),
                    DetailsRow(name: "HTTPS", value: Self.encryption(exchange) ?? ""),
                    DetailsRow(
                        name: "Reverse proxy", value: exchange.reverseProxy.map { "The app sent it to \($0)" } ?? ""),
                    DetailsRow(name: "Upstream proxy", value: exchange.upstreamProxy ?? ""),
                    DetailsRow(name: "Client certificate", value: exchange.clientCertificate ?? ""),
                ]))
    }

    /// What became of an encrypted connection: passed through, or a decryption the app refused.
    static func tunnelEncryption(_ exchange: Exchange) -> String {
        if case .failed(let failure) = exchange.state, failure.isDecryptionFailure {
            return "Reqly tried to decrypt it, but the app's handshake failed"
        }
        return "Encrypted, passed through untouched"
    }

    /// What HTTPS took part in the exchange: Reqly decrypted it, or Reqly itself spoke TLS with the
    /// server, such as for a request a rule sent from http to https.
    static func encryption(_ exchange: Exchange) -> String? {
        if exchange.isDecrypted {
            return "Decrypted by Reqly"
        }
        if exchange.request.scheme == "https" || exchange.tlsVersion != nil {
            return "Sent over TLS by Reqly"
        }
        return nil
    }
}

/// What the details say about decrypting a request's host, with the action that fits, in the
/// Mac's words: it says what happens to the host from now on, which may differ from what
/// happened to this request. Plain HTTP has none.
struct DecryptionNote: Hashable {
    enum Action: Hashable {
        case decrypt
        case stopDecrypting
    }

    /// What it looks like: a lock, an open lock, or a warning.
    enum Look: Hashable {
        case locked
        case unlocked
        case warning
    }

    var text: String
    var look: Look
    /// What its button does, or `nil` for none, as in a saved session, which decrypts nothing.
    var action: Action?
    /// Whether the button is the one to press, as for an encrypted connection Reqly could decrypt.
    var isSuggested = false
    let host: String

    /// `isDecrypting` says whether Reqly decrypts `host` now, or is `nil` when this session
    /// decrypts nothing, such as a saved one. `device` is the device the request came from, if
    /// any.
    init?(_ situation: DecryptionSituation, host: String, isDecrypting: Bool?, device: String? = nil) {
        self.host = host
        switch (situation, isDecrypting) {
        case (.plain, _), (.certificateRejected, nil):
            // The failure says what happened.
            return nil
        case (.encryptedTunnel, false):
            text = "This connection is encrypted, so Reqly can't show what's inside."
            look = .locked
            action = .decrypt
            isSuggested = true
        case (.encryptedTunnel, true):
            text = "Reqly now decrypts \(host). Its next requests show up decrypted."
            look = .unlocked
            action = .stopDecrypting
        case (.encryptedTunnel, nil):
            text = "This connection is encrypted, so Reqly can't show what's inside."
            look = .locked
        case (.decrypted, true):
            text = "Reqly decrypted this request."
            look = .unlocked
            action = .stopDecrypting
        case (.decrypted, nil):
            text = "Reqly decrypted this request."
            look = .unlocked
        case (.certificateRejected, true):
            // A device keeps the certificate it was given, so a new one here needs installing there too.
            text =
                device.map {
                    "\($0) may trust an earlier Reqly certificate. Install the current one on it, or stop decrypting \(host) to let its traffic through, encrypted."
                } ?? "Stopping decryption for \(host) lets its traffic through again, encrypted."
            look = .warning
            action = .stopDecrypting
        case (.decrypted, false), (.certificateRejected, false):
            text = "Reqly no longer decrypts \(host). Its connections pass through encrypted."
            look = .locked
            action = .decrypt
        }
    }

    /// Its button's title: "Decrypt api.weatherly.dev" or "Stop Decrypting api.weatherly.dev".
    var actionTitle: String? {
        switch action {
        case .decrypt: "Decrypt \(host)"
        case .stopDecrypting: "Stop Decrypting \(host)"
        case nil: nil
        }
    }
}
