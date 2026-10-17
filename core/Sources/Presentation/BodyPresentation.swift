import BodyKit
import Foundation
import ReqlyModel

/// The ways to look at a body. Which ones a body offers depends on what it holds.
public enum BodyMode: Hashable, Sendable {
    case formatted, tree, raw, preview, form, hex
}

/// What reading a protobuf body takes: the types of the `.proto` files, and which of them the
/// body holds, when that's known.
public struct ProtobufReading: Sendable {
    public var schema: ProtobufSchema
    /// The request's path, which names a gRPC call's method, such as `/weather.v1.Forecasts/Get`.
    public var path: String?
    public var isRequest: Bool
    /// The message type chosen for bodies like this one.
    public var chosenType: String?

    public init(schema: ProtobufSchema, path: String?, isRequest: Bool, chosenType: String?) {
        self.schema = schema
        self.path = path
        self.isRequest = isRequest
        self.chosenType = chosenType
    }

    /// The type to read a message as: the one chosen, the one the method takes or returns,
    /// or the one the `Content-Type` names. `nil` reads it without a schema.
    public func messageType(contentType: String?) -> String? {
        if let chosenType, schema.message(named: chosenType) != nil {
            return chosenType
        }
        if let path, let method = schema.method(forPath: path) {
            return isRequest ? method.input : method.output
        }
        if let named = BodyKind.protobufMessageType(contentType), schema.message(named: named) != nil {
            return named
        }
        return nil
    }
}

/// A body made ready to show: unpacked, recognized, and laid out for each way of viewing it.
/// It's made in the background, since formatting a big body takes a moment.
public struct BodyPresentation: Sendable {
    /// Text past this isn't shown, so the view stays quick.
    public static let displayLimit = 16 << 20
    /// Bodies past this aren't formatted, shown as a tree or read as forms.
    public static let formatLimit = 8 << 20

    public private(set) var kind: BodyKind
    /// The body as the app received it: unpacked when it came compressed.
    public private(set) var content: Data
    public private(set) var wireSize: Int
    /// The encoding the body was unpacked from, such as gzip.
    public private(set) var unpackedFrom: String?
    /// Why the body is shown differently than its type suggests, such as JSON that isn't valid.
    public private(set) var note: String?
    public private(set) var modes: [BodyMode] = [.hex]
    public private(set) var formatted: Code?
    public private(set) var raw: Code?
    public private(set) var tree: (any ValueOutline)?
    public private(set) var fields: [FormField]?
    public private(set) var parts: [MultipartPart]?
    /// Whether the text stops at ``displayLimit``.
    public private(set) var isTruncated = false
    /// The body was read as protobuf messages.
    public private(set) var readsAsProtobuf = false
    /// The message type a protobuf body was read as, or `nil` when it was read without one.
    public private(set) var protobufType: String?
    /// How many messages a gRPC body holds.
    public private(set) var messageCount: Int?
    /// The status at the end of a gRPC-Web response.
    public private(set) var grpcStatus: GRPCStatus?
    /// More to say below the body, such as a stream that's still going.
    public private(set) var details: [String] = []

    /// Text to show in a code view, with its line count, which sets the view's height.
    public struct Code: Sendable {
        public private(set) var text: String
        public private(set) var tokens: [SyntaxToken]
        public private(set) var isCode: Bool
        /// How many rows the text takes. Code keeps its lines whole; plain text wraps, about
        /// every hundred characters in a detail pane of usual width.
        public private(set) var rowCount: Int

        public init(_ text: String, tokens: [SyntaxToken] = [], isCode: Bool = true) {
            self.text = text
            // Coloring a very long body would take too long.
            self.tokens = text.utf16.count <= HighlightedText.highlightLimit ? tokens : []
            self.isCode = isCode
            var rows = 0
            var lineLength = 0
            for byte in text.utf8 {
                if byte == 0x0A {
                    rows += isCode ? 1 : max(1, (lineLength + 99) / 100)
                    lineLength = 0
                } else if byte & 0xC0 != 0x80 {
                    lineLength += 1
                }
            }
            rowCount = rows + (isCode ? 1 : max(1, (lineLength + 99) / 100))
        }

        public init(_ highlighted: HighlightedText) {
            self.init(highlighted.text, tokens: highlighted.tokens)
        }
    }

