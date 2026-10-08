import Foundation

/// What a body holds, which decides how Reqly shows it.
public enum BodyKind: Hashable, Sendable {
    case json
    case xml
    case html
    /// A form sent as `application/x-www-form-urlencoded`.
    case form
    /// A form sent as `multipart/form-data`, with the boundary between its parts.
    case multipart(boundary: String)
    case image(ImageFormat)
    /// A protobuf message, as many APIs and Connect's simple calls send one.
    case protobuf
    /// gRPC messages, each with a prefix of its own.
    case grpc(GRPCFraming)
    /// Other text, such as plain text, JavaScript or CSS.
    case text
    case binary

    /// The name for the body's header, such as "JSON" or "PNG".
    public var name: String {
        switch self {
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .form: "Form"
        case .multipart: "Multipart form"
        case .image(let format): format.rawValue
        case .protobuf: "Protobuf"
        case .grpc(let framing): framing.rawValue
        case .text: "Text"
        case .binary: "Binary"
        }
    }

    /// Works out what an unpacked body holds. The `Content-Type` comes first, and the bytes
    /// decide when it's missing or too vague to tell.
    public static func detect(_ data: Data, contentType: String?) -> BodyKind {
        let type = MediaType(contentType)
        let essence = type?.essence ?? ""
        // Before JSON, since gRPC's JSON messages, as `application/grpc+json`, are framed too.
        if let framing = GRPCFraming(contentType: contentType) {
            return .grpc(framing)
        }
        if protobufTypes.contains(essence) {
            return .protobuf
        }
        if essence == "application/json" || essence == "text/json" || essence.hasSuffix("+json") {
            return .json
        }
        if essence == "application/x-www-form-urlencoded" {
            return .form
        }
        if essence == "multipart/form-data", let boundary = type?.parameters["boundary"], !boundary.isEmpty {
            return .multipart(boundary: boundary)
        }
        if essence == "image/svg+xml" {
            return .image(.svg)
        }
        if let format = ImageFormat(sniffing: data) {
            return .image(format)
        }
        if essence.hasPrefix("image/") {
            return .binary
        }
        if essence == "text/html" || essence == "application/xhtml+xml" {
            return .html
        }
        if essence == "application/xml" || essence == "text/xml" || essence.hasSuffix("+xml") {
            return .xml
        }
        let isVague = essence.isEmpty || essence == "text/plain" || essence == "application/octet-stream"
        if isVague, let sniffed = sniffText(data) {
            return sniffed
        }
        if essence.hasPrefix("text/") || Self.textTypes.contains(essence) {
            return .text
        }
        return isVague && BodyText.decode(data, contentType: contentType) != nil ? .text : .binary
    }

    private static let protobufTypes: Set<String> = [
        "application/x-protobuf", "application/protobuf", "application/x-google-protobuf",
        "application/vnd.google.protobuf", "application/proto", "application/x-proto",
    ]

    /// The message type a protobuf body's `Content-Type` names, as some servers say, such as
    /// `application/x-protobuf; messageType="weather.v1.Forecast"`.
    public static func protobufMessageType(_ contentType: String?) -> String? {
        let parameters = MediaType(contentType)?.parameters ?? [:]
        let name = parameters["messagetype"] ?? parameters["proto"] ?? parameters["type"]
        return name?.isEmpty == false ? name : nil
    }

    private static let textTypes: Set<String> = [
        "application/javascript", "application/ecmascript", "application/x-javascript", "application/graphql",
        "application/yaml", "application/x-yaml", "application/csv", "application/sql",
    ]

    /// JSON, XML or HTML recognized by how the text starts and ends.
    private static func sniffText(_ data: Data) -> BodyKind? {
        let bytes = data.prefix(512)
        guard let first = bytes.first(where: { !Self.isWhitespace($0) }) else { return nil }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            let last = data.suffix(64).last { !Self.isWhitespace($0) }
            let closes = first == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
            return last == closes ? .json : nil
        }
        guard first == UInt8(ascii: "<") else { return nil }
        let start = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") {
            return .html
        }
        if start.hasPrefix("<?xml") {
            return start.contains("<svg") ? .image(.svg) : .xml
        }
        if start.hasPrefix("<svg") {
            return .image(.svg)
        }
        return nil
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

/// The image formats Reqly recognizes.
public enum ImageFormat: String, Hashable, Sendable {
    case png = "PNG"
    case jpeg = "JPEG"
    case gif = "GIF"
    case webp = "WebP"
    case heic = "HEIC"
    case avif = "AVIF"
    case bmp = "BMP"
    case tiff = "TIFF"
    case icon = "ICO"
    case svg = "SVG"

    /// The format that the image's first bytes give away, or `nil`.
    init?(sniffing data: Data) {
        let bytes = [UInt8](data.prefix(16))
        func starts(with signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<offset + signature.count]) == signature
        }
        if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if starts(with: Array("GIF87a".utf8)) || starts(with: Array("GIF89a".utf8)) {
            self = .gif
        } else if starts(with: Array("RIFF".utf8)) && starts(with: Array("WEBP".utf8), at: 8) {
            self = .webp
        } else if starts(with: Array("ftyp".utf8), at: 4), bytes.count >= 12 {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            switch brand {
            case "avif", "avis": self = .avif
            case "heic", "heix", "heim", "heis", "mif1", "msf1": self = .heic
            default: return nil
            }
        } else if starts(with: [0x42, 0x4D]) {
            self = .bmp
        } else if starts(with: [0x49, 0x49, 0x2A, 0x00]) || starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            self = .tiff
        } else if starts(with: [0x00, 0x00, 0x01, 0x00]) {
            self = .icon
        } else {
            return nil
        }
    }
}

/// Turns bodies into text.
public enum BodyText {
    /// The body as text, in the charset its `Content-Type` names, or in UTF-8. It's `nil` when
    /// the bytes aren't text in that charset.
    public static func decode(_ data: Data, contentType: String?) -> String? {
        let charset = MediaType(contentType)?.parameters["charset"]?.lowercased()
        switch charset {
        case "iso-8859-1", "latin1", "latin-1", "iso_8859-1":
            return String(data: data, encoding: .isoLatin1)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252)
        case "utf-16":
            return String(data: data, encoding: .utf16)
        case "utf-16le":
            return String(data: data, encoding: .utf16LittleEndian)
        case "utf-16be":
            return String(data: data, encoding: .utf16BigEndian)
        case "shift_jis", "shift-jis", "sjis":
            return String(data: data, encoding: .shiftJIS)
        default:
            // Text never holds NUL bytes, and checking for them catches most binary data early.
            guard !data.prefix(4096).contains(0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}

/// A `Content-Type` value, split into its type and parameters.
struct MediaType {
    /// The type and subtype in lowercase, such as `application/json`.
    var essence: String
    /// Parameters by lowercase name, without quotes, such as `charset` and `boundary`.
    var parameters: [String: String]

    init?(_ header: String?) {
        guard let header else { return nil }
        let pieces = header.split(separator: ";", omittingEmptySubsequences: false)
        essence = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
        parameters = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            parameters[name] = value
        }
    }
}
