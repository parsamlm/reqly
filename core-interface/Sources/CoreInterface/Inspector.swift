import BodyKit
import Foundation
import Presentation
import ProxyEngine
import ReqlyModel

// What the details pane shows besides the headers: gRPC, timing, rules, devices, cookies, raw
// text, trees and WebSocket messages.

/// A gRPC call's status.
public struct WireGRPC: Codable, Sendable, Equatable {
    public var code: Int
    /// Such as `NOT_FOUND`.
    public var name: String
    /// Such as "Not found".
    public var title: String
    public var message: String?

    init(_ status: GRPCStatus) {
        code = status.code
        name = status.name
        title = status.title
        message = status.message
    }
}

/// A step of the exchange: `queued`, `dnsLookup`, `connecting`, `tlsHandshake`, `requestSent`,
/// `waiting`, `downloading` or `open`.
public struct WirePhase: Codable, Sendable, Equatable {
    public var step: String
    public var start: Double
    public var end: Double

    init(_ phase: TimingPhase) {
        step =
            switch phase.step {
            case .queued: "queued"
            case .dnsLookup: "dnsLookup"
            case .connecting: "connecting"
            case .tlsHandshake: "tlsHandshake"
            case .requestSent: "requestSent"
            case .waiting: "waiting"
            case .downloading: "downloading"
            case .open: "open"
            }
        start = phase.start.timeIntervalSince1970
        end = phase.end.timeIntervalSince1970
    }
}

/// A rule that changed the exchange: its kind, its name and what it did.
public struct WireRule: Codable, Sendable, Equatable {
    /// `breakpoint`, `mapLocal`, `mapRemote`, `rewrite`, `block`, `script` or `slowNetwork`.
    public var kind: String
    public var name: String
    /// Such as "Sent to https://staging.weatherly.dev/v2/forecast".
    public var detail: String

    /// One line for each rule. A rule that acted more than once, such as on the request and then
    /// on the response, gets everything it did on its line, as on the Mac.
    static func joined(_ rules: [AppliedRule]) -> [WireRule] {
        var joined: [WireRule] = []
        for rule in rules {
            if let index = joined.firstIndex(where: { $0.name == rule.name && $0.kind == rule.kind.rawValue }) {
                joined[index].detail += " " + rule.detail
            } else {
                joined.append(WireRule(kind: rule.kind.rawValue, name: rule.name, detail: rule.detail))
            }
        }
        return joined
    }
}

/// What a script printed while it ran on the request or on the response.
public struct WireScriptOutput: Codable, Sendable, Equatable {
    public var rule: String
    /// `request` or `response`.
    public var part: String
    public var lines: [String]
}

/// The phone, simulator or emulator a request came from.
public struct WireDeviceInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// `network`, `simulator` or `emulator`.
    public var kind: String
    public var address: String?
    /// The device and what kind it is, such as "iPhone 17 Pro · Simulator".
    public var fullName: String

    init(_ device: Device) {
        id = device.id
        name = device.name
        kind = device.kind.rawValue
        address = device.address
        fullName =
            switch device.kind {
            case .network:
                device.address.map { $0 == device.name ? device.name : "\(device.name) · \($0)" } ?? device.name
            case .simulator: "\(device.name) · Simulator"
            case .emulator: "\(device.name) · Android emulator"
            }
    }
}

/// A cookie, from a `Cookie` header or a `Set-Cookie` header.
public struct WireCookie: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    /// When a Set-Cookie cookie expires, in seconds since 1970, when its date reads as one.
    public var expires: Double?
    /// Its expiry as the server wrote it, when it doesn't read as a date.
    public var expiresText: String?
    /// Its other attributes in a few words, such as "Path /" and "Secure".
    public var attributes: [String]

    init(name: String, value: String) {
        self.name = name
        self.value = value
        attributes = []
    }

    init(_ cookie: ResponseCookie) {
        name = cookie.name
        value = cookie.value
        expires = cookie.expiryDate?.timeIntervalSince1970
        expiresText = cookie.expiryDate == nil ? cookie.expires : nil
        attributes = cookie.attributes
    }
}

/// The request and the response as text, the way HTTP/1.1 writes them, for the Raw tab.
public struct WireRaw: Encodable, Sendable, Equatable {
    public var request: WireCode
    /// `nil` before the response arrives, and for an encrypted connection.
    public var response: WireCode?
    /// Whether any header is a secret, such as a cookie, so the tab offers to show them.
    public var hasSecrets: Bool
}