    public init(data: Data, headers: Headers, rootLabel: String, protobuf: ProtobufReading? = nil) {
        wireSize = data.count
        let encoding = headers["Content-Encoding"].flatMap { $0.lowercased() == "identity" ? nil : $0 }
        content = data
        if let encoding {
            if let unpacked = BodyDecoder.decode(data, contentEncoding: encoding) {
                content = unpacked
                unpackedFrom = encoding
            } else {
                note = "Reqly can't unpack \(encoding), or the body is cut short, so it shows the bytes as they came."
                kind = .binary
                return
            }
        }
        let contentType = headers["Content-Type"]
        kind = BodyKind.detect(content, contentType: contentType)
        if case .image = kind {
            modes = [.preview, .hex]
            return
        }
        if kind == .binary {
            return
        }
        if kind == .protobuf || GRPCFraming(contentType: contentType) != nil {
            readProtobuf(headers: headers, rootLabel: rootLabel, reading: protobuf)
            return
        }
        guard let text = text(contentType: contentType) else {
            kind = .binary
            return
        }
        let canFormat = content.count <= Self.formatLimit
        switch kind {
        case .json:
            raw = Code(text, tokens: JSONSyntax.tokens(in: text))
            if canFormat {
                do {
                    let value = try JSONValue.parse(content)
                    formatted = Code(value.formatted())
                    tree = JSONTree(value, rootLabel: rootLabel)
                    modes = [.formatted, .tree, .raw, .hex]
                } catch let error as JSONError {
                    note = "This isn't valid JSON: \(error.message)"
                    modes = [.raw, .hex]
                } catch {
                    modes = [.raw, .hex]
                }
            } else {
                modes = [.raw, .hex]
            }
        case .xml:
            raw = Code(text, tokens: MarkupSyntax.tokens(in: text))
            if canFormat {
                let laidOut = MarkupSyntax.formattedXML(text)
                formatted = Code(laidOut, tokens: MarkupSyntax.tokens(in: laidOut))
                modes = [.formatted, .raw, .hex]
            } else {
                modes = [.raw, .hex]
            }
        case .html:
            raw = Code(text, tokens: MarkupSyntax.tokens(in: text))
            modes = [.raw, .hex]
        case .form:
            raw = Code(text, isCode: false)
            fields = URLEncodedForm.fields(text)
            modes = [.form, .raw, .hex]
        case .multipart(let boundary):
            parts = canFormat ? MultipartForm.parts(content, boundary: boundary) : nil
            modes = parts == nil ? [.hex] : [.form, .hex]
        default:
            raw = Code(text, isCode: false)
            modes = [.raw, .hex]
        }
    }

    /// A protobuf message, or gRPC's messages, as text format and as a tree.
    private mutating func readProtobuf(headers: Headers, rootLabel: String, reading: ProtobufReading?) {
        let contentType = headers["Content-Type"]
        guard content.count <= Self.formatLimit else {
            note = "This body is too big to read as protobuf, so it shows as bytes."
            return
        }
        let schema = reading?.schema ?? ProtobufSchema()
        let type = reading?.messageType(contentType: contentType)
        guard let framing = GRPCFraming(contentType: contentType) else {
            guard let message = Protobuf.decode(content, as: type, schema: schema) else {
                note = "This isn't a protobuf message Reqly can read, so it shows as bytes."
                return
            }
            formatted = Code(message.formatted())
            tree = ProtobufTree(message, rootLabel: rootLabel)
            protobufType = message.typeName
            readsAsProtobuf = true
            modes = [.formatted, .tree, .hex]
            return
        }

        let body = GRPCBody.read(content, framing: framing, encoding: headers["grpc-encoding"])
        messageCount = body.messages.count
        note = body.problem
        if !body.trailers.isEmpty {
            grpcStatus = GRPCStatus(fields: Headers(body.trailers.map { HeaderField(name: $0.name, value: $0.value) }))
        }
        if let end = body.endOfStream {
            details.append("The stream ended with \(end)")
        }
        if body.incompleteBytes > 0 {
            details.append("The body ends partway through a message. It shows once the rest of it arrives.")
        }
        guard !body.messages.isEmpty else { return }
        if GRPCFraming.carriesJSON(contentType) {
            // gRPC can carry JSON messages instead of protobuf ones.
            let values = body.messages.map {
                (try? JSONValue.parse($0.data)) ?? .string(String(decoding: $0.data, as: UTF8.self))
            }
            let value = values.count == 1 ? values[0] : .array(values)
            formatted = Code(value.formatted())
            tree = JSONTree(value, rootLabel: rootLabel)
            modes = [.formatted, .tree, .hex]
            return
        }
        let messages = body.messages.map { Protobuf.decode($0.data, as: type, schema: schema) ?? .unreadable($0.data) }
        formatted = Code(ProtobufMessage.formatted(messages, sizes: body.messages.map(\.wireSize)))
        tree = ProtobufTree(messages: messages, rootLabel: rootLabel)
        protobufType = type
        readsAsProtobuf = true
        modes = [.formatted, .tree, .hex]
    }

    /// The body as text, up to the display limit. A cut at the limit may split a character, so
    /// up to three bytes may go.
    private mutating func text(contentType: String?) -> String? {
        if case .multipart = kind {
            return ""
        }
        isTruncated = content.count > Self.displayLimit
        let shown = content.prefix(Self.displayLimit)
        for trim in 0...(isTruncated ? 3 : 0) {
            if let text = BodyText.decode(shown.dropLast(trim), contentType: contentType) {
                return text
            }
        }
        return nil
    }

    /// The text the copy button copies in a given mode.
    public func copyableText(in mode: BodyMode) -> String? {
        switch mode {
        case .formatted, .tree: (formatted ?? raw)?.text
        case .raw, .form: raw?.text
        case .preview, .hex: nil
        }
    }
}
