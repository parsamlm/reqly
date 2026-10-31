import BodyKit
import Foundation
import Presentation
import ProxyEngine
import ReqlyModel

// What SessionHost's methods take and give where the core has no type of its own, and the events
// it sends. The Linux app uses them as they are; the Windows app gets each of them as JSON, made
// beside the messages.

/// A value to set, or to remove, in a call that changes only what it names.
public enum ValueChange<Value: Sendable>: Sendable {
    case set(Value)
    case remove
}

extension ValueChange: Equatable where Value: Equatable {}

/// Every exchange in a session at a glance, as the Mac's menu-bar panel shows them.
public struct TrafficSummary: Sendable, Equatable {
    public var total: Int
    /// What every exchange sent and received.
    public var bytes: Int64
    public var newest: ExchangeSummary?

    public init(total: Int, bytes: Int64, newest: ExchangeSummary? = nil) {
        self.total = total
        self.bytes = bytes
        self.newest = newest
    }

    init(_ all: ExchangeList) {
        total = all.count
        bytes = all.reduce(0) { $0 + $1.bytesSent + $1.bytesReceived }
        newest = all.last
    }
}

/// The sidebar's rows, as the list engine keeps them for the Mac's sidebar. Each row has a key,
/// which ``SessionHost/setScope(_:)`` takes to narrow the list to it, and its count.
public struct Sidebar: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var key: String
        public var name: String
        public var count: Int
        /// An app's program, for its icon.
        public var path: String?

        public init(key: String, name: String, count: Int, path: String? = nil) {
            self.key = key
            self.name = name
            self.count = count
            self.path = path
        }
    }

    public struct DeviceRow: Sendable, Equatable {
        public var key: String
        /// This computer, or the device, as filters name it.
        public var device: DeviceChoice
        /// `nil` for this computer.
        public var name: String?
        /// `nil` for this computer.
        public var kind: Device.Kind?
        public var count: Int
        public var apps: [Row]
        /// The hosts its traffic from no known app went to.
        public var otherHosts: [Row]

        public init(
            key: String, device: DeviceChoice, name: String? = nil, kind: Device.Kind? = nil, count: Int, apps: [Row],
            otherHosts: [Row]
        ) {
            self.key = key
            self.device = device
            self.name = name
            self.kind = kind
            self.count = count
            self.apps = apps
            self.otherHosts = otherHosts
        }
    }

    public var total: Int
    public var pinned: Int
    /// This computer's apps, by name.
    public var apps: [Row]
    /// Every host, in the order people expect: h2 before h10.
    public var hosts: [Row]
    /// This computer, then each device, by name. Empty while all traffic comes from this computer.
    public var devices: [DeviceRow]
    /// The methods the requests used, the common ones first, for the filters.
    public var methods: [String]
    /// Every app on any device, by name, for the filters.
    public var sources: [Source]

    public init(
        total: Int, pinned: Int, apps: [Row], hosts: [Row], devices: [DeviceRow], methods: [String], sources: [Source]
    ) {
        self.total = total
        self.pinned = pinned
        self.apps = apps
        self.hosts = hosts
        self.devices = devices
        self.methods = methods
        self.sources = sources
    }
}

/// How the rows changed, in order, as the list should change its own. Rows are counted from 0.
/// `inserted` names each new row's exchange, so the app needs no other call to keep its list of
/// rows; it asks for the rows it shows with ``SessionHost/rows(_:)``.
public enum RowStep: Sendable, Equatable {
    /// Rows taken out, at their places before.
    case removed([Int])
    /// Rows put in, each at its place after, with its exchange.
    case inserted([InsertedRow])
    /// Exchanges whose rows stay but show something new.
    case changed([ExchangeID])
    /// Every row, when so many changed that listing the changes would take longer.
    case reset([ExchangeID])

    public struct InsertedRow: Sendable, Equatable {
        public var row: Int
        public var id: ExchangeID

        public init(row: Int, id: ExchangeID) {
            self.row = row
            self.id = id
        }
    }
}

/// Something that happened in a session, handed to the app as it happens.
public enum Event: Sendable {
    /// The rows changed. `version` goes up by one each time.
    case rows(version: Int, total: Int, shown: Int, steps: [RowStep])
    /// Saving traffic failed, with a message to show; or it works again, with `nil`.
    case storageProblem(String?)
    /// The sidebar's rows, when apps, hosts or devices came or went.
    case sidebar(Sidebar)
    /// The sidebar's counts that changed, by row key, when no row came or went.
    case counts(total: Int, pinned: Int, counts: [String: Int])
    /// How far a HAR export got.
    case exportProgress(done: Int, total: Int)
    /// A breakpoint holds a request or a response, ready to edit, until
    /// ``SessionHost/resumePaused(_:as:)`` or ``SessionHost/stopPaused(_:)`` answers.
    case paused(id: ExchangeID, edit: PausedEdit)
    /// A held exchange went on or went away, as when its app gave up.
    case resumed(id: ExchangeID)
    /// A device on the network wants to send its traffic through Reqly, and waits for
    /// ``SessionHost/decideDevice(_:allow:name:)``. `waiting` counts it with the others that wait.
    case deviceWaiting(id: String, address: String, waiting: Int)
}

