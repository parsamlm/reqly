import Foundation
import Presentation
import ReqlyModel

/// An exchange's details, as the details pane shows them: the exchange itself, and what both
/// apps work out from it, such as its query decoded, its cookies, the steps of its timing and
/// the rules that changed it. Windows gets the same as its `details` reply.
public struct ExchangeDetails: Sendable, Equatable {
    /// A name and its value, such as one of a query's parameters.
    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// A cookie, from a `Cookie` header or a `Set-Cookie` header.
    public struct Cookie: Sendable, Equatable {
        public var name: String
        public var value: String
        /// When a Set-Cookie cookie expires, when its date reads as one.
        public var expires: Date?
        /// Its expiry as the server wrote it, when it doesn't read as a date.
        public var expiresText: String?
        /// Its other attributes in a few words, such as "Path /" and "Secure".
        public var attributes: [String]

        public init(
            name: String, value: String, expires: Date? = nil, expiresText: String? = nil, attributes: [String] = []
        ) {
            self.name = name
            self.value = value
            self.expires = expires
            self.expiresText = expiresText
            self.attributes = attributes
        }

        init(_ cookie: ResponseCookie) {
            let date = cookie.expiryDate
            self.init(
                name: cookie.name, value: cookie.value, expires: date, expiresText: date == nil ? cookie.expires : nil,
                attributes: cookie.attributes)
        }
    }

    public var exchange: Exchange
    /// The query's names and values, decoded, in order.
    public var query: [Field]
    /// Why the exchange failed, in plain words.
    public var failure: String?
    /// What the details say about decryption, and the action that fits.
    public var decryption: DecryptionSituation
    /// Whether the connection switched to WebSocket.
    public var isWebSocket: Bool
    /// How the call ended, for an exchange that was a gRPC call.
    public var grpc: GRPCStatus?
    /// The steps of the exchange, for the Timing tab's waterfall.
    public var phases: [TimingPhase]
    /// When Reqly started on a connection to the server, which a reused connection skips.
    public var connectStarted: Date?
    /// The rules that changed the exchange, one line per rule.
    public var appliedRules: [AppliedRule]
    /// The device the request came from and what kind it is, such as "iPhone 17 Pro · Simulator".
    public var deviceName: String?
    /// The part a breakpoint holds, while one holds the exchange.
    public var pausedPart: MessagePart?
    public var requestCookies: [Cookie]
    public var responseCookies: [Cookie]

    public init(_ exchange: Exchange) {
        self.exchange = exchange
        let parameters = exchange.request.query.map(QueryParameters.parse) ?? []
        query = parameters.map { Field(name: $0.name, value: $0.value) }
        if case .failed(let failure) = exchange.state {
            self.failure = failure.message
        }
        decryption = DecryptionSituation(exchange)
        isWebSocket = exchange.messageCount > 0 || exchange.response?.status == 101
        grpc = exchange.grpcStatus
        phases = exchange.timingPhases
        connectStarted = exchange.timing.connectStarted
        appliedRules = exchange.appliedRules.joinedByRule
        deviceName = exchange.device?.fullName
        if case .paused(let part) = exchange.state {
            pausedPart = part
        }
        requestCookies = exchange.request.headers.requestCookies.map { Cookie(name: $0.name, value: $0.value) }
        responseCookies = (exchange.response?.headers.responseCookies ?? []).map(Cookie.init)
    }
}