/// Text with its syntax marked: each token is `[location, length, kind]`, in UTF-16 code units,
/// with kinds `key`, `string`, `number`, `literal`, `keyword`, `tag`, `attribute`,
/// `attributeValue` and `comment`. Anything without a token is punctuation or plain text.
public struct WireCode: Encodable, Sendable, Equatable {
    public var text: String
    public var tokens: [[WireTokenPart]]
    /// Whether it's code, kept in whole lines, rather than text that wraps.
    public var isCode: Bool

    init(text: String, tokens: [SyntaxToken], isCode: Bool) {
        self.text = text
        self.tokens = Self.parts(tokens)
        self.isCode = isCode
    }

    /// Tokens as the app reads them: `[location, length, kind]`, in UTF-16 code units.
    static func parts(_ tokens: [SyntaxToken]) -> [[WireTokenPart]] {
        tokens.map { [.number($0.location), .number($0.length), .kind(name($0.kind))] }
    }

    static func name(_ kind: SyntaxKind) -> String {
        switch kind {
        case .key: "key"
        case .string: "string"
        case .number: "number"
        case .literal: "literal"
        case .keyword: "keyword"
        case .tag: "tag"
        case .attribute: "attribute"
        case .attributeValue: "attributeValue"
        case .comment: "comment"
        }
    }
}

/// A token's place, length or kind, in a compact array.
public enum WireTokenPart: Encodable, Sendable, Equatable {
    case number(Int)
    case kind(String)

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .kind(let name): try container.encode(name)
        }
    }
}

/// A body's tree, for the Tree view: every node, in order, each naming its parent and children.
public struct WireTree: Encodable, Sendable, Equatable {
    public struct Node: Encodable, Sendable, Equatable {
        public var label: String
        /// The value, or for a container a summary such as "3 keys".
        public var summary: String
        /// Such as "object", "string" or "repeated".
        public var type: String
        /// `string`, `number`, `literal`, `bytes` or `container`, for the value's color.
        public var style: String
        public var parent: Int?
        public var children: [Int]
        public var depth: Int
    }

    public var nodes: [Node]

    init(_ outline: any ValueOutline) {
        nodes = (0..<outline.count).map { id in
            let node = outline.node(id)
            return Node(
                label: node.label, summary: node.summary, type: node.typeName, style: Self.name(node.style),
                parent: node.parent, children: node.children, depth: node.depth)
        }
    }

    static func name(_ style: OutlineStyle) -> String {
        switch style {
        case .string: "string"
        case .number: "number"
        case .literal: "literal"
        case .bytes: "bytes"
        case .container: "container"
        }
    }
}

/// A form field, or a part of a multipart body.
public struct WireFormField: Encodable, Sendable, Equatable {
    public var name: String
    /// The value, or for a part that isn't text, what it is: a file's name, type and size, as
    /// the Mac's form view says.
    public var value: String
    /// Whether it's a file, whose description shows in the regular font rather than as code.
    public var isFile: Bool

    init(name: String, value: String, isFile: Bool) {
        self.name = name
        self.value = value
        self.isFile = isFile
    }

    init(_ part: MultipartPart) {
        name = part.name ?? "Unnamed part"
        let size = ByteCount.text(Int64(part.body.count))
        if let filename = part.filename {
            value = [filename, part.contentType, size].compactMap { $0 }.joined(separator: " · ")
            isFile = true
        } else if let text = BodyText.decode(part.body, contentType: part.contentType) {
            value = text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text
            isFile = false
        } else {
            value = [part.contentType ?? "Binary data", size].joined(separator: " · ")
            isFile = true
        }
    }
}

/// A WebSocket message, as the Messages tab lists it.
public struct WireMessage: Encodable, Sendable, Equatable {
    public var number: Int
    /// `sent` or `received`.
    public var direction: String
    /// `text`, `binary`, `close`, `ping` or `pong`.
    public var kind: String
    public var time: Double
    /// Its length on the wire, and how much of it Reqly kept.
    public var size: Int
    public var keptSize: Int
    /// A close message's code.
    public var closeCode: Int?
    /// A text message's words, or a close message's reason, which the filter looks in.
    public var text: String?
    /// The start of the message, as its row shows it: its first line of text, a close's code
    /// and reason, or its first bytes as hex.
    public var preview: String

    init(number: Int, _ message: WebSocketMessage) {
        self.number = number
        direction = message.direction.rawValue
        kind = message.kind.rawValue
        time = message.time.timeIntervalSince1970
        size = message.size
        keptSize = message.data.count
        closeCode = message.closeCode
        text = message.text
        preview = Self.preview(message)
    }

