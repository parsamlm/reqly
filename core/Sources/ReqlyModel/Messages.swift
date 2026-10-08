import Foundation

/// A request as the app sent it, before any body.
public struct RequestHead: Hashable, Sendable, Codable {
    public var method: String
    /// `http` or `https`.
    public var scheme: String
    public var host: String
    public var port: Int
    /// The path and query as sent, such as `/v2/forecast?city=amsterdam`.
    /// For a tunnel (`CONNECT`) it is the authority, such as `api.weatherly.dev:443`.
    public var target: String
    /// Such as `HTTP/1.1`.
    public var version: String
    public var headers: Headers

    public init(
        method: String,
        scheme: String,
        host: String,
        port: Int,
        target: String,
        version: String = "HTTP/1.1",
        headers: Headers = Headers()
    ) {
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.target = target
        self.version = version
        self.headers = headers
    }

    /// The target without its query.
    public var path: String {
        guard let mark = target.firstIndex(of: "?") else { return target }
        return String(target[..<mark])
    }

    /// The query without its leading `?`, or `nil` when there is none.
    public var query: String? {
        guard let mark = target.firstIndex(of: "?") else { return nil }
        return String(target[target.index(after: mark)...])
    }

    /// The host, bracketed if it's an IPv6 address, with the port unless it's the scheme's default.
    public var authority: String {
        let name = host.contains(":") ? "[\(host)]" : host
        let isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return isDefaultPort ? name : "\(name):\(port)"
    }

    /// The full URL. A tunnel has no path, so its URL is just the scheme and authority.
    public var url: URL? {
        let path = method == "CONNECT" ? "" : target
        return URL(string: "\(scheme)://\(authority)\(path)")
    }
}

/// A response's status line and headers, before any body.
public struct ResponseHead: Hashable, Sendable, Codable {
    public var status: Int
    public var reason: String
    public var version: String
    public var headers: Headers

    public init(status: Int, reason: String, version: String = "HTTP/1.1", headers: Headers = Headers()) {
        self.status = status
        self.reason = reason
        self.version = version
        self.headers = headers
    }

    public var statusClass: StatusClass? { StatusClass(status: status) }
}

/// The five kinds of HTTP status. The interface colors status dots by class, as the
/// design guidelines describe.
public enum StatusClass: Sendable, Hashable, CaseIterable {
    case informational, success, redirection, clientError, serverError

    public init?(status: Int) {
        switch status {
        case 100..<200: self = .informational
        case 200..<300: self = .success
        case 300..<400: self = .redirection
        case 400..<500: self = .clientError
        case 500..<600: self = .serverError
        default: return nil
        }
    }
}
