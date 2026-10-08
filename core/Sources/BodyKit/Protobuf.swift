import Foundation

/// A protobuf message as Reqly reads it: its fields in the order they came. Without a schema,
/// a field has its number and a value guessed from its bytes. With one, from `.proto` files,
/// it also has its name and its type.
public struct ProtobufMessage: Hashable, Sendable {
    /// The message's full type name, such as `weather.v1.Forecast`, when a schema gave it.
    public var typeName: String?
    public var fields: [ProtobufField]
    /// The message is one entry of a map, with its key as field 1 and its value as field 2.
    public var isMapEntry: Bool

    public init(typeName: String? = nil, fields: [ProtobufField] = [], isMapEntry: Bool = false) {
        self.typeName = typeName
        self.fields = fields
        self.isMapEntry = isMapEntry
    }
}

/// One value of a field, as it came. A repeated field comes as one of these for each value.
public struct ProtobufField: Hashable, Sendable {
    public var number: Int
    /// The field's name, when a schema gave it.
    public var name: String?
    /// The field's type in the schema, such as `int32` or `weather.v1.Forecast`.
    public var declaredType: String?
    /// The schema says the field is repeated, or a map.
    public var isRepeated: Bool
    public var value: ProtobufValue

    public init(
        number: Int, name: String? = nil, declaredType: String? = nil, isRepeated: Bool = false,
        value: ProtobufValue
    ) {
        self.number = number
        self.name = name
        self.declaredType = declaredType
        self.isRepeated = isRepeated
        self.value = value
    }

    /// The name to show: the field's name, or its number.
    public var label: String { name ?? String(number) }

    /// The type to show: the schema's, or what the bytes were.
    public var typeName: String { declaredType ?? value.wireName }
}

/// A field's value.
public indirect enum ProtobufValue: Hashable, Sendable {
    /// A varint read without a schema, which could be any kind of integer, a bool or an enum.
    case varint(UInt64)
    /// Four bytes read without a schema: a float, or an integer.
    case fixed32(UInt32)
    /// Eight bytes read without a schema: a double, or an integer.
    case fixed64(UInt64)
    case string(String)
    case bytes(Data)
    case message(ProtobufMessage)
    /// Fields between a start and an end marker, as proto2's groups send them.
    case group(ProtobufMessage)
    case int(Int64)
    case uint(UInt64)
    case float(Float)
    case double(Double)
    case bool(Bool)
    /// An enum's number, with its name when the schema has one for it.
    case enumeration(Int32, name: String?)

    /// What the bytes were, for a field the schema doesn't know.
    public var wireName: String {
        switch self {
        case .varint: "varint"
        case .fixed32: "fixed32"
        case .fixed64: "fixed64"
        case .string: "string"
        case .bytes: "bytes"
        case .message: "message"
        case .group: "group"
        case .int: "int64"
        case .uint: "uint64"
        case .float: "float"
        case .double: "double"
        case .bool: "bool"
        case .enumeration: "enum"
        }
    }

    /// The message a message or a group holds.
    public var message: ProtobufMessage? {
        switch self {
        case .message(let message), .group(let message): message
        default: nil
        }
    }
}

/// Reads protobuf's wire format.
public enum Protobuf {
    /// Messages nested deeper than this are shown as bytes, so a hostile body can't exhaust
    /// the stack. Reading, formatting and the tree all go one call deeper for each level.
    public static let maximumDepth = 48

    /// `data` read as a message, or `nil` when it isn't one. With a schema and the name of
    /// the message's type, fields get their names and types. Fields the schema doesn't know,
    /// or that don't match it, are read as without one.
    public static func decode(_ data: Data, as typeName: String? = nil, schema: ProtobufSchema? = nil)
        -> ProtobufMessage?
    {
        let bytes = [UInt8](data)
        let decoder = WireDecoder(bytes: bytes, schema: schema ?? ProtobufSchema())
        let type = typeName.flatMap { decoder.schema.message(named: $0) }
        return decoder.message(0..<bytes.count, type: type, depth: 0)
    }
}

/// A value as the wire format has it, before it's known what it means.
private enum WireValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case lengthDelimited(Range<Int>)
    /// A group's fields, without its end marker.
    case group(Range<Int>)
}

private struct WireReader {
    let bytes: [UInt8]
    var index: Int
    let end: Int

