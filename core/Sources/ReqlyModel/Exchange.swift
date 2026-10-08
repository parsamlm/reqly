import Foundation

/// Identifies one request and its response within a capture session.
public struct ExchangeID: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifies one connection from an app to Reqly. A connection can carry many exchanges.
public struct ConnectionID: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ExchangeKind: Sendable, Hashable, Codable {
    /// A request and response that Reqly can read.
    case http
    /// An encrypted connection that passes through untouched, for a host Reqly doesn't decrypt.
    case tunnel
}

public enum ExchangeState: Sendable, Hashable, Codable {
    /// The request is still arriving from the app.
    case sending
    /// The request is with the server; no response yet.
    case waiting
    /// The response is arriving.
    case receiving
    /// A tunnel is open and relaying encrypted bytes.
    case open
    /// Held at a breakpoint until you continue it or cancel it.
    case paused(MessagePart)
    case completed
    case failed(ExchangeFailure)

    public var isFinished: Bool {
        switch self {
        case .completed, .failed: true
        case .sending, .waiting, .receiving, .open, .paused: false
        }
    }
}

/// Why an exchange didn't finish.
public enum ExchangeFailure: Sendable, Hashable, Codable {
    /// Reqly couldn't reach the server, for example because the name didn't resolve.
    case cannotConnect(String)
    /// The server closed the connection before the response finished.
    case serverClosed
    /// The app closed the connection before the exchange finished.
    case appClosed
    /// The app sent something that isn't valid HTTP.
    case invalidRequest(String)
    /// The request was addressed to Reqly's own port, which would loop forever.
    case loopDetected
    /// Capturing stopped while the exchange was in progress.
    case captureStopped
    /// The app refused Reqly's certificate for a decrypted host. Its Mac or device may not
    /// trust Reqly's current certificate, or the app may pin its own.
    case certificateRejected
    /// The server's certificate didn't pass the Mac's checks, so Reqly didn't send the request.
    case serverCertificateInvalid(String)
    /// A secure connection couldn't be set up. On a tunnel, it's the app's handshake with Reqly
    /// for a decrypted host that failed.
    case secureConnectionFailed(String)
    /// The server stopped answering a request Reqly sent itself.
    case timedOut
    /// A Block rule closed the connection, as a network failure would.
    case blocked(rule: String)
    /// You cancelled the request or the response while a breakpoint held it. Sessions saved
    /// before Reqly told the two apart have no part, and read as the request.
    case cancelledAtBreakpoint(part: MessagePart?)
    /// A failure read from a file, such as a HAR file, in the words of the tool that recorded it.
    case recorded(String)
    /// The server asked for a client certificate, and Reqly has none for its host.
    case clientCertificateRequired
    /// The server didn't accept the client certificate Reqly presented.
    case clientCertificateRejected

    /// A short explanation for the interface, in the voice of the design guidelines.
    public var message: String {
        switch self {
        case .cannotConnect(let reason): "Couldn't connect to the server: \(reason)"
        case .serverClosed: "The server closed the connection before the response finished."
        case .appClosed: "The app closed the connection before the response finished."
        case .invalidRequest(let reason): "The app sent a request Reqly couldn't read: \(reason)"
        case .loopDetected: "The request was sent to Reqly itself, so Reqly stopped it."
        case .captureStopped: "Capturing stopped before the response finished."
        case .certificateRejected:
            "The app didn't accept Reqly's certificate. Either the Mac or device it runs on doesn't trust Reqly's current certificate, for example after you made a new one, or the app accepts only its own. Install the certificate again, or stop decrypting this host."
        case .serverCertificateInvalid(let reason):
            "The server's certificate isn't valid, so Reqly didn't send the request. \(reason)"
        case .secureConnectionFailed(let reason): "Reqly couldn't set up a secure connection. \(reason)"
        case .timedOut: "The server stopped answering, so Reqly gave up on the response."
        case .blocked(let rule): "The rule “\(rule)” blocked this request, so Reqly closed the connection."
        case .cancelledAtBreakpoint(let part): "You cancelled this \((part ?? .request).rawValue) at a breakpoint."
        case .recorded(let reason): reason
        case .clientCertificateRequired:
            "The server asked for a client certificate, and Reqly has none for this host. Add one in Settings, under Client Certificates."
        case .clientCertificateRejected:
            "The server didn't accept the client certificate Reqly presented for this host."
        }
    }

