import Foundation

/// One header line, with the name spelled the way it was sent.
public struct HeaderField: Hashable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Header fields in the order they were sent. Names match case-insensitively, and
/// repeated names are kept as separate fields.
public struct Headers: Hashable, Sendable, Codable {
    public private(set) var fields: [HeaderField]

    public init(_ fields: [HeaderField] = []) {
        self.fields = fields
    }

    /// The first value for `name`, or `nil` when the header isn't there.
    public subscript(name: String) -> String? {
        fields.first { $0.name.matchesHeaderName(name) }?.value
    }

    public func values(named name: String) -> [String] {
        fields.filter { $0.name.matchesHeaderName(name) }.map(\.value)
    }

    public func contains(_ name: String) -> Bool {
        fields.contains { $0.name.matchesHeaderName(name) }
    }

    public mutating func append(name: String, value: String) {
        fields.append(HeaderField(name: name, value: value))
    }

    public mutating func remove(named name: String) {
        fields.removeAll { $0.name.matchesHeaderName(name) }
    }
}

extension Headers: RandomAccessCollection {
    public var startIndex: Int { fields.startIndex }
    public var endIndex: Int { fields.endIndex }
    public subscript(position: Int) -> HeaderField { fields[position] }
}

extension Headers: ExpressibleByDictionaryLiteral {
    /// Keeps the literal's order, and allows the same name more than once.
    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements.map { HeaderField(name: $0.0, value: $0.1) })
    }
}

extension String {
    /// Header names compare without regard to ASCII case (RFC 9110, section 5.1).
    func matchesHeaderName(_ other: String) -> Bool {
        utf8.count == other.utf8.count && caseInsensitiveCompare(other) == .orderedSame
    }
}