    init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        index = range.lowerBound
        end = range.upperBound
    }

    var isAtEnd: Bool { index >= end }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard index < end else { return nil }
            let byte = bytes[index]
            index += 1
            // The tenth byte has room for one more bit.
            if shift == 63, byte > 1 { return nil }
            result |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        return nil
    }

    /// A field's number and wire type.
    mutating func tag() -> (number: Int, wireType: UInt8)? {
        guard let tag = varint(), tag >> 3 >= 1, tag >> 3 <= 536_870_911 else { return nil }
        return (Int(tag >> 3), UInt8(tag & 7))
    }

    private mutating func little(_ count: Int) -> UInt64? {
        guard end - index >= count else { return nil }
        var value: UInt64 = 0
        for offset in 0..<count {
            value |= UInt64(bytes[index + offset]) << UInt64(8 * offset)
        }
        index += count
        return value
    }

    /// The value after a tag. A group's value runs to its end marker, and groups may nest.
    mutating func value(wireType: UInt8, number: Int, depth: Int) -> WireValue? {
        switch wireType {
        case 0:
            return varint().map(WireValue.varint)
        case 1:
            return little(8).map(WireValue.fixed64)
        case 5:
            return little(4).map { .fixed32(UInt32($0)) }
        case 2:
            guard let length = varint(), length <= UInt64(end - index) else { return nil }
            let start = index
            index += Int(length)
            return .lengthDelimited(start..<index)
        case 3:
            guard depth < Protobuf.maximumDepth else { return nil }
            let start = index
            while true {
                let fieldStart = index
                guard let (inner, innerType) = tag() else { return nil }
                if innerType == 4 {
                    return inner == number ? .group(start..<fieldStart) : nil
                }
                guard value(wireType: innerType, number: inner, depth: depth + 1) != nil else { return nil }
            }
        default:
            // 4 ends a group that never started; 6 and 7 aren't wire types.
            return nil
        }
    }
}

private struct WireDecoder {
    let bytes: [UInt8]
    let schema: ProtobufSchema

    func message(_ range: Range<Int>, type: ProtobufSchema.Message?, depth: Int) -> ProtobufMessage? {
        var reader = WireReader(bytes: bytes, range: range)
        var fields: [ProtobufField] = []
        while !reader.isAtEnd {
            guard let (number, wireType) = reader.tag(),
                let wire = reader.value(wireType: wireType, number: number, depth: depth)
            else { return nil }
            if let field = type?.fields[number], let values = typed(wire, as: field, depth: depth) {
                for value in values {
                    fields.append(
                        ProtobufField(
                            number: number, name: field.name, declaredType: field.type.name,
                            isRepeated: field.isRepeated, value: value))
                }
            } else {
                guard let value = guessed(wire, depth: depth) else { return nil }
                fields.append(ProtobufField(number: number, value: value))
            }
        }
        var message = ProtobufMessage(typeName: type?.name, fields: fields, isMapEntry: type?.isMapEntry ?? false)
        if type?.name == "google.protobuf.Any" {
            unpackAny(&message, depth: depth)
        }
        return message
    }

    // MARK: Without a schema

    /// A value read without knowing its type. Length-delimited bytes are text when they read
    /// as text, a message when they parse as one, and bytes otherwise. Bytes that could be
    /// either are text, unless they start the way a message whose first field is number 1 does.
    private func guessed(_ wire: WireValue, depth: Int) -> ProtobufValue? {
        switch wire {
        case .varint(let value): return .varint(value)
        case .fixed32(let value): return .fixed32(value)
        case .fixed64(let value): return .fixed64(value)
        case .group(let range):
            return message(range, type: nil, depth: depth + 1).map(ProtobufValue.group)
        case .lengthDelimited(let range):
            guard !range.isEmpty else { return .string("") }
            let text = readableText(range)
            let first = bytes[range.lowerBound]
            let startsLikeAMessage = first == 0x09 || first == 0x0A || first == 0x0D
            if let text, !startsLikeAMessage {
                return .string(text)
            }
            if depth + 1 < Protobuf.maximumDepth, let nested = message(range, type: nil, depth: depth + 1) {
                return .message(nested)
            }
            return text.map(ProtobufValue.string) ?? .bytes(Data(bytes[range]))
        }
    }

    /// The bytes as UTF-8 text, when they're text a person could read: no control characters
    /// besides tabs and line breaks.
    private func readableText(_ range: Range<Int>) -> String? {
        guard let text = String(validating: bytes[range], as: UTF8.self) else { return nil }
        for scalar in text.unicodeScalars where scalar.properties.generalCategory == .control {
            if scalar != "\t", scalar != "\n", scalar != "\r" { return nil }
        }
        return text
    }

    // MARK: With a schema