    /// On a tunnel, whether the app's handshake with Reqly failed on a host Reqly decrypts.
    public var isDecryptionFailure: Bool {
        switch self {
        case .certificateRejected, .secureConnectionFailed: true
        default: false
        }
    }
}

/// When each step of an exchange happened.
public struct ExchangeTiming: Hashable, Sendable, Codable {
    /// Reqly read the head of the request.
    public var started: Date
    /// The app finished sending the request.
    public var requestEnded: Date?
    /// Reqly started opening a connection to the server. Missing when the request reused one.
    public var connectStarted: Date?
    /// The server's name resolved to its addresses. Missing when the host is an IP address.
    public var resolved: Date?
    public var connected: Date?
    /// The TLS handshake with the server finished.
    public var secured: Date?
    /// Reqly finished sending the request to the server.
    public var requestSent: Date?
    public var responseStarted: Date?
    public var ended: Date?

    public init(started: Date) {
        self.started = started
    }

    /// From the first byte of the request to the last byte of the response.
    public var duration: TimeInterval? { ended.map { $0.timeIntervalSince(started) } }
}

/// One request and its response, with everything Reqly knows about them.
public struct Exchange: Identifiable, Hashable, Sendable {
    public var id: ExchangeID
    public var connectionID: ConnectionID
    public var kind: ExchangeKind
    public var request: RequestHead
    public var requestBody: Data
    public var response: ResponseHead?
    public var responseBody: Data
    /// Headers the server sent after the response body, as gRPC servers do with the call's status.
    public var responseTrailers: Headers?
    public var timing: ExchangeTiming
    public var state: ExchangeState
    /// Bytes from the app to the server. For an HTTP exchange, the request body.
    public var bytesSent: Int64
    /// Bytes from the server to the app. For an HTTP exchange, the response body.
    public var bytesReceived: Int64
    /// The app or tool that sent the request, once Reqly has found out.
    public var source: Source?
    /// The phone, simulator or emulator the request came from. Requests from the Mac's own
    /// apps have none.
    public var device: Device?
    /// The server's IP address and port, such as `203.0.113.24:443`, once Reqly is connected.
    public var remoteAddress: String?
    /// The TLS version of the connection to the server, such as `1.3`.
    public var tlsVersion: String?
    /// Whether the request went over a connection to the server that an earlier request opened.
    public var reusedConnection: Bool
    /// The protocol Reqly spoke with the server, such as `HTTP/2` or `HTTP/1.1`.
    public var serverProtocol: String?
    /// The upstream proxy the exchange went through, such as `proxy.example.com:8080`.
    public var upstreamProxy: String?
    /// The reverse proxy the app sent the request to, such as `localhost:8080`.
    public var reverseProxy: String?
    /// The client certificate Reqly presented to the server, by name. Reqly presents the one it
    /// has for the host only when the server asks for a certificate, so this is `nil` when Reqly
    /// has none for the host, when the server didn't ask for one, and when the connection failed
    /// before the server asked, for example because Reqly didn't trust the server's certificate.
    public var clientCertificate: String?
    /// Whether Reqly sent the request itself, from the composer or Resend, rather than passing on
    /// an app's.
    public var sentByReqly: Bool
    /// What scripts printed while they ran on the exchange, in order.
    public var scriptOutput: [ScriptOutput]
    /// The WebSocket messages the connection carried after the exchange switched to WebSocket.
    /// The messages themselves are in the store.
    public var messageCount: Int
    public var annotation: Annotation
    /// The rules that changed the exchange, in the order they acted.
    public var appliedRules: [AppliedRule]

