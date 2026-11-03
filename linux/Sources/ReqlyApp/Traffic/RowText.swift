import CoreInterface
import Foundation
import ReqlyModel

/// What a row says, as the Mac's list says it: each column's words, how its status shows, its
/// marks, and the words screen readers hear for the whole row, one cell after another.
struct RowText: Equatable {
    /// How the Status column shows a request, before its code.
    enum Look: Equatable {
        /// A dot in the status class's color: for gRPC behind HTTP 200, the call's own class.
        case status(StatusClass)
        /// A warning, in red.
        case failed
        /// A pause symbol, in the accent color, while a breakpoint holds it.
        case paused
        /// A lock, for an encrypted connection Reqly passed through.
        case encrypted
        /// A dotted circle, while there's no response yet.
        case waiting
    }

    var look: Look
    /// The code, such as 200, or Failed or Paused. An encrypted connection and a request in
    /// progress have none.
    var status: String
    /// The status in words, for screen readers, which skip the dot and the symbols: the failure's
    /// message, a breakpoint's hold, an encrypted connection, the code and what it means, with a
    /// gRPC call's own status, or "In progress".
    var statusDescription: String
    /// What the status's tooltip says, for a gRPC call that failed behind HTTP 200.
    var statusHelp: String?
    var method: String
    /// The host, with the port when it isn't the scheme's own, such as `localhost:8080`.
    var host: String
    /// After the host, dimmed: the path and query, or what an encrypted connection is.
    var path: String
    var isEncrypted: Bool
    /// The app that sent it, or the device's name when the app isn't known.
    var app: String
    /// The app and the device it's on, for the App column's tooltip, when a device sent it.
    var appHelp: String?
    var time: String
    var duration: String
    /// What the response's body weighed, once it's arriving or done.
    var size: String
    var isPinned: Bool
    var color: MarkColor?
    var comment: String?

    init(_ summary: ExchangeSummary, locale: Locale = .current, timeZone: TimeZone = .current) {
        isEncrypted = summary.kind == .tunnel
        method = summary.method
        let isDefaultPort = summary.port == (summary.scheme == "https" ? 443 : summary.scheme == "http" ? 80 : nil)
        host = isDefaultPort ? summary.host : "\(summary.host):\(summary.port)"
        path = isEncrypted ? "Encrypted connection" : summary.target
        if summary.source == nil, let device = summary.device {
            app = device.name
            appHelp = device.fullName
        } else {
            app = summary.source?.name ?? ""
            appHelp = summary.device.flatMap { device in summary.source.map { "\($0.name) on \(device.fullName)" } }
        }
        time = Format.time(summary.started, locale: locale, timeZone: timeZone)
        duration = Format.duration(summary.duration, locale: locale)
        size = summary.bytesReceived > 0 || summary.state == .completed ? Format.size(summary.bytesReceived) : ""
        isPinned = summary.annotation.isPinned
        color = summary.annotation.color
        comment = summary.annotation.comment
        switch summary.state {
        case .failed(let failure):
            look = .failed
            status = "Failed"
            statusDescription = failure.message
        case .paused(let part):
            look = .paused
            status = "Paused"
            statusDescription = "Paused at a breakpoint, before the \(part.rawValue) goes on"
        case _ where isEncrypted:
            look = .encrypted
            status = ""
            statusDescription = summary.state == .open ? "Encrypted connection, open" : "Encrypted connection"
        case _ where summary.status != nil:
            let code = summary.status ?? 0
            look = .status(summary.statusClass ?? .informational)
            status = String(code)
            let meaning = Self.reason(code).map { "\(code) \($0)" } ?? String(code)
            if let grpc = summary.grpcStatus, grpc != 0 {
                let call = GRPCStatus(code: grpc)
                statusDescription = "\(meaning), gRPC status \(call.code) \(call.title.lowercased())"
                statusHelp = statusDescription
            } else {
                statusDescription = meaning
            }
        default:
            look = .waiting
            status = ""
            statusDescription = "In progress"
        }
    }

    /// What the Request column shows: the host, then, dimmed, the path, or two spaces apart, what
    /// an encrypted connection is.
    var request: (host: String, rest: String) {
        (host, isEncrypted ? "  " + path : path)
    }

    /// The row's words for screen readers, as its cells say them, one after another: "200 OK,
    /// GET, api.example.com/v1/items, Firefox, 11:05:59 AM, 161 ms, 292 B, pinned, marked red,
    /// comment: …". An encrypted connection's status says what it is, so its address is only
    /// the host. A cell with nothing in it says nothing.
    var label: String {
        // A failure's message is a sentence, which the next words go on from.
        let status = statusDescription.hasSuffix(".") ? String(statusDescription.dropLast()) : statusDescription
        var words = [status, method, isEncrypted ? host : host + path, app, time, duration, size]
        if isPinned {
            words.append("pinned")
        }
        if let color {
            words.append("marked \(color.title.lowercased())")
        }
        if let comment {
            words.append("comment: \(comment)")
        }
        return words.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Where a row is in the list, for screen readers: "Request 3 of 10,000", counted from 1.
    static func position(_ row: Int, of count: Int, locale: Locale = .current) -> String {
        "Request \(Format.count(row + 1, locale: locale)) of \(Format.count(count, locale: locale))"
    }

    /// What a status code means, as HTTP names it, such as "Not Found" for 404, for the codes
    /// apps meet; `nil` for the others.
    static func reason(_ status: Int) -> String? {
        reasons[status]
    }

    private static let reasons = [
        100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted",
        203: "Non-Authoritative Information", 204: "No Content", 205: "Reset Content", 206: "Partial Content",
        300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized",
        402: "Payment Required", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
        407: "Proxy Authentication Required", 408: "Request Timeout", 409: "Conflict", 410: "Gone",
        411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large", 414: "URI Too Long",
        415: "Unsupported Media Type", 416: "Range Not Satisfiable", 417: "Expectation Failed",
        421: "Misdirected Request", 422: "Unprocessable Content", 425: "Too Early", 426: "Upgrade Required",
        428: "Precondition Required", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
        451: "Unavailable For Legal Reasons", 500: "Internal Server Error", 501: "Not Implemented",
        502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
        511: "Network Authentication Required",
    ]
}
