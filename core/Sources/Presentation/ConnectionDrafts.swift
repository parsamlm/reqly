import Foundation
import ReqlyModel

/// Hosts as you type them in a list, such as `intranet.example.com, *.corp.example.com`: the
/// ones that are hosts, and the entries that aren't. The Mac's settings and the Windows app's
/// read them alike.
public struct HostList: Hashable, Sendable {
    public var patterns: [HostPattern]
    /// Entries that aren't a host name or a `*.` pattern, in the order they came.
    public var invalid: [String]

    /// Entries split on commas, spaces and new lines.
    public init(_ text: String) {
        let entries = text.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " }).map(String.init)
        patterns = entries.compactMap(HostPattern.init(rawValue:))
        invalid = entries.filter { HostPattern(rawValue: $0) == nil }
    }

    /// What's wrong with the list: its first entry that isn't a host.
    public var problem: String? {
        invalid.first.map { "“\($0)” isn't a host name or a pattern such as *.example.com." }
    }

    /// The hosts as the field shows them.
    public static func text(_ patterns: [HostPattern]) -> String {
        patterns.map(\.rawValue).joined(separator: ", ")
    }
}

/// The upstream proxy as Settings edit it, before you apply it.
public struct UpstreamProxyDraft: Hashable, Sendable {
    public var isOn = false
    public var host = ""
    public var port = ""
    public var username = ""
    public var password = ""
    /// Hosts to reach directly, as typed.
    public var bypass = ""
    public var bypassesLocalAddresses = true

    public init() {}

    public init(_ proxy: UpstreamProxy?, isOn: Bool) {
        self.isOn = isOn
        guard let proxy else { return }
        host = proxy.host
        port = String(proxy.port)
        username = proxy.username ?? ""
        password = proxy.password ?? ""
        bypass = HostList.text(proxy.bypass)
        bypassesLocalAddresses = proxy.bypassesLocalAddresses
    }

    /// The proxy to save, without the bypass entries that aren't hosts. `nil` without a server or a port.
    public var proxy: UpstreamProxy? {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = Int(port.trimmingCharacters(in: .whitespaces)) else { return nil }
        let username = username.trimmingCharacters(in: .whitespaces)
        return UpstreamProxy(
            host: host, port: port, username: username.isEmpty ? nil : username,
            password: username.isEmpty || password.isEmpty ? nil : password, bypass: HostList(bypass).patterns,
            bypassesLocalAddresses: bypassesLocalAddresses)
    }

    /// What's wrong with the settings, while the proxy is on. `proxyPort` is the one Reqly listens on.
    public func problem(proxyPort: Int) -> String? {
        guard isOn else { return nil }
        let host = host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            return "Enter the proxy's server."
        }
        if host.contains(where: \.isWhitespace) || host.contains("/") {
            return "The server is a host name or an address, without http:// or a path."
        }
        guard let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            return "The port is a number from 1 to 65535."
        }
        if HostScope.isThisMac(host), port == proxyPort {
            return "That's Reqly's own address. Enter the other proxy's."
        }
        return HostList(bypass).problem
    }
}

extension ReverseProxy {
    /// What's wrong with a reverse proxy as you edit it, with its port as you typed it: the port
    /// against Reqly's own and the other reverse proxies', then the server.
    public func problem(port: String, proxyPort: Int, among proxies: [ReverseProxy]) -> String? {
        guard let number = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(number) else {
            return "The port is a number from 1 to 65535."
        }
        if number == proxyPort {
            return "Port \(String(number)) is the one Reqly's proxy uses."
        }
        if proxies.contains(where: { $0.id != id && $0.localPort == number }) {
            return "Another reverse proxy uses port \(String(number))."
        }
        if serverURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the server that requests go to."
        }
        if server == nil {
            return "The server is an address such as https://api.example.com."
        }
        return nil
    }

    /// A port no reverse proxy uses yet, from 8080 up, for a new one.
    public static func suggestedPort(among proxies: [ReverseProxy], proxyPort: Int) -> Int {
        let used = Set(proxies.map(\.localPort))
        return (8080...8999).first { !used.contains($0) && $0 != proxyPort } ?? 8080
    }
}
