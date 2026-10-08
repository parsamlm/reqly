import Foundation

/// A host to decrypt: an exact host such as `api.weatherly.dev`, or every subdomain of a
/// domain, written `*.weatherly.dev`.
public struct HostPattern: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// `nil` when the text isn't a host name or a `*.` pattern.
    public init?(rawValue: String) {
        let text = rawValue.trimmingCharacters(in: .whitespaces).lowercased()
        let name = text.hasPrefix("*.") ? String(text.dropFirst(2)) : text
        guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "*" }) else { return nil }
        self.rawValue = text
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let pattern = HostPattern(rawValue: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a host: \(text)"))
        }
        self = pattern
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public func matches(_ host: String) -> Bool {
        let host = host.lowercased()
        if rawValue.hasPrefix("*.") {
            let domain = rawValue.dropFirst(1)  // ".weatherly.dev"
            return host.hasSuffix(domain) && host.count > domain.count
        }
        return host == rawValue
    }
}

extension Sequence<HostPattern> {
    public func matches(_ host: String) -> Bool {
        contains { $0.matches(host) }
    }
}
