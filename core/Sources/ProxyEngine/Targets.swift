import Foundation
import NIOHTTP1
import ReqlyModel

/// A host and port to connect to.
struct Authority: Hashable, Sendable {
    var host: String
    var port: Int

    /// Parses `host`, `host:port` or `[ipv6]:port`, ignoring any `user@` part.
    init?(_ text: Substring, defaultPort: Int) {
        var text = text
        if let at = text.lastIndex(of: "@") {
            text = text[text.index(after: at)...]
        }
        let host: Substring
        let port: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            if rest.isEmpty {
                port = nil
            } else if rest.hasPrefix(":") {
                port = rest.dropFirst()
            } else {
                return nil
            }
        } else if let colon = text.lastIndex(of: ":") {
            host = text[..<colon]
            port = text[text.index(after: colon)...]
        } else {
            host = text
            port = nil
        }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
        if let port {
            guard let number = Int(port), (1...65535).contains(number) else { return nil }
            self.port = number
        } else {
            self.port = defaultPort
        }
        self.host = host.lowercased()
    }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host)
    }

    /// TLS needs to know whether to ask the server for a name or an address.
    var isIPAddress: Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

/// The server a request is for, and the path and query to send it.
struct ProxyTarget: Sendable {
    var authority: Authority
    /// The path and query to send to the server, such as `/a?b=c`.
    var originForm: String

    init(authority: Authority, originForm: String) {
        self.authority = authority
        self.originForm = originForm
    }

    /// The path and query of a request target, whether the app sent the path, as usual, or a
    /// full URL.
    static func originForm(of uri: String) -> String {
        guard !uri.hasPrefix("/"), uri != "*", let separator = uri.range(of: "://") else { return uri }
        let rest = uri[separator.upperBound...]
        guard let pathStart = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) else { return "/" }
        let origin = rest[pathStart...]
        return origin.hasPrefix("?") ? "/" + origin : String(origin)
    }

    /// Parses an absolute-form request target such as `http://example.com:8080/a?b=c`.
    /// Returns `nil` for anything else, including `https://` targets, which apps send through a tunnel.
    init?(absoluteForm uri: String) {
        guard let separator = uri.range(of: "://"),
            uri[..<separator.lowerBound].lowercased() == "http"
        else { return nil }
        let rest = uri[separator.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        guard let authority = Authority(rest[..<authorityEnd], defaultPort: 80) else { return nil }
        var origin = rest[authorityEnd...]
        if let hash = origin.firstIndex(of: "#") {
            origin = origin[..<hash]
        }
        self.authority = authority
        self.originForm = origin.isEmpty ? "/" : origin.hasPrefix("?") ? "/" + origin : String(origin)
    }
}

extension Headers {
    init(_ headers: HTTPHeaders) {
        self.init(headers.map { HeaderField(name: $0.name, value: $0.value) })
    }
}

extension RequestHead {
    init(_ head: HTTPRequestHead, scheme: String, authority: Authority, target: String) {
        self.init(
            method: head.method.rawValue,
            scheme: scheme,
            host: authority.host,
            port: authority.port,
            target: target,
            version: head.version.major == 2 ? "HTTP/2" : head.version.description,
            headers: Headers(head.headers)
        )
    }
}

extension ResponseHead {
    init(_ head: HTTPResponseHead) {
        self.init(
            status: Int(head.status.code),
            reason: head.status.reasonPhrase,
            version: head.version.description,
            headers: Headers(head.headers)
        )
    }
}
