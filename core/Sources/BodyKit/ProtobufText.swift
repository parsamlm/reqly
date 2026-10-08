import Foundation

extension ProtobufMessage {
    /// The message in protobuf's text format, as `protoc --decode` prints it, with its syntax
    /// marked. A field without a name shows by its number, as `protoc --decode_raw` prints it.
    public func formatted() -> HighlightedText {
        var builder = TextBuilder()
        ProtobufFormatter.write(self, indent: 0, into: &builder)
        return builder.result
    }

    /// Bytes that aren't a protobuf message, to show among messages that are.
    public static func unreadable(_ data: Data) -> ProtobufMessage {
        ProtobufMessage(fields: [ProtobufField(number: 0, name: "(not protobuf)", value: .bytes(data))])
    }

    /// Several messages, such as a gRPC stream's, each under a comment with its number.
    public static func formatted(_ messages: [ProtobufMessage], sizes: [Int]) -> HighlightedText {
        guard messages.count != 1 else { return messages[0].formatted() }
        var builder = TextBuilder()
        for (position, message) in messages.enumerated() {
            if position > 0 {
                builder.append("\n")
            }
            let size = position < sizes.count ? " · \(sizes[position].formatted()) bytes" : ""
            builder.append("# Message \(position + 1) of \(messages.count)\(size)\n", .comment)
            ProtobufFormatter.write(message, indent: 0, into: &builder)
        }
        return builder.result
    }
}

enum ProtobufFormatter {
    static func write(_ message: ProtobufMessage, indent: Int, into builder: inout TextBuilder) {
        for field in message.fields {
            builder.append(String(repeating: "  ", count: indent))
            builder.append(field.label, .key)
            if let nested = field.value.message {
                if nested.fields.isEmpty {
                    builder.append(" {}\n")
                } else {
                    builder.append(" {\n")
                    write(nested, indent: indent + 1, into: &builder)
                    builder.append(String(repeating: "  ", count: indent) + "}\n")
                }
            } else {
                builder.append(": ")
                writeScalar(field.value, into: &builder)
                builder.append("\n")
            }
        }
    }

    static func writeScalar(_ value: ProtobufValue, into builder: inout TextBuilder) {
        switch value {
        case .string(let text): builder.append(quoted(text), .string)
        case .bytes(let data): builder.append(quoted(data), .string)
        case .bool(let flag): builder.append(flag ? "true" : "false", .literal)
        case .enumeration(let number, let name):
            if let name {
                builder.append(name, .literal)
            } else {
                builder.append(String(number), .number)
            }
        default: builder.append(text(of: value), .number)
        }
    }

    /// A value as text, on one line: a string in quotes, bytes as hex.
    static func text(of value: ProtobufValue) -> String {
        switch value {
        case .varint(let number):
            // Without a schema, a negative int32 or int64 looks like a huge unsigned number.
            number > UInt64(Int64.max) ? String(Int64(bitPattern: number)) : String(number)
        case .fixed32(let bits): guess(bits)
        case .fixed64(let bits): guess(bits)
        case .string(let text): quoted(text)
        case .bytes(let data): hex(data, limit: 48)
        case .int(let number): String(number)
        case .uint(let number): String(number)
        case .float(let number): decimal(Double(number), text: number.description)
        case .double(let number): decimal(number, text: number.description)
        case .bool(let flag): flag ? "true" : "false"
        case .enumeration(let number, let name): name ?? String(number)
        case .message(let message), .group(let message): fieldCount(message)
        }
    }

    static func fieldCount(_ message: ProtobufMessage) -> String {
        switch message.fields.count {
        case 0: "empty"
        case 1: "1 field"
        default: "\(message.fields.count) fields"
        }
    }

    /// Four bytes as a float when they read as an everyday one, and as an integer otherwise.
    /// Small integers are tiny floats, and timestamps and IDs are enormous ones.
    private static func guess(_ bits: UInt32) -> String {
        let float = Float(bitPattern: bits)
        if bits & 0x7F80_0000 != 0, float.isFinite, abs(float) >= 1e-6, abs(float) < 1e9 {
            return float.description
        }
        return bits & 0x8000_0000 != 0 ? String(Int32(bitPattern: bits)) : String(bits)
    }

    private static func guess(_ bits: UInt64) -> String {
        let double = Double(bitPattern: bits)
        if bits & 0x7FF0_0000_0000_0000 != 0, double.isFinite, abs(double) >= 1e-9, abs(double) < 1e15 {
            return double.description
        }
        return bits & 0x8000_0000_0000_0000 != 0 ? String(Int64(bitPattern: bits)) : String(bits)
    }