/// A body made ready to show, and how bodies like it are read as Protobuf.
public struct PresentedBody: Sendable {
    public var body: BodyPresentation
    /// The message type chosen for bodies like this one, if one was.
    public var chosenType: String?
    /// Whether the `.proto` files have message types to choose from.
    public var hasMessageTypes: Bool

    public init(body: BodyPresentation, chosenType: String? = nil, hasMessageTypes: Bool) {
        self.body = body
        self.chosenType = chosenType
        self.hasMessageTypes = hasMessageTypes
    }
}

/// The request and the response as text, the way HTTP/1.1 writes them, for the Raw tab.
public struct RawExchange: Sendable {
    public var request: RawMessage
    /// `nil` before the response arrives, and for an encrypted connection.
    public var response: RawMessage?
    /// Whether any header is a secret, such as a cookie, so the tab offers to show them.
    public var hasSecrets: Bool

    public init(request: RawMessage, response: RawMessage? = nil, hasSecrets: Bool) {
        self.request = request
        self.response = response
        self.hasSecrets = hasSecrets
    }
}

/// A request as you write it in the composer, before it's sent.
public struct RequestDraft: Sendable, Equatable {
    public struct Header: Sendable, Equatable {
        public var name: String
        public var value: String
        /// Whether to send it. Turning a header off keeps it for later.
        public var isOn: Bool

        public init(name: String, value: String, isOn: Bool = true) {
            self.name = name
            self.value = value
            self.isOn = isOn
        }
    }

    public var method: String
    /// As typed: without a scheme, it's sent with `https://`.
    public var url: String
    public var headers: [Header]
    /// Sent as it is.
    public var body: Data

    public init(method: String = "GET", url: String, headers: [Header] = [], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Reqly sets these itself when it sends the request, from the URL and the body, and leaves
    /// out the ones meant for a proxy.
    static let framingHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "proxy-connection", "proxy-authorization",
    ]

    /// A draft filled in from an exchange, for Edit and Resend.
    public init(_ exchange: Exchange) {
        method = exchange.request.method
        url = exchange.request.url?.absoluteString ?? ""
        headers = exchange.request.headers
            .filter { !Self.framingHeaders.contains($0.name.lowercased()) }
            .map { Header(name: $0.name, value: $0.value) }
        body = exchange.requestBody
    }

    /// The request to send, or what to fix, as the Mac's composer says it.
    public func request() throws(Problem) -> OutgoingRequest {
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
            return header.isOn && !name.isEmpty ? HeaderField(name: name, value: header.value) : nil
        }
        return OutgoingRequest(method: method, url: url, headers: Headers(fields), body: body)
    }
}

/// A body as Copy Response Body copies it.
public enum CopyableBody: Sendable, Equatable {
    case text(String)
    /// An image's bytes.
    case image(Data)
    /// Neither: its first megabyte, as hex.
    case hex(String)

    /// A body unpacked: as text when it's text, as an image when it's an image, and otherwise
    /// its first megabyte as hex, as the Mac app's Copy Response Body copies it.
    public init(_ data: Data, headers: Headers) {
        let body = headers["Content-Encoding"].flatMap { BodyDecoder.decode(data, contentEncoding: $0) } ?? data
        if let text = BodyText.decode(body, contentType: headers["Content-Type"]) {
            self = .text(text)
        } else if case .image = BodyKind.detect(body, contentType: headers["Content-Type"]) {
            self = .image(body)
        } else {
            self = .hex(body.prefix(1 << 20).map { String(format: "%02X", $0) }.joined(separator: " "))
        }
    }
}

/// What's wrong with something as you edit it, or a note on what it does once nothing is.
public struct CheckResult: Sendable, Equatable {
    public var problem: String?
    public var note: String?

    public init(problem: String? = nil, note: String? = nil) {
        self.problem = problem
        self.note = note
    }
}

extension WebSocketMessage {
    /// The start of the message, as its row shows it: its first line of text, a close's code
    /// and reason, or its first bytes as hex, as the Mac's message rows say it.
    public var preview: String {
        if kind == .close {
            let code =
                closeCode.map { code in
                    let meaning = Self.closeMeaning(code)
                    return meaning.isEmpty ? String(code) : "\(code) \(meaning)"
                } ?? "No code"
            let reason = text.flatMap { $0.isEmpty ? nil : $0 }
            return reason.map { "\(code) · \($0)" } ?? code
        }
        if let text = text ?? readableControlText {
            let line = text.prefix(300).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty && !text.isEmpty ? "⏎" : line
        }
        return data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// What a ping or a pong says, when it's text, as it often is.
    private var readableControlText: String? {
        guard kind == .ping || kind == .pong, let text = String(data: data, encoding: .utf8),
            !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return text
    }

    /// What a close code means, in a few words.
    public static func closeMeaning(_ code: Int) -> String {
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
