import Foundation

/// The message, enum and service types of `.proto` files, which give protobuf messages their
/// field names and types, and gRPC calls the types of their messages.
public struct ProtobufSchema: Hashable, Sendable {
    public struct Message: Hashable, Sendable {
        /// The full name, such as `weather.v1.Forecast`.
        public var name: String
        public var fields: [Int: Field]
        /// A map's entries are messages of their own, each with a key and a value.
        public var isMapEntry: Bool
    }

    public struct Field: Hashable, Sendable {
        public var name: String
        public var number: Int
        public var type: FieldType
        public var isRepeated: Bool
        /// The field is a proto2 group, sent between start and end markers.
        public var isGroup: Bool
    }

    public enum FieldType: Hashable, Sendable {
        case scalar(Scalar)
        /// A message type, by its full name.
        case message(String)
        /// An enum type, by its full name.
        case enumeration(String)

        /// The name as a `.proto` file has it, but in full: `int32`, or `weather.v1.Forecast`.
        public var name: String {
            switch self {
            case .scalar(let scalar): scalar.rawValue
            case .message(let name), .enumeration(let name): name
            }
        }
    }

    public enum Scalar: String, Hashable, Sendable, CaseIterable {
        case double, float, int64, uint64, int32, fixed64, fixed32, bool, string, bytes, uint32, sfixed32, sfixed64
        case sint32, sint64

        /// How a value of the type goes over the wire.
        var wireType: UInt8 {
            switch self {
            case .double, .fixed64, .sfixed64: 1
            case .float, .fixed32, .sfixed32: 5
            case .string, .bytes: 2
            default: 0
            }
        }
    }

    public struct Enum: Hashable, Sendable {
        public var name: String
        /// The name for each number. When names share a number, the first one.
        public var names: [Int32: String]
    }

    public struct Service: Hashable, Sendable {
        /// The full name, such as `weather.v1.Forecasts`.
        public var name: String
        public var methods: [Method]
    }

    public struct Method: Hashable, Sendable {
        public var name: String
        /// The full name of the request's message type.
        public var input: String
        /// The full name of the response's message type.
        public var output: String
        public var clientStreams: Bool
        public var serverStreams: Bool
    }

    public internal(set) var messages: [String: Message] = [:]
    public internal(set) var enums: [String: Enum] = [:]
    public internal(set) var services: [String: Service] = [:]
    /// The well-known types, which every schema has without any files.
    var builtInTypes: Set<String> = []

    public init() {}

    /// The message type with a full name, with or without its leading dot.
    public func message(named name: String) -> Message? {
        messages[name.hasPrefix(".") ? String(name.dropFirst()) : name]
    }

    /// The method a gRPC call's path names, such as `/weather.v1.Forecasts/Get`. The path may
    /// start with more, as when a server takes gRPC-Web calls under a path of its own.
    public func method(forPath path: String) -> Method? {
        let parts = path.split(separator: "?", maxSplits: 1).first?.split(separator: "/") ?? []
        guard parts.count >= 2, let service = services[String(parts[parts.count - 2])] else { return nil }
        return service.methods.first { $0.name == parts[parts.count - 1] }
    }

    /// The names of the message types the files define, sorted. The well-known types, and the
    /// map entries the files don't name, are left out.
    public var messageNames: [String] {
        messages.values.filter { !$0.isMapEntry && !builtInTypes.contains($0.name) }.map(\.name).sorted()
    }
}

/// Something in a `.proto` file that Reqly couldn't read or use.
public struct ProtoFileProblem: Hashable, Sendable {
    public var file: String
    public var line: Int
    public var message: String

    public init(file: String, line: Int, message: String) {
        self.file = file
        self.line = line
        self.message = message
    }
}

extension ProtobufSchema {
    /// The types in `.proto` files, given by name and text, with protobuf's well-known types,
    /// such as `google.protobuf.Timestamp`, which files import without having them. A field
    /// whose type can't be found is left out, so it's read as without a schema, and reported.
    public static func load(_ files: [(name: String, text: String)]) -> (
        schema: ProtobufSchema, problems: [ProtoFileProblem]
    ) {
        var builder = SchemaBuilder()
        builder.parse(name: "google/protobuf/well_known_types.proto", text: wellKnownTypes, isBuiltIn: true)
        for file in files {
            builder.parse(name: file.name, text: file.text, isBuiltIn: false)
        }
        return builder.build()
    }