    public init(
        id: ExchangeID,
        connectionID: ConnectionID,
        kind: ExchangeKind,
        request: RequestHead,
        started: Date
    ) {
        self.id = id
        self.connectionID = connectionID
        self.kind = kind
        self.request = request
        self.requestBody = Data()
        self.response = nil
        self.responseBody = Data()
        self.responseTrailers = nil
        self.timing = ExchangeTiming(started: started)
        self.state = .sending
        self.bytesSent = 0
        self.bytesReceived = 0
        self.source = nil
        self.device = nil
        self.remoteAddress = nil
        self.tlsVersion = nil
        self.reusedConnection = false
        self.serverProtocol = nil
        self.upstreamProxy = nil
        self.reverseProxy = nil
        self.clientCertificate = nil
        self.sentByReqly = false
        self.scriptOutput = []
        self.messageCount = 0
        self.annotation = Annotation()
        self.appliedRules = []
    }

    /// How the gRPC call ended, for an exchange that was one.
    public var grpcStatus: GRPCStatus? {
        GRPCStatus(response: response, trailers: responseTrailers)
    }

    /// Whether Reqly decrypted the app's own HTTPS to read the exchange. A request Reqly sent
    /// itself, from the composer or Resend, or one an app sent to a reverse proxy, had no TLS
    /// from the app to decrypt: Reqly spoke TLS with the server itself.
    public var isDecrypted: Bool {
        kind == .http && request.scheme == "https" && reverseProxy == nil && !sentByReqly
    }

    public var summary: ExchangeSummary {
        ExchangeSummary(
            id: id,
            kind: kind,
            method: request.method,
            scheme: request.scheme,
            host: request.host,
            port: request.port,
            target: request.target,
            status: response?.status,
            state: state,
            started: timing.started,
            duration: timing.duration,
            bytesSent: bytesSent,
            bytesReceived: bytesReceived,
            contentType: response?.headers["Content-Type"],
            contentGroup: ContentGroup(contentType: response?.headers["Content-Type"]),
            source: source,
            device: device,
            messageCount: messageCount,
            grpcStatus: grpcStatus?.code,
            annotation: annotation
        )
    }
}

/// The few fields the request list shows, small enough to keep in memory for every row.
public struct ExchangeSummary: Identifiable, Hashable, Sendable {
    public var id: ExchangeID
    public var kind: ExchangeKind
    public var method: String
    public var scheme: String
    public var host: String
    public var port: Int
    public var target: String
    public var status: Int?
    public var state: ExchangeState
    public var started: Date
    public var duration: TimeInterval?
    public var bytesSent: Int64
    public var bytesReceived: Int64
    public var contentType: String?
    /// The kind of body `contentType` names. It's worked out once, because the list filters
    /// every row each time traffic arrives.
    public var contentGroup: ContentGroup
    public var source: Source?
    public var device: Device?
    /// WebSocket messages, for an exchange that switched to WebSocket.
    public var messageCount: Int
    /// The status code of a gRPC call, which can fail while its HTTP status is 200.
    public var grpcStatus: Int?
    public var annotation: Annotation

    /// The HTTP status's class, or for a gRPC call that got an HTTP response, the class of the
    /// call's own status.
    public var statusClass: StatusClass? {
        if let grpcStatus, let status, (200..<300).contains(status) {
            return GRPCStatus(code: grpcStatus).statusClass
        }
        return status.flatMap(StatusClass.init(status:))
    }

    /// Whether the connection switched to WebSocket.
    public var isWebSocket: Bool {
        messageCount > 0 || status == 101
    }

    /// The target without its query.
    public var path: String {
        guard let mark = target.firstIndex(of: "?") else { return target }
        return String(target[..<mark])
    }

    /// The full URL. A tunnel has no path, so its URL is just the scheme and authority.
    public var url: URL? {
        RequestHead(method: method, scheme: scheme, host: host, port: port, target: target).url
    }
}