    /// A float as text format writes it: `inf` and `nan` have names of their own.
    private static func decimal(_ number: Double, text: String) -> String {
        if number.isNaN { return "nan" }
        if number.isInfinite { return number < 0 ? "-inf" : "inf" }
        return text
    }

    static func hex(_ data: Data, limit: Int = .max) -> String {
        let shown = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > limit ? shown + " …" : shown
    }

    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += String(format: "\\x%02x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// Bytes as a text format string: printable ASCII as is, and the rest escaped.
    static func quoted(_ data: Data) -> String {
        var result = "\""
        for byte in data {
            switch byte {
            case UInt8(ascii: "\""): result += "\\\""
            case UInt8(ascii: "\\"): result += "\\\\"
            case 0x20..<0x7F: result.unicodeScalars.append(UnicodeScalar(byte))
            default: result += String(format: "\\x%02x", byte)
            }
        }
        return result + "\""
    }
}

// MARK: - Tree

/// Protobuf messages as an outline for the tree viewer. A repeated field's values sit
/// together under the field, and a map's entries under their keys.
public struct ProtobufTree: ValueOutline {
    public struct Node: Sendable {
        public var label: String
        var content: Content
        public var parent: Int?
        public var children: [Int]
        public var depth: Int
        var step: Step
    }

    enum Content: Sendable {
        /// Several messages, such as a gRPC stream's.
        case stream(Int)
        case message(ProtobufMessage)
        case field(ProtobufField)
        /// A repeated field's values, or a map's entries.
        case list([ProtobufField], isMap: Bool)
    }

    enum Step: Sendable {
        case root
        case field(String)
        case index(Int)
        /// A map's key, as text format writes it.
        case key(String)
    }

    public private(set) var nodes: [Node] = []

    /// One message at the root, labeled `rootLabel`, such as "Response".
    public init(_ message: ProtobufMessage, rootLabel: String) {
        addRoot(message, label: rootLabel)
    }

    /// Several messages, such as a gRPC stream's, each a row under the root.
    public init(messages: [ProtobufMessage], rootLabel: String) {
        if messages.count == 1 {
            addRoot(messages[0], label: rootLabel)
            return
        }
        let root = add(.stream(messages.count), label: rootLabel, step: .root, parent: nil, depth: 0)
        var children: [Int] = []
        for (position, message) in messages.enumerated() {
            let id = add(
                .message(message), label: "Message \(position + 1)", step: .index(position), parent: root, depth: 1)
            nodes[id].children = addFields(of: message, parent: id, depth: 2)
            children.append(id)
        }
        nodes[root].children = children
    }

    private mutating func addRoot(_ message: ProtobufMessage, label: String) {
        let root = add(.message(message), label: label, step: .root, parent: nil, depth: 0)
        nodes[root].children = addFields(of: message, parent: root, depth: 1)
    }

    private mutating func add(_ content: Content, label: String, step: Step, parent: Int?, depth: Int) -> Int {
        nodes.append(Node(label: label, content: content, parent: parent, children: [], depth: depth, step: step))
        return nodes.count - 1
    }

    /// The rows for a message's fields. Values of the same field go together, where the first
    /// of them came.
    private mutating func addFields(of message: ProtobufMessage, parent: Int, depth: Int) -> [Int] {
        var order: [Int] = []
        var values: [Int: [ProtobufField]] = [:]
        for field in message.fields {
            if values[field.number] == nil {
                order.append(field.number)
            }
            values[field.number, default: []].append(field)
        }
        var children: [Int] = []
        for number in order {
            let fields = values[number] ?? []
            let first = fields[0]
            if fields.count == 1, !first.isRepeated {
                children.append(
                    addField(first, label: first.label, step: .field(first.label), parent: parent, depth: depth))
                continue
            }
            let isMap = fields.allSatisfy { $0.value.message?.isMapEntry == true }
            let list = add(
                .list(fields, isMap: isMap), label: first.label, step: .field(first.label), parent: parent, depth: depth
            )
            var items: [Int] = []
            for (position, field) in fields.enumerated() {
                if isMap, let entry = field.value.message {
                    let key =
                        entry.fields.first { $0.number == 1 }.map { ProtobufFormatter.text(of: $0.value) } ?? "\"\""
                    let value = entry.fields.first { $0.number == 2 } ?? ProtobufField(number: 2, value: .string(""))
                    items.append(addField(value, label: key, step: .key(key), parent: list, depth: depth + 1))
                } else {
                    items.append(
                        addField(field, label: String(position), step: .index(position), parent: list, depth: depth + 1)
                    )
                }
            }
            nodes[list].children = items
            children.append(list)
        }
        return children
    }