    /// As the Mac's message rows say it.
    static func preview(_ message: WebSocketMessage) -> String {
        if message.kind == .close {
            let code =
                message.closeCode.map { code in
                    let meaning = closeMeaning(code)
                    return meaning.isEmpty ? String(code) : "\(code) \(meaning)"
                } ?? "No code"
            let reason = message.text.flatMap { $0.isEmpty ? nil : $0 }
            return reason.map { "\(code) · \($0)" } ?? code
        }
        if let text = message.text ?? readableControlText(message) {
            let line = text.prefix(300).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty && !text.isEmpty ? "⏎" : line
        }
        return message.data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// What a ping or a pong says, when it's text, as it often is.
    private static func readableControlText(_ message: WebSocketMessage) -> String? {
        guard message.kind == .ping || message.kind == .pong,
            let text = String(data: message.data, encoding: .utf8),
            !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return text
    }

    /// What a close code means, in a few words.
    static func closeMeaning(_ code: Int) -> String {
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

/// A request as you write it in the composer, before it's sent.
public struct WireOutgoing: Codable, Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public var name: String
        public var value: String
        /// Whether to send it. Turning a header off keeps it for later.
        public var isOn: Bool?
    }

    public var method: String
    public var url: String
    public var headers: [Header]
    public var body: String?
    /// A body that isn't text, in base64. It's sent as it was.
    public var binaryBody: String?

    /// Reqly sets these itself when it sends the request, from the URL and the body, and leaves
    /// out the ones meant for a proxy.
    static let framingHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "proxy-connection", "proxy-authorization",
    ]

    /// A draft filled in from an exchange, for Edit and Resend.
    init(_ exchange: Exchange) {
        method = exchange.request.method
        url = exchange.request.url?.absoluteString ?? ""
        headers = exchange.request.headers
            .filter { !Self.framingHeaders.contains($0.name.lowercased()) }
            .map { Header(name: $0.name, value: $0.value, isOn: true) }
        if let text = String(data: exchange.requestBody, encoding: .utf8) {
            body = text
        } else {
            binaryBody = exchange.requestBody.base64EncodedString()
        }
    }

    /// The request to send, or what to fix, as the Mac's composer says it.
    func request() throws(Problem) -> OutgoingRequest {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host(), !host.isEmpty
        else {
            throw Problem(.badRequest, "Enter a URL that starts with http:// or https://.")
        }
        let fields = headers.compactMap { header -> HeaderField? in
            let name = header.name.trimmingCharacters(in: .whitespaces)
            return header.isOn != false && !name.isEmpty ? HeaderField(name: name, value: header.value) : nil
        }
        let data = binaryBody.flatMap { Data(base64Encoded: $0) } ?? Data((body ?? "").utf8)
        return OutgoingRequest(method: method, url: url, headers: Headers(fields), body: data)
    }
}

/// A request or a response held at a breakpoint, ready to edit.
public struct WirePaused: Encodable, Sendable, Equatable {
    public var id: UInt64
    /// `request` or `response`.
    public var part: String
    /// The breakpoint's rule, by name.
    public var breakpoint: String
    public var method: String
    public var url: String
    public var status: String
    public var reason: String
    public var headers: [WireHeader]
    public var body: String
    /// A body that isn't text, by its size. It goes on as it was.
    public var binaryBodySize: Int?

    init(id: UInt64, _ edit: PausedEdit) {
        self.id = id
        part = edit.part.rawValue
        breakpoint = edit.breakpoint
        method = edit.method
        url = edit.url
        status = edit.status
        reason = edit.reason
        headers = edit.headers.map { WireHeader(name: $0.name, value: $0.value) }
        body = edit.body
        binaryBodySize = edit.binaryBody?.count
    }
}

/// What you changed in a held request or response: everything the editor shows.
public struct WirePausedEdit: Codable, Sendable, Equatable {
    public var method: String?
    public var url: String?
    public var status: String?
    public var reason: String?
    public var headers: [WireHeader]?
    public var body: String?

    func apply(to edit: inout PausedEdit) {
        edit.method = method ?? edit.method
        edit.url = url ?? edit.url
        edit.status = status ?? edit.status
        edit.reason = reason ?? edit.reason
        if let headers {
            edit.headers = headers.map { PausedEdit.Header(name: $0.name, value: $0.value) }
        }
        edit.body = body ?? edit.body
    }
}

/// What a script would do to an exchange, for the script editor's Try.
public struct WireScriptTrial: Encodable, Sendable, Equatable {
    /// `request` or `response`.
    public var part: String
    /// Such as "Changed 1 header." or "Failed: TypeError: …, on line 3."
    public var detail: String
    public var logs: [String]
    public var failed: Bool
}