    /// The well-known types, as Google's own files define them.
    private static let wellKnownTypes = """
        syntax = "proto3";
        package google.protobuf;
        message Timestamp { int64 seconds = 1; int32 nanos = 2; }
        message Duration { int64 seconds = 1; int32 nanos = 2; }
        message Empty {}
        message Any { string type_url = 1; bytes value = 2; }
        message FieldMask { repeated string paths = 1; }
        message Struct { map<string, Value> fields = 1; }
        message Value {
          oneof kind {
            NullValue null_value = 1; double number_value = 2; string string_value = 3; bool bool_value = 4;
            Struct struct_value = 5; ListValue list_value = 6;
          }
        }
        enum NullValue { NULL_VALUE = 0; }
        message ListValue { repeated Value values = 1; }
        message DoubleValue { double value = 1; }
        message FloatValue { float value = 1; }
        message Int64Value { int64 value = 1; }
        message UInt64Value { uint64 value = 1; }
        message Int32Value { int32 value = 1; }
        message UInt32Value { uint32 value = 1; }
        message BoolValue { bool value = 1; }
        message StringValue { string value = 1; }
        message BytesValue { bytes value = 1; }
        """
}

// MARK: - Reading .proto files

private struct ProtoToken {
    enum Kind { case identifier, number, string, symbol }
    var kind: Kind
    /// The token as written. For a string, its value without quotes or escapes.
    var text: String
    var line: Int
}

private struct ProtoSyntaxError: Error {
    var line: Int
    var message: String
}

/// Splits a `.proto` file into tokens, leaving out whitespace and comments.
private func protoTokens(_ text: String) throws(ProtoSyntaxError) -> [ProtoToken] {
    let bytes = Array(text.utf8)
    var tokens: [ProtoToken] = []
    var index = 0
    var line = 1
    func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F
    }
    while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case 0x0A:
            line += 1
            index += 1
        case 0x20, 0x09, 0x0D, 0x0C, 0x0B:
            index += 1
        case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
            while index < bytes.count, bytes[index] != 0x0A { index += 1 }
        case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "*"):
            let start = line
            index += 2
            while index < bytes.count,
                !(bytes[index] == UInt8(ascii: "*") && index + 1 < bytes.count
                    && bytes[index + 1] == UInt8(ascii: "/"))
            {
                if bytes[index] == 0x0A { line += 1 }
                index += 1
            }
            guard index < bytes.count else { throw ProtoSyntaxError(line: start, message: "A comment never ends.") }
            index += 2
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            let quote = byte
            let start = line
            index += 1
            var value: [UInt8] = []
            while index < bytes.count, bytes[index] != quote {
                if bytes[index] == 0x0A {
                    throw ProtoSyntaxError(line: start, message: "A string never ends.")
                }
                if bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count {
                    index += 1
                    switch bytes[index] {
                    case UInt8(ascii: "n"): value.append(0x0A)
                    case UInt8(ascii: "t"): value.append(0x09)
                    case UInt8(ascii: "r"): value.append(0x0D)
                    default: value.append(bytes[index])
                    }
                } else {
                    value.append(bytes[index])
                }
                index += 1
            }
            guard index < bytes.count else { throw ProtoSyntaxError(line: start, message: "A string never ends.") }
            index += 1
            tokens.append(ProtoToken(kind: .string, text: String(decoding: value, as: UTF8.self), line: start))
        case _ where byte >= 0x30 && byte <= 0x39:
            let start = index
            index += 1
            while index < bytes.count {
                let next = bytes[index]
                let isSign =
                    (next == UInt8(ascii: "+") || next == UInt8(ascii: "-"))
                    && (bytes[index - 1] | 0x20) == UInt8(ascii: "e") && (bytes[start + 1] | 0x20) != UInt8(ascii: "x")
                guard isIdentifierByte(next) || next == UInt8(ascii: ".") || isSign else { break }
                index += 1
            }
            tokens.append(
                ProtoToken(kind: .number, text: String(decoding: bytes[start..<index], as: UTF8.self), line: line))
        case _ where isIdentifierByte(byte):
            let start = index
            while index < bytes.count, isIdentifierByte(bytes[index]) { index += 1 }
            tokens.append(
                ProtoToken(kind: .identifier, text: String(decoding: bytes[start..<index], as: UTF8.self), line: line))
        case _ where byte < 0x80:
            tokens.append(ProtoToken(kind: .symbol, text: String(UnicodeScalar(byte)), line: line))
            index += 1
        default:
            throw ProtoSyntaxError(line: line, message: "There's a character Reqly doesn't expect here.")
        }
    }
    return tokens
}

