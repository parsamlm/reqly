import Foundation
import ReqlyModel

/// What the engine reports while it relays traffic. Events for one exchange arrive in order.
public enum ProxyEvent: Sendable, Equatable {
    case connectionOpened(ConnectionID, client: ClientAddress, at: Date)
    case connectionClosed(ConnectionID, at: Date)

    case requestHead(ExchangeID, ConnectionID, RequestHead, at: Date)
    case requestBody(ExchangeID, Data)
    case requestEnd(ExchangeID, at: Date)
    /// Reqly started opening a connection to the server. Missing when an open connection is reused.
    case serverConnecting(ExchangeID, at: Date)
    /// The server's name resolved to its addresses. Missing when the host is an IP address.
    case serverResolved(ExchangeID, at: Date)
    /// The connection to the server is open. `address` is the server's IP address and port.
    case serverConnected(ExchangeID, address: String?, at: Date)
    /// The TLS handshake with the server finished. `tlsVersion` is a number such as `1.3`.
    case serverSecured(ExchangeID, tlsVersion: String?, at: Date)
    /// The request goes over a connection that an earlier request opened.
    case serverReused(ExchangeID, address: String?, tlsVersion: String?)
    /// Reqly finished sending the request to the server.
    case requestSent(ExchangeID, at: Date)
    case responseHead(ExchangeID, ResponseHead, at: Date)
    case responseBody(ExchangeID, Data)
    /// Headers that came after the response body, such as a gRPC call's status. Only sent
    /// when there are some, just before the response ends.
    case responseTrailers(ExchangeID, Headers)
    case responseEnd(ExchangeID, at: Date)

    /// The protocol the exchange goes to the server over, such as `HTTP/2` or `HTTP/1.1`.
    case serverProtocol(ExchangeID, String)
    /// The exchange goes to the server through the upstream proxy at this address.
    case upstreamProxy(ExchangeID, String)
    /// The app sent the request to a reverse proxy at this address, such as `localhost:8080`.
    case reverseProxy(ExchangeID, String)
    /// The server asked for a client certificate, and Reqly presented the one with this name.
    case clientCertificate(ExchangeID, String)
    /// Reqly sent the request itself, such as one you composed, rather than passing on an
    /// app's. It comes right after the request's head.
    case sentByReqly(ExchangeID)
    /// A WebSocket message, once the exchange has switched to WebSocket.
    case webSocketMessage(ExchangeID, WebSocketMessage)
    /// A rule acted on the exchange.
    case ruleApplied(ExchangeID, AppliedRule)
    /// A script printed this while it ran on the exchange.
    case scriptOutput(ExchangeID, ScriptOutput)
    /// A breakpoint holds the exchange until ``ProxyServer/decide(_:_:)`` is called for it.
    /// `breakpoint` is the name of its rule.
    case paused(ExchangeID, PausedMessage, breakpoint: String)
    /// The exchange goes on after a breakpoint.
    case resumed(ExchangeID, MessagePart)

    /// An encrypted connection that Reqly relays without reading it.
    case tunnelOpened(ExchangeID, at: Date)
    case tunnelClosed(ExchangeID, bytesSent: Int64, bytesReceived: Int64, at: Date)

    case failed(ExchangeID, ExchangeFailure, at: Date)
}

extension ProxyEvent {
    /// When the event happened, for the events that say.
    public var time: Date? {
        switch self {
        case .connectionOpened(_, _, let time), .connectionClosed(_, let time), .requestHead(_, _, _, let time),
            .requestEnd(_, let time), .serverConnecting(_, let time), .serverResolved(_, let time),
            .serverConnected(_, _, let time), .serverSecured(_, _, let time), .requestSent(_, let time),
            .responseHead(_, _, let time), .responseEnd(_, let time), .tunnelOpened(_, let time),
            .tunnelClosed(_, _, _, let time), .failed(_, _, let time):
            time
        case .webSocketMessage(_, let message):
            message.time
        case .requestBody, .responseBody, .responseTrailers, .serverReused, .serverProtocol, .upstreamProxy,
            .reverseProxy, .clientCertificate, .sentByReqly, .scriptOutput, .ruleApplied, .paused, .resumed:
            nil
        }
    }
}

/// Where an app's connection came from. Reqly uses the port to find the app that opened it.
public struct ClientAddress: Sendable, Hashable {
    public var ip: String
    public var port: Int
    /// The port the app connected to, when it's a reverse proxy's rather than the proxy's.
    public var localPort: Int?

    public init(ip: String, port: Int, localPort: Int? = nil) {
        self.ip = ip
        self.port = port
        self.localPort = localPort
    }

    /// Whether the connection comes from this Mac, rather than from a device on the network.
    public var isLoopback: Bool {
        ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
    }
}