    /// The values a field holds, read as its type says, or `nil` when the bytes don't match
    /// it. A packed repeated field holds many.
    private func typed(_ wire: WireValue, as field: ProtobufSchema.Field, depth: Int) -> [ProtobufValue]? {
        switch (field.type, wire) {
        case (.scalar(let scalar), _):
            if case .lengthDelimited(let range) = wire, scalar.wireType != 2 {
                return field.isRepeated ? packed(range, scalar: scalar) : nil
            }
            return scalarValue(wire, as: scalar).map { [$0] }
        case (.enumeration(let name), .varint(let value)):
            return [enumValue(value, in: name)]
        case (.enumeration(let name), .lengthDelimited(let range)) where field.isRepeated:
            var reader = WireReader(bytes: bytes, range: range)
            var values: [ProtobufValue] = []
            while !reader.isAtEnd {
                guard let value = reader.varint() else { return nil }
                values.append(enumValue(value, in: name))
            }
            return values
        case (.message(let name), .lengthDelimited(let range)), (.message(let name), .group(let range)):
            // Editions may send any message field between group markers.
            guard depth + 1 < Protobuf.maximumDepth,
                let nested = message(range, type: schema.message(named: name), depth: depth + 1)
            else { return nil }
            if case .group = wire {
                return [.group(nested)]
            }
            return [.message(nested)]
        default:
            return nil
        }
    }

    private func scalarValue(_ wire: WireValue, as scalar: ProtobufSchema.Scalar) -> ProtobufValue? {
        switch (scalar, wire) {
        case (.int32, .varint(let value)): .int(Int64(Int32(truncatingIfNeeded: value)))
        case (.int64, .varint(let value)): .int(Int64(bitPattern: value))
        case (.uint32, .varint(let value)): .uint(UInt64(UInt32(truncatingIfNeeded: value)))
        case (.uint64, .varint(let value)): .uint(value)
        case (.sint32, .varint(let value)):
            .int(Int64(Self.zigzag(UInt64(UInt32(truncatingIfNeeded: value)))))
        case (.sint64, .varint(let value)): .int(Self.zigzag(value))
        case (.bool, .varint(let value)): .bool(value != 0)
        case (.fixed32, .fixed32(let value)): .uint(UInt64(value))
        case (.sfixed32, .fixed32(let value)): .int(Int64(Int32(bitPattern: value)))
        case (.float, .fixed32(let value)): .float(Float(bitPattern: value))
        case (.fixed64, .fixed64(let value)): .uint(value)
        case (.sfixed64, .fixed64(let value)): .int(Int64(bitPattern: value))
        case (.double, .fixed64(let value)): .double(Double(bitPattern: value))
        case (.string, .lengthDelimited(let range)):
            // Text that isn't UTF-8 shows as the bytes it is.
            String(validating: bytes[range], as: UTF8.self).map(ProtobufValue.string)
                ?? .bytes(Data(bytes[range]))
        case (.bytes, .lengthDelimited(let range)): .bytes(Data(bytes[range]))
        default: nil
        }
    }

    /// Numbers packed one after another into one length-delimited field.
    private func packed(_ range: Range<Int>, scalar: ProtobufSchema.Scalar) -> [ProtobufValue]? {
        var reader = WireReader(bytes: bytes, range: range)
        var values: [ProtobufValue] = []
        while !reader.isAtEnd {
            guard let wire = reader.value(wireType: scalar.wireType, number: 0, depth: 0),
                let value = scalarValue(wire, as: scalar)
            else { return nil }
            values.append(value)
        }
        return values
    }

    private func enumValue(_ value: UInt64, in enumName: String) -> ProtobufValue {
        let number = Int32(truncatingIfNeeded: value)
        return .enumeration(number, name: schema.enums[enumName]?.names[number])
    }

    private static func zigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }

    /// An `Any` names the type of the message it carries, so a schema that has the type can
    /// read the message too.
    private func unpackAny(_ message: inout ProtobufMessage, depth: Int) {
        guard case .string(let url)? = message.fields.first(where: { $0.number == 1 })?.value,
            let index = message.fields.firstIndex(where: { $0.number == 2 }),
            case .bytes(let data) = message.fields[index].value,
            let type = schema.message(named: String(url.split(separator: "/").last ?? "")),
            depth + 1 < Protobuf.maximumDepth
        else { return }
        let inner = [UInt8](data)
        let decoder = WireDecoder(bytes: inner, schema: schema)
        guard let unpacked = decoder.message(0..<inner.count, type: type, depth: depth + 1) else { return }
        message.fields[index].value = .message(unpacked)
        message.fields[index].declaredType = type.name
    }
}