/// A message as a file has it, before the types its fields name are found.
private struct ParsedMessage {
    var name: String
    /// Where its fields' type names are looked up from: the message itself.
    var scope: String
    var fields: [ParsedField]
    var isMapEntry: Bool
    var file: String
    var line: Int
}

private struct ParsedField {
    var name: String
    var number: Int
    /// A scalar's name, or a type name as written.
    var typeName: String
    var isRepeated: Bool
    var isGroup: Bool
    var line: Int
}

private struct ParsedExtension {
    /// The message the fields extend, as written.
    var target: String
    var scope: String
    var field: ParsedField
    var file: String
}

private struct ParsedService {
    var name: String
    var scope: String
    var methods: [(name: String, input: String, output: String, clientStreams: Bool, serverStreams: Bool, line: Int)]
    var file: String
}

/// Reads one file's tokens into messages, enums and services.
private struct ProtoParser {
    let tokens: [ProtoToken]
    let file: String
    var index = 0
    var package = ""
    var messages: [ParsedMessage] = []
    var enums: [(name: String, names: [Int32: String], line: Int)] = []
    var services: [ParsedService] = []
    var extensions: [ParsedExtension] = []

    init(tokens: [ProtoToken], file: String) {
        self.tokens = tokens
        self.file = file
    }

    private var current: ProtoToken? { index < tokens.count ? tokens[index] : nil }
    private var line: Int { current?.line ?? tokens.last?.line ?? 1 }

    private func error(_ message: String) -> ProtoSyntaxError {
        ProtoSyntaxError(line: line, message: message)
    }

    private func isNext(_ text: String) -> Bool {
        current?.kind != .string && current?.text == text
    }

    private mutating func take(_ text: String) -> Bool {
        guard isNext(text) else { return false }
        index += 1
        return true
    }

    private mutating func expect(_ text: String) throws(ProtoSyntaxError) {
        guard take(text) else {
            throw error(current.map { "Expected “\(text)” but found “\($0.text)”." } ?? "Expected “\(text)”.")
        }
    }

    private mutating func identifier() throws(ProtoSyntaxError) -> String {
        guard let token = current, token.kind == .identifier else { throw error("Expected a name.") }
        index += 1
        return token.text
    }

    /// A dotted name, such as `weather.v1.Forecast` or `.google.protobuf.Timestamp`.
    private mutating func typeName() throws(ProtoSyntaxError) -> String {
        var name = take(".") ? "." : ""
        name += try identifier()
        while take(".") {
            let part = try identifier()
            name += "." + part
        }
        return name
    }

    private mutating func integer() throws(ProtoSyntaxError) -> Int {
        let isNegative = take("-")
        guard let token = current, token.kind == .number else { throw error("Expected a number.") }
        index += 1
        let text = token.text.lowercased()
        let value: Int? =
            if text.hasPrefix("0x") {
                Int(text.dropFirst(2), radix: 16)
            } else if text.count > 1, text.hasPrefix("0") {
                Int(text.dropFirst(), radix: 8)
            } else {
                Int(text)
            }
        guard let value else { throw error("“\(token.text)” isn't a whole number.") }
        return isNegative ? -value : value
    }

    private mutating func string() throws(ProtoSyntaxError) -> String {
        guard let token = current, token.kind == .string else { throw error("Expected a string in quotes.") }
        index += 1
        var value = token.text
        // Strings next to each other join up.
        while let next = current, next.kind == .string {
            value += next.text
            index += 1
        }
        return value
    }

    /// Skips tokens up to and including the `;` that ends a statement, and anything in
    /// brackets or braces before it.
    private mutating func skipStatement() throws(ProtoSyntaxError) {
        var depth = 0
        while let token = current {
            index += 1
            guard token.kind == .symbol else { continue }
            switch token.text {
            case "{", "[", "(": depth += 1
            case "}", "]", ")":
                depth -= 1
                // An option's value in braces ends its statement without a `;`.
                if depth == 0, token.text == "}", !isNext(";") { return }
            case ";" where depth == 0: return
            default: break
            }
        }
        throw error("The file ends in the middle of a statement.")
    }

