import Foundation

/// A JSON value. Object members keep the order they were sent in.
public indirect enum JSONValue: Hashable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    /// The number exactly as it was written, such as `1.50` or `2e10`.
    case number(String)
    case bool(Bool)
    case null
}

public struct JSONMember: Hashable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// Why some text isn't valid JSON.
public struct JSONError: Error, Hashable, Sendable {
    /// Where the problem is, in bytes from the start.
    public var offset: Int
    public var message: String
}

extension JSONValue {
    /// Nesting deeper than this is an error, so a hostile body can't exhaust the stack. Parsing,
    /// formatting and the tree all go one call deeper for each level, on background threads,
    /// whose stacks are small.
    public static let maximumDepth = 100

    /// Parses JSON text.
    public static func parse(_ data: Data) throws -> JSONValue {
        var reader = JSONReader(bytes: [UInt8](data))
        let value = try reader.value()
        reader.skipWhitespace()
        guard reader.index == reader.bytes.count else {
            throw reader.error("There's more text after the JSON value.")
        }
        return value
    }

    /// The value as indented text, with its syntax marked. Short objects and arrays that hold
    /// no others stay on one line.
    public func formatted() -> HighlightedText {
        var builder = TextBuilder()
        JSONFormatter.write(self, indent: 0, into: &builder)
        return builder.result
    }

    /// The value as it's typed in JSON, on one line for a string, number or literal.
    public var scalarText: String? {
        switch self {
        case .string(let text): JSONFormatter.quoted(text)
        case .number(let text): text
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .object, .array: nil
        }
    }

    var isScalarOrEmpty: Bool {
        switch self {
        case .object(let members): members.isEmpty
        case .array(let items): items.isEmpty
        default: true
        }
    }
}

// MARK: - Reading

private struct JSONReader {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    func error(_ message: String) -> JSONError {
        JSONError(offset: index, message: message)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, BodyKind.isWhitespace(bytes[index]) {
            index += 1
        }
    }

    mutating func value() throws -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw error("The JSON ends too early.") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"):
            try literal("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try literal("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try literal("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .number(try number())
        default:
            throw error("This isn't the start of a JSON value.")
        }
    }

    private mutating func nest() throws {
        depth += 1
        guard depth <= JSONValue.maximumDepth else { throw error("The JSON is nested too deeply.") }
    }

