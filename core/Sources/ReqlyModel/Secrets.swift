import Foundation

extension HeaderField {
    /// Whether the header carries a secret: credentials or cookies. Reqly masks these in the
    /// interface, and can hide them when you save or share traffic.
    public var isSecret: Bool {
        Self.secretNames.contains(name.lowercased())
    }

    private static let secretNames: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie"]
}

extension Headers {
    /// What a hidden secret's value becomes.
    public static let hiddenValue = "(hidden)"

    /// The headers with every secret's value hidden.
    public func hidingSecrets() -> Headers {
        Headers(fields.map { $0.isSecret ? HeaderField(name: $0.name, value: Self.hiddenValue) : $0 })
    }
}

extension Exchange {
    /// The exchange with the secrets in its headers hidden. Bodies stay as they are.
    public func hidingSecrets() -> Exchange {
        var exchange = self
        exchange.request.headers = request.headers.hidingSecrets()
        if let response {
            exchange.response?.headers = response.headers.hidingSecrets()
        }
        return exchange
    }
}