    /// Skips a field's options, such as `[packed = true, deprecated = true]`.
    private mutating func skipFieldOptions() throws(ProtoSyntaxError) {
        guard isNext("[") else { return }
        var depth = 0
        while let token = current {
            index += 1
            guard token.kind == .symbol else { continue }
            if token.text == "[" || token.text == "{" { depth += 1 }
            if token.text == "]" || token.text == "}" { depth -= 1 }
            if depth == 0 { return }
        }
        throw error("A field's options never end.")
    }

    mutating func parseFile() throws(ProtoSyntaxError) {
        while let token = current {
            switch token.text {
            case ";":
                index += 1
            case "syntax", "edition":
                index += 1
                try expect("=")
                _ = try string()
                try expect(";")
            case "package":
                index += 1
                package = try typeName()
                try expect(";")
            case "import":
                index += 1
                _ = take("weak") || take("public")
                _ = try string()
                try expect(";")
            case "option":
                try skipStatement()
            case "message":
                index += 1
                try parseMessage(in: package)
            case "enum":
                index += 1
                try parseEnum(in: package)
            case "service":
                index += 1
                try parseService()
            case "extend":
                index += 1
                try parseExtend(in: package)
            default:
                throw error("“\(token.text)” can't start a statement here.")
            }
        }
    }

    private func fullName(_ name: String, in scope: String) -> String {
        scope.isEmpty ? name : "\(scope).\(name)"
    }

    private mutating func parseMessage(in scope: String) throws(ProtoSyntaxError) {
        let start = line
        let name = try fullName(identifier(), in: scope)
        try expect("{")
        var message = ParsedMessage(name: name, scope: name, fields: [], isMapEntry: false, file: file, line: start)
        try parseMessageBody(into: &message)
        messages.append(message)
    }

    /// The fields and nested types of a message, up to its closing brace.
    private mutating func parseMessageBody(into message: inout ParsedMessage) throws(ProtoSyntaxError) {
        while !take("}") {
            guard let token = current else { throw error("A message never ends.") }
            switch token.text {
            case ";":
                index += 1
            case "message":
                index += 1
                try parseMessage(in: message.name)
            case "enum":
                index += 1
                try parseEnum(in: message.name)
            case "extend":
                index += 1
                try parseExtend(in: message.name)
            case "option", "reserved", "extensions":
                try skipStatement()
            case "oneof":
                index += 1
                _ = try identifier()
                try expect("{")
                while !take("}") {
                    if isNext("option") {
                        try skipStatement()
                    } else if take(";") {
                        continue
                    } else {
                        try parseField(into: &message, in: message.name)
                    }
                }
            case "map" where index + 1 < tokens.count && tokens[index + 1].text == "<":
                try parseMap(into: &message)
            default:
                try parseField(into: &message, in: message.name)
            }
        }
    }

    private mutating func parseField(into message: inout ParsedMessage, in scope: String) throws(ProtoSyntaxError) {
        let start = line
        var isRepeated = false
        if take("repeated") {
            isRepeated = true
        } else {
            _ = take("optional") || take("required")
        }
        if take("group") {
            // A group is a nested message type and a field of that type at once.
            let groupName = try identifier()
            try expect("=")
            let number = try integer()
            try skipFieldOptions()
            try expect("{")
            let typeName = fullName(groupName, in: scope)
            var group = ParsedMessage(
                name: typeName, scope: typeName, fields: [], isMapEntry: false, file: file, line: start)
            try parseMessageBody(into: &group)
            messages.append(group)
            message.fields.append(
                ParsedField(
                    name: groupName.lowercased(), number: number, typeName: "." + typeName, isRepeated: isRepeated,
                    isGroup: true, line: start))
            return
        }
        let type = try typeName()
        let name = try identifier()
        try expect("=")
        let number = try integer()
        try skipFieldOptions()
        try expect(";")
        message.fields.append(
            ParsedField(name: name, number: number, typeName: type, isRepeated: isRepeated, isGroup: false, line: start)
        )
    }

