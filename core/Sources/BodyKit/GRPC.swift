import Foundation

/// How a gRPC body is laid out: messages one after another, each after five bytes that say
/// whether it's compressed and how long it is.
public enum GRPCFraming: String, Hashable, Sendable {
    case grpc = "gRPC"
    /// gRPC-Web, which browsers can send. A response ends with the call's status, in a part
    /// of its own, since browsers can't read trailers.
    case grpcWeb = "gRPC-Web"
    /// gRPC-Web sent as base64 text.
    case grpcWebText = "gRPC-Web text"
    /// Connect's streaming calls, which end with a part in JSON that says how the call went.
    case connect = "Connect"

    /// The framing a `Content-Type` names, such as `application/grpc+proto`.
    public init?(contentType: String?) {
        guard let essence = MediaType(contentType)?.essence else { return nil }
        let base = essence.prefix { $0 != "+" }
        switch base {
        case "application/grpc": self = .grpc
        case "application/grpc-web": self = .grpcWeb
        case "application/grpc-web-text": self = .grpcWebText
        case "application/connect" where essence.contains("+"): self = .connect
        default: return nil
        }
    }

    /// Whether the messages of a `Content-Type` such as `application/grpc+json` are JSON
    /// instead of protobuf.
    public static func carriesJSON(_ contentType: String?) -> Bool {
        MediaType(contentType)?.essence.hasSuffix("+json") == true
    }
}

/// A body read as gRPC messages.
public struct GRPCBody: Hashable, Sendable {
    public struct Message: Hashable, Sendable {
        /// The message's bytes, unpacked when they came compressed.
        public var data: Data
        /// The message's size as it was sent, without its prefix.
        public var wireSize: Int
        public var wasCompressed: Bool
    }

    /// A field of the status gRPC-Web sends at the end of a response, such as `grpc-status`.
    public struct Field: Hashable, Sendable {
        public var name: String
        public var value: String
    }

    public var messages: [Message] = []
    public var trailers: [Field] = []
    /// The JSON part that ends a Connect stream.
    public var endOfStream: String?
    /// Bytes at the end that don't make a whole message yet, as while a stream goes on.
    public var incompleteBytes = 0
    /// Why some messages are shown as they came.
    public var problem: String?

    /// Reads a body framed for gRPC. `encoding` is the call's `grpc-encoding`, which says how
    /// compressed messages were packed.
    public static func read(_ data: Data, framing: GRPCFraming, encoding: String?) -> GRPCBody {
        var body = GRPCBody()
        let bytes: [UInt8]
        if framing == .grpcWebText {
            guard let decoded = decodeBase64Chunks(data) else {
                body.problem = "This body isn't the base64 text gRPC-Web sends."
                body.incompleteBytes = data.count
                return body
            }
            bytes = [UInt8](decoded)
        } else {
            bytes = [UInt8](data)
        }
        var index = 0
        while index < bytes.count {
            guard bytes.count - index >= 5 else { break }
            let flags = bytes[index]
            let length = bytes[(index + 1)...(index + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard bytes.count - index - 5 >= length else { break }
            let payload = Data(bytes[(index + 5)..<(index + 5 + length)])
            index += 5 + length
            let isWeb = framing == .grpcWeb || framing == .grpcWebText
            if isWeb, flags & 0x80 != 0 {
                body.trailers += headerLines(payload)
                continue
            }
            if framing == .connect, flags & 0x02 != 0 {
                body.endOfStream = String(decoding: payload, as: UTF8.self)
                continue
            }
            var message = Message(data: payload, wireSize: length, wasCompressed: flags & 0x01 != 0)
            if message.wasCompressed {
                let name = encoding?.trimmingCharacters(in: .whitespaces).lowercased() ?? "gzip"
                if let unpacked = BodyDecoder.decode(payload, contentEncoding: name) {
                    message.data = unpacked
                } else {
                    body.problem =
                        BodyDecoder.canDecode(name)
                        ? "Some messages are damaged, so they show as they came."
                        : "Reqly can't unpack messages compressed with \(name), so they show as they came."
                }
            }
            body.messages.append(message)
        }
        body.incompleteBytes = bytes.count - index
        return body
    }

    /// The base64 text of a gRPC-Web body, which may be several pieces of base64, each with
    /// its own padding, one after another.
    private static func decodeBase64Chunks(_ data: Data) -> Data? {
        let text = data.filter { !BodyKind.isWhitespace($0) }
        var decoded = Data()
        var start = text.startIndex
        var index = text.startIndex
        var count = 0
        while index < text.endIndex {
            count += 1
            index += 1
            // A piece ends with its padding, at the end of a group of four.
            let endsPiece = text[index - 1] == UInt8(ascii: "=") && count % 4 == 0
            if endsPiece || index == text.endIndex {
                guard let piece = Data(base64Encoded: Data(text[start..<index])) else { return nil }
                decoded.append(piece)
                start = index
                count = 0
            }
        }
        return decoded
    }

    /// Lines such as `grpc-status: 0`, split into names and values.
    private static func headerLines(_ payload: Data) -> [Field] {
        String(decoding: payload, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return Field(
                name: line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }
}