    private mutating func object() throws -> JSONValue {
        try nest()
        defer { depth -= 1 }
        index += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw error("An object's keys must be strings in double quotes.")
            }
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw error("A colon must follow each key.")
            }
            index += 1
            members.append(JSONMember(key: key, value: try value()))
            skipWhitespace()
            guard index < bytes.count else { throw error("The object isn't closed.") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            } else {
                throw error("A comma or a closing brace must follow each value.")
            }
        }
    }

    private mutating func array() throws -> JSONValue {
        try nest()
        defer { depth -= 1 }
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try value())
            skipWhitespace()
            guard index < bytes.count else { throw error("The array isn't closed.") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            } else {
                throw error("A comma or a closing bracket must follow each item.")
            }
        }
    }

    private mutating func literal(_ word: StaticString) throws {
        let count = word.utf8CodeUnitCount
        let matches = word.withUTF8Buffer { expected in
            index + count <= bytes.count && bytes[index..<index + count].elementsEqual(expected)
        }
        guard matches else { throw error("This isn't a JSON value.") }
        index += count
    }

    private mutating func number() throws -> String {
        let start = index
        func digits() -> Int {
            let first = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            return index - first
        }
        if bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        guard digits() > 0 else { throw error("A number needs digits.") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw error("A number needs digits after its decimal point.") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard digits() > 0 else { throw error("A number needs digits in its exponent.") }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func string() throws -> String {
        index += 1
        let start = index
        // Most strings have no escapes, so they're copied in one piece.
        while index < bytes.count, bytes[index] != UInt8(ascii: "\""), bytes[index] != UInt8(ascii: "\\") {
            guard bytes[index] >= 0x20 else { throw error("A string can't hold control characters.") }
            index += 1
        }
        guard index < bytes.count else { throw error("The string isn't closed.") }
        if bytes[index] == UInt8(ascii: "\"") {
            index += 1
            return String(decoding: bytes[start..<index - 1], as: UTF8.self)
        }
        var decoded = [UInt8](bytes[start..<index])
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: decoded, as: UTF8.self)
            }
            guard byte >= 0x20 else { throw error("A string can't hold control characters.") }
            if byte != UInt8(ascii: "\\") {
                decoded.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "\""): decoded.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): decoded.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "/"): decoded.append(UInt8(ascii: "/"))
            case UInt8(ascii: "b"): decoded.append(0x08)
            case UInt8(ascii: "f"): decoded.append(0x0C)
            case UInt8(ascii: "n"): decoded.append(0x0A)
            case UInt8(ascii: "r"): decoded.append(0x0D)
            case UInt8(ascii: "t"): decoded.append(0x09)
            case UInt8(ascii: "u"):
                let scalar = try unicodeEscape()
                decoded.append(contentsOf: Array(String(Character(scalar)).utf8))
                continue
            default:
                throw error("This isn't a valid escape in a string.")
            }
            index += 1
        }
        throw error("The string isn't closed.")
    }

    /// Reads `uXXXX`, or a pair of them for a character outside the Basic Multilingual Plane.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        let high = try hexQuad()
        if (0xD800..<0xDC00).contains(high), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
            bytes[index + 1] == UInt8(ascii: "u")
        {
            index += 1
            let low = try hexQuad()
            if (0xDC00..<0xE000).contains(low) {
                return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}"
            }
        }
        return Unicode.Scalar(high) ?? "\u{FFFD}"
    }

    /// Reads `u` and four hex digits, leaving the index after them.
    private mutating func hexQuad() throws -> UInt32 {
        index += 1
        guard index + 4 <= bytes.count else { throw error("A \\u escape needs four hex digits.") }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            guard let digit = Self.hexValue(byte) else { throw error("A \\u escape needs four hex digits.") }
            value = value << 4 | digit
        }
        index += 4
        return value
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }
}

// MARK: - Writing

private enum JSONFormatter {
    /// Objects and arrays up to this long stay on one line, if they hold no others.
    static let lineLimit = 72

    static func write(_ value: JSONValue, indent: Int, into builder: inout TextBuilder) {
        switch value {
        case .object(let members):
            if members.isEmpty {
                builder.append("{}")
            } else if fitsOnOneLine(value) {
                writeInline(value, into: &builder)
            } else {
                builder.append("{\n")
                for (position, member) in members.enumerated() {
                    builder.append(spaces(indent + 1))
                    builder.append(quoted(member.key), .key)
                    builder.append(": ")
                    write(member.value, indent: indent + 1, into: &builder)
                    builder.append(position < members.count - 1 ? ",\n" : "\n")
                }
                builder.append(spaces(indent) + "}")
            }
        case .array(let items):
            if items.isEmpty {
                builder.append("[]")
            } else if fitsOnOneLine(value) {
                writeInline(value, into: &builder)
            } else {
                builder.append("[\n")
                for (position, item) in items.enumerated() {
                    builder.append(spaces(indent + 1))
                    write(item, indent: indent + 1, into: &builder)
                    builder.append(position < items.count - 1 ? ",\n" : "\n")
                }
                builder.append(spaces(indent) + "]")
            }
        default:
            writeScalar(value, into: &builder)
        }
    }

    private static func writeScalar(_ value: JSONValue, into builder: inout TextBuilder) {
        switch value {
        case .string(let text): builder.append(quoted(text), .string)
        case .number(let text): builder.append(text, .number)
        case .bool(let flag): builder.append(flag ? "true" : "false", .literal)
        case .null: builder.append("null", .literal)
        case .object: builder.append("{}")
        case .array: builder.append("[]")
        }
    }

    private static func writeInline(_ value: JSONValue, into builder: inout TextBuilder) {
        switch value {
        case .object(let members):
            builder.append("{ ")
            for (position, member) in members.enumerated() {
                builder.append(quoted(member.key), .key)
                builder.append(": ")
                writeScalar(member.value, into: &builder)
                builder.append(position < members.count - 1 ? ", " : " }")
            }
        case .array(let items):
            builder.append("[")
            for (position, item) in items.enumerated() {
                writeScalar(item, into: &builder)
                builder.append(position < items.count - 1 ? ", " : "]")
            }
        default:
            writeScalar(value, into: &builder)
        }
    }

