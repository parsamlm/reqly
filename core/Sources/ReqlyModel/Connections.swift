import Foundation

/// Another HTTP proxy that Reqly sends its own traffic through, for networks that reach the
/// internet only through one, as many offices do.
///
/// HTTPS, WebSocket and encrypted connections go through a tunnel the proxy opens with
/// `CONNECT`. Plain HTTP requests go to the proxy as they are, with the full URL.
public struct UpstreamProxy: Hashable, Sendable, Codable {
    /// The proxy's host name or address, such as `proxy.example.com`.
    public var host: String
    public var port: Int
    /// The user name to sign in with, if the proxy asks for one.
    public var username: String?
    /// The password to sign in with. It isn't saved with the rest; the app keeps it in the Keychain.
    public var password: String?
    /// Hosts Reqly reaches directly, such as `intranet.example.com` or `*.corp.example.com`.
    public var bypass: [HostPattern]
    /// Reaches addresses on the local network, such as `192.168.1.20` or `printer.local`, directly.
    public var bypassesLocalAddresses: Bool

    public init(
        host: String, port: Int, username: String? = nil, password: String? = nil, bypass: [HostPattern] = [],
        bypassesLocalAddresses: Bool = true
    ) {
        self.host = host.trimmingCharacters(in: .whitespaces).lowercased()
        self.port = port
        self.username = username
        self.password = password
        self.bypass = bypass
        self.bypassesLocalAddresses = bypassesLocalAddresses
    }

    enum CodingKeys: String, CodingKey {
        case host, port, username, bypass, bypassesLocalAddresses
    }

    /// The proxy's address, such as `proxy.example.com:8080`.
    public var address: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The `Proxy-Authorization` header's value, when there's a user name to sign in with.
    public var authorization: String? {
        guard let username, !username.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password ?? "")".utf8).base64EncodedString()
    }

    /// Whether a connection to `host` goes directly instead of through the proxy. This Mac is
    /// always reached directly, unless `includingThisMac` is off, as only tests turn it.
    public func bypasses(_ host: String, includingThisMac: Bool = true) -> Bool {
        let host = host.lowercased()
        if (includingThisMac && HostScope.isThisMac(host)) || bypass.matches(host) {
            return true
        }
        return bypassesLocalAddresses && HostScope.isLocalNetwork(host)
    }
}

/// A local address that sends every request it gets on to one server, for apps that can't use
/// a proxy: point such an app at `http://localhost:8080`, and Reqly records its traffic.
public struct ReverseProxy: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var isOn: Bool
    /// The port on this Mac that apps connect to. Only this Mac can reach it.
    public var localPort: Int
    /// Where requests go, such as `https://api.weatherly.dev`.
    public var serverURL: String
    /// Points redirects to the server back at the local address, so the app stays on it.
    public var rewritesRedirects: Bool

    public init(
        id: UUID = UUID(), isOn: Bool = true, localPort: Int, serverURL: String, rewritesRedirects: Bool = true
    ) {
        self.id = id
        self.isOn = isOn
        self.localPort = localPort
        self.serverURL = serverURL
        self.rewritesRedirects = rewritesRedirects
    }

    /// A server requests can go to: its scheme, host and port.
    public struct Server: Hashable, Sendable {
        public var scheme: String
        public var host: String
        public var port: Int

        /// The scheme, host and port of an `http` or `https` URL, or `nil` for anything else.
        /// A path in the URL is left out, since the app's own paths are sent.
        public init?(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard let components = URLComponents(string: text.contains("://") ? text : "https://\(text)"),
                let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                let host = components.host?.lowercased(), !host.isEmpty
            else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = components.port ?? (scheme == "https" ? 443 : 80)
        }

        public var usesTLS: Bool { scheme == "https" }

        /// The host, with the port when it isn't the scheme's own, as a `Host` header has it.
        public var hostHeader: String {
            let host = self.host.contains(":") ? "[\(self.host)]" : self.host
            let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            return isDefault ? host : "\(host):\(port)"
        }

        /// Such as `https://api.weatherly.dev`.
        public var url: String { "\(scheme)://\(hostHeader)" }
    }

    /// Where requests go, or `nil` while ``serverURL`` isn't an `http` or `https` URL.
    public var server: Server? { Server(serverURL) }

    /// The address apps use, such as `localhost:8080`.
    public var localAddress: String { "localhost:\(localPort)" }
}

/// A client certificate that Reqly presents to servers that ask apps to identify themselves,
/// as some APIs do. This is what the app shows of it; the certificate and its private key stay
/// in the Keychain.
public struct ClientCertificate: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var isOn: Bool
    /// The hosts it's for, such as `api.bank.dev` or `*.bank.dev`.
    public var hosts: [HostPattern]
    /// Who the certificate names, such as "Weatherly Staging".
    public var name: String
    /// Who issued it.
    public var issuer: String
    public var expires: Date?

    public init(
        id: UUID = UUID(), isOn: Bool = true, hosts: [HostPattern], name: String, issuer: String, expires: Date?
    ) {
        self.id = id
        self.isOn = isOn
        self.hosts = hosts
        self.name = name
        self.issuer = issuer
        self.expires = expires
    }

    public func hasExpired(at date: Date = Date()) -> Bool {
        expires.map { $0 < date } ?? false
    }
}

/// Where a host is: on this Mac, on the local network, or elsewhere.
public enum HostScope {
    /// This Mac itself.
    public static func isThisMac(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
            || host == "0.0.0.0"
    }

    /// An address on the local network: a private or link-local IP address, or a `.local` name.
    public static func isLocalNetwork(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        // IPv6: unique local addresses (fc00::/7) and link-local ones (fe80::/10).
        guard host.contains(":") else { return false }
        return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8") || host.hasPrefix("fe9")
            || host.hasPrefix("fea") || host.hasPrefix("feb")
    }
}