    private mutating func addField(_ field: ProtobufField, label: String, step: Step, parent: Int, depth: Int) -> Int {
        let id = add(.field(field), label: label, step: step, parent: parent, depth: depth)
        if let message = field.value.message, Self.wellKnownSummary(message) == nil {
            nodes[id].children = addFields(of: message, parent: id, depth: depth + 1)
        }
        return id
    }

    public var count: Int { nodes.count }

    public func node(_ id: Int) -> OutlineNode {
        let node = nodes[id]
        return OutlineNode(
            label: node.label, summary: summary(node.content), typeName: typeName(node.content),
            style: style(node.content), parent: node.parent, children: node.children, depth: node.depth)
    }

    private func summary(_ content: Content) -> String {
        switch content {
        case .stream(let count): return "\(count) messages"
        case .message(let message): return ProtobufFormatter.fieldCount(message)
        case .field(let field):
            if let message = field.value.message {
                return Self.wellKnownSummary(message) ?? ProtobufFormatter.fieldCount(message)
            }
            return ProtobufFormatter.text(of: field.value)
        case .list(let fields, let isMap):
            if isMap {
                return fields.count == 1 ? "1 entry" : "\(fields.count) entries"
            }
            return fields.count == 1 ? "1 item" : "\(fields.count) items"
        }
    }

    private func typeName(_ content: Content) -> String {
        switch content {
        case .stream: "stream"
        case .message(let message): message.typeName.map(Self.shortName) ?? "message"
        case .field(let field): Self.shortName(field.typeName)
        case .list(_, let isMap): isMap ? "map" : "repeated"
        }
    }

    private func style(_ content: Content) -> OutlineStyle {
        guard case .field(let field) = content else { return .container }
        switch field.value {
        case .string: return .string
        case .bytes: return .bytes
        case .bool, .enumeration: return .literal
        case .message(let message), .group(let message):
            return Self.wellKnownSummary(message) == nil ? .container : .literal
        default: return .number
        }
    }

    /// `weather.v1.Forecast` becomes `Forecast`.
    private static func shortName(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    /// The well-known types that hold one value in a few fields, as that value: a timestamp
    /// as its date, a duration in seconds, and a wrapper as what it wraps.
    static func wellKnownSummary(_ message: ProtobufMessage) -> String? {
        func number(_ field: Int) -> Int64 {
            switch message.fields.last(where: { $0.number == field })?.value {
            case .int(let value): value
            case .uint(let value): Int64(truncatingIfNeeded: value)
            default: 0
            }
        }
        switch message.typeName {
        case "google.protobuf.Timestamp":
            let seconds = Double(number(1)) + Double(number(2)) / 1e9
            let date = Date(timeIntervalSince1970: seconds)
            let format = Date.ISO8601FormatStyle(includingFractionalSeconds: number(2) != 0)
            return date.formatted(format)
        case "google.protobuf.Duration":
            let seconds = Double(number(1)) + Double(number(2)) / 1e9
            return "\(seconds.formatted(.number.precision(.fractionLength(0...9))))s"
        case "google.protobuf.DoubleValue", "google.protobuf.FloatValue", "google.protobuf.Int64Value",
            "google.protobuf.UInt64Value", "google.protobuf.Int32Value", "google.protobuf.UInt32Value",
            "google.protobuf.BoolValue", "google.protobuf.StringValue", "google.protobuf.BytesValue":
            if let value = message.fields.last?.value {
                return ProtobufFormatter.text(of: value)
            }
            // A wrapper of the default value sends no field at all.
            switch message.typeName {
            case "google.protobuf.BoolValue": return "false"
            case "google.protobuf.StringValue", "google.protobuf.BytesValue": return "\"\""
            default: return "0"
            }
        default:
            return nil
        }
    }

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
            case .root: break
            case .field(let name): path += path.isEmpty ? name : ".\(name)"
            case .index(let position): path += "[\(position)]"
            case .key(let key): path += "[\(key)]"
            }
        }
        return path
    }

    public func copyText(of id: Int) -> String {
        switch nodes[id].content {
        case .stream:
            let messages = nodes[id].children.compactMap { child -> ProtobufMessage? in
                if case .message(let message) = nodes[child].content { return message }
                return nil
            }
            return ProtobufMessage.formatted(messages, sizes: []).text
        case .message(let message):
            return message.formatted().text
        case .list(let fields, _):
            return ProtobufMessage(fields: fields).formatted().text
        case .field(let field):
            switch field.value {
            case .string(let text): return text
            case .bytes(let data): return data.map { String(format: "%02X", $0) }.joined(separator: " ")
            case .message(let message), .group(let message): return message.formatted().text
            default: return ProtobufFormatter.text(of: field.value)
            }
        }
    }
}