    /// A map field, such as `map<string, Forecast> forecasts = 3;`, is sent as repeated
    /// entries, each a message with the key as field 1 and the value as field 2.
    private mutating func parseMap(into message: inout ParsedMessage) throws(ProtoSyntaxError) {
        let start = line
        try expect("map")
        try expect("<")
        let keyType = try typeName()
        try expect(",")
        let valueType = try typeName()
        try expect(">")
        let name = try identifier()
        try expect("=")
        let number = try integer()
        try skipFieldOptions()
        try expect(";")
        let entryName = fullName(
            name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() + "Entry",
            in: message.name)
        messages.append(
            ParsedMessage(
                name: entryName, scope: message.name,
                fields: [
                    ParsedField(
                        name: "key", number: 1, typeName: keyType, isRepeated: false, isGroup: false, line: start),
                    ParsedField(
                        name: "value", number: 2, typeName: valueType, isRepeated: false, isGroup: false, line: start),
                ],
                isMapEntry: true, file: file, line: start))
        message.fields.append(
            ParsedField(
                name: name, number: number, typeName: "." + entryName, isRepeated: true, isGroup: false, line: start))
    }

    private mutating func parseEnum(in scope: String) throws(ProtoSyntaxError) {
        let start = line
        let name = try fullName(identifier(), in: scope)
        try expect("{")
        var names: [Int32: String] = [:]
        while !take("}") {
            guard let token = current else { throw error("An enum never ends.") }
            switch token.text {
            case ";": index += 1
            case "option", "reserved": try skipStatement()
            default:
                let value = try identifier()
                try expect("=")
                let number = try integer()
                try skipFieldOptions()
                try expect(";")
                if names[Int32(truncatingIfNeeded: number)] == nil {
                    names[Int32(truncatingIfNeeded: number)] = value
                }
            }
        }
        enums.append((name, names, start))
    }

    private mutating func parseService() throws(ProtoSyntaxError) {
        let name = try fullName(identifier(), in: package)
        try expect("{")
        var service = ParsedService(name: name, scope: package, methods: [], file: file)
        while !take("}") {
            guard let token = current else { throw error("A service never ends.") }
            switch token.text {
            case ";": index += 1
            case "option": try skipStatement()
            case "rpc":
                let start = line
                index += 1
                let method = try identifier()
                try expect("(")
                let clientStreams = take("stream")
                let input = try typeName()
                try expect(")")
                try expect("returns")
                try expect("(")
                let serverStreams = take("stream")
                let output = try typeName()
                try expect(")")
                if take("{") {
                    while !take("}") {
                        guard current != nil else { throw error("A method never ends.") }
                        if take(";") { continue }
                        try skipStatement()
                    }
                } else {
                    try expect(";")
                }
                service.methods.append((method, input, output, clientStreams, serverStreams, start))
            default:
                throw error("“\(token.text)” can't be in a service.")
            }
        }
        services.append(service)
    }

    private mutating func parseExtend(in scope: String) throws(ProtoSyntaxError) {
        let target = try typeName()
        try expect("{")
        var holder = ParsedMessage(name: scope, scope: scope, fields: [], isMapEntry: false, file: file, line: line)
        while !take("}") {
            guard current != nil else { throw error("An extend block never ends.") }
            if take(";") { continue }
            try parseField(into: &holder, in: scope)
        }
        for field in holder.fields {
            extensions.append(ParsedExtension(target: target, scope: scope, field: field, file: file))
        }
    }
}

/// Collects the files' types, then finds the types each field names.
private struct SchemaBuilder {
    private var messages: [ParsedMessage] = []
    private var enums: [String: ProtobufSchema.Enum] = [:]
    private var services: [ParsedService] = []
    private var extensions: [ParsedExtension] = []
    private var problems: [ProtoFileProblem] = []
    /// Where each type came from, to tell when two files define the same one.
    private var origins: [String: String] = [:]
    private var builtInTypes: Set<String> = []

    mutating func parse(name: String, text: String, isBuiltIn: Bool) {
        var parser: ProtoParser
        do {
            parser = ProtoParser(tokens: try protoTokens(text), file: name)
            try parser.parseFile()
        } catch {
            problems.append(ProtoFileProblem(file: name, line: error.line, message: error.message))
            return
        }
        for message in parser.messages where claim(message.name, file: name, line: message.line, isBuiltIn: isBuiltIn) {
            messages.append(message)
        }
        for item in parser.enums where claim(item.name, file: name, line: item.line, isBuiltIn: isBuiltIn) {
            enums[item.name] = ProtobufSchema.Enum(name: item.name, names: item.names)
        }
        services += parser.services
        extensions += parser.extensions
    }