    private static func fitsOnOneLine(_ value: JSONValue) -> Bool {
        var length: Int
        switch value {
        case .object(let members):
            guard members.count <= 12, members.allSatisfy({ $0.value.isScalarOrEmpty }) else { return false }
            length = 4 + 2 * (members.count - 1)
            for member in members {
                length += quoted(member.key).count + 2 + (member.value.scalarText?.count ?? 2)
                if length > lineLimit { return false }
            }
        case .array(let items):
            guard items.count <= 12, items.allSatisfy(\.isScalarOrEmpty) else { return false }
            length = 2 + 2 * (items.count - 1)
            for item in items {
                length += item.scalarText?.count ?? 2
                if length > lineLimit { return false }
            }
        default:
            return true
        }
        return length <= lineLimit
    }

    private static func spaces(_ level: Int) -> String {
        String(repeating: "  ", count: level)
    }

    /// `text` as a JSON string, in double quotes, with what must be escaped escaped.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case _ where scalar.value < 0x20:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

// MARK: - Tree

/// A JSON value as numbered nodes, for showing it as an outline.
public struct JSONTree: Sendable {
    public struct Node: Sendable {
        /// The key, the index in brackets' place, or the root's label.
        public var label: String
        public var value: JSONValue
        public var parent: Int?
        public var children: [Int]
        public var depth: Int
        /// How the node is reached from its parent: a key, or an index.
        public var step: Step

        /// The type's name, such as "object" or "string".
        public var typeName: String {
            switch value {
            case .object: "object"
            case .array: "array"
            case .string: "string"
            case .number: "number"
            case .bool: "boolean"
            case .null: "null"
            }
        }

        /// What the value column shows: the value itself, or what an object or array holds.
        public var summary: String {
            switch value {
            case .object(let members):
                if members.isEmpty { return "empty" }
                // Objects in an array are told apart by their keys.
                if case .index = step, members.count <= 4 {
                    return members.map(\.key).joined(separator: ", ")
                }
                return members.count == 1 ? "1 key" : "\(members.count) keys"
            case .array(let items):
                if items.isEmpty { return "empty" }
                return items.count == 1 ? "1 item" : "\(items.count) items"
            default:
                return value.scalarText ?? ""
            }
        }
    }

    public enum Step: Sendable, Hashable {
        case root
        case key(String)
        case index(Int)
    }

    public private(set) var nodes: [Node] = []

    /// The tree of `value`, whose root is labeled `rootLabel`, such as "Response".
    public init(_ value: JSONValue, rootLabel: String) {
        add(value, label: rootLabel, step: .root, parent: nil, depth: 0)
    }

    @discardableResult
    private mutating func add(_ value: JSONValue, label: String, step: Step, parent: Int?, depth: Int) -> Int {
        let id = nodes.count
        nodes.append(Node(label: label, value: value, parent: parent, children: [], depth: depth, step: step))
        var children: [Int] = []
        switch value {
        case .object(let members):
            for member in members {
                children.append(
                    add(member.value, label: member.key, step: .key(member.key), parent: id, depth: depth + 1))
            }
        case .array(let items):
            for (position, item) in items.enumerated() {
                children.append(
                    add(item, label: String(position), step: .index(position), parent: id, depth: depth + 1))
            }
        default:
            break
        }
        nodes[id].children = children
        return id
    }

    /// The way to reach a node from the root, such as `current.temperature` or `hourly[0].time`.
    public func path(to id: Int) -> String {
        var steps: [Step] = []
        var current: Int? = id
        while let node = current {
            steps.append(nodes[node].step)
            current = nodes[node].parent
        }
        var path = ""
        for step in steps.reversed() {
            switch step {
            case .root:
                break
            case .index(let position):
                path += "[\(position)]"
            case .key(let key):
                let isIdentifier =
                    !key.isEmpty && key.first.map { $0.isLetter || $0 == "_" || $0 == "$" } == true
                    && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
                if isIdentifier {
                    path += path.isEmpty ? key : ".\(key)"
                } else {
                    path += "[\(JSONFormatter.quoted(key))]"
                }
            }
        }
        return path
    }
}