    /// Whether a type is new. The well-known types come first, and a file's own copies of
    /// them are left out quietly.
    private mutating func claim(_ name: String, file: String, line: Int, isBuiltIn: Bool) -> Bool {
        if let origin = origins[name] {
            if !builtInTypes.contains(name) {
                problems.append(
                    ProtoFileProblem(
                        file: file, line: line,
                        message: "\(name) is already defined in \(origin), so this one is left out."
                    ))
            }
            return false
        }
        origins[name] = file
        if isBuiltIn {
            builtInTypes.insert(name)
        }
        return true
    }

    /// The full name of the message or enum that `name` refers to from `scope`. Protobuf looks
    /// in the innermost scope first, then each one around it.
    private func resolve(_ name: String, from scope: String, in known: Set<String>) -> String? {
        if name.hasPrefix(".") {
            let full = String(name.dropFirst())
            return known.contains(full) ? full : nil
        }
        var scope = scope
        while true {
            let candidate = scope.isEmpty ? name : "\(scope).\(name)"
            if known.contains(candidate) { return candidate }
            guard !scope.isEmpty else { return nil }
            scope = scope.lastIndex(of: ".").map { String(scope[..<$0]) } ?? ""
        }
    }

    private mutating func field(_ parsed: ParsedField, scope: String, file: String, known: Set<String>)
        -> ProtobufSchema.Field?
    {
        let type: ProtobufSchema.FieldType
        if let scalar = ProtobufSchema.Scalar(rawValue: parsed.typeName) {
            type = .scalar(scalar)
        } else if let full = resolve(parsed.typeName, from: scope, in: known) {
            type = enums[full] != nil ? .enumeration(full) : .message(full)
        } else {
            problems.append(
                ProtoFileProblem(
                    file: file, line: parsed.line,
                    message:
                        "Reqly can't find the type \(parsed.typeName), so the field \(parsed.name) shows by its number. Add the file that defines the type, too."
                ))
            return nil
        }
        return ProtobufSchema.Field(
            name: parsed.name, number: parsed.number, type: type, isRepeated: parsed.isRepeated,
            isGroup: parsed.isGroup)
    }

    mutating func build() -> (schema: ProtobufSchema, problems: [ProtoFileProblem]) {
        let known = Set(messages.map(\.name)).union(enums.keys)
        var schema = ProtobufSchema()
        schema.enums = enums
        schema.builtInTypes = builtInTypes
        for parsed in messages {
            var message = ProtobufSchema.Message(name: parsed.name, fields: [:], isMapEntry: parsed.isMapEntry)
            for parsedField in parsed.fields {
                if let field = field(parsedField, scope: parsed.scope, file: parsed.file, known: known) {
                    message.fields[field.number] = field
                }
            }
            schema.messages[parsed.name] = message
        }
        for item in extensions {
            guard let target = resolve(item.target, from: item.scope, in: known), schema.messages[target] != nil,
                var field = field(item.field, scope: item.scope, file: item.file, known: known)
            else { continue }
            // Text format names an extension by its full name, in brackets.
            field.name = "[\(item.scope.isEmpty ? field.name : "\(item.scope).\(field.name)")]"
            schema.messages[target]?.fields[field.number] = field
        }
        for parsed in services {
            var service = ProtobufSchema.Service(name: parsed.name, methods: [])
            for method in parsed.methods {
                guard let input = resolve(method.input, from: parsed.scope, in: known),
                    let output = resolve(method.output, from: parsed.scope, in: known)
                else {
                    problems.append(
                        ProtoFileProblem(
                            file: parsed.file, line: method.line,
                            message:
                                "Reqly can't find the message types of \(method.name), so its calls are read without them. Add the files that define them, too."
                        ))
                    continue
                }
                service.methods.append(
                    ProtobufSchema.Method(
                        name: method.name, input: input, output: output, clientStreams: method.clientStreams,
                        serverStreams: method.serverStreams))
            }
            schema.services[parsed.name] = service
        }
        let sorted = problems.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        return (schema, sorted)
    }
}
