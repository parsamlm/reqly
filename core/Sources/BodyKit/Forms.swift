import Foundation

/// One field of a form.
public struct FormField: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Reads forms sent as `application/x-www-form-urlencoded`, and query strings, which look the same.
public enum URLEncodedForm {
    /// The fields in the order they were sent, decoded. A plus sign stands for a space.
    public static func fields(_ text: String) -> [FormField] {
        text.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return FormField(name: decode(parts[0]), value: parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    private static func decode(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

/// One part of a form sent as `multipart/form-data`.
public struct MultipartPart: Hashable, Sendable {
    /// The part's headers by lowercase name, such as `content-type`.
    public var headers: [String: String]
    public var body: Data

    /// The form field's name, from `Content-Disposition`.
    public var name: String? { disposition["name"] }
    /// The uploaded file's name, for a part that holds a file.
    public var filename: String? { disposition["filename"] }
    public var contentType: String? { headers["content-type"] }

    private var disposition: [String: String] {
        MediaType(headers["content-disposition"])?.parameters ?? [:]
    }
}

/// Reads forms sent as `multipart/form-data`.
public enum MultipartForm {
    /// The parts between the boundaries, in order. A form cut short keeps the parts it has.
    public static func parts(_ data: Data, boundary: String) -> [MultipartPart] {
        let bytes = [UInt8](data)
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [MultipartPart] = []
        guard var position = find(delimiter, in: bytes, from: 0) else { return [] }
        while true {
            position += delimiter.count
            // Two hyphens after a boundary end the form.
            if position + 2 <= bytes.count, bytes[position] == 0x2D, bytes[position + 1] == 0x2D {
                break
            }
            guard let headersStart = find([0x0D, 0x0A], in: bytes, from: position),
                let headersEnd = find([0x0D, 0x0A, 0x0D, 0x0A], in: bytes, from: headersStart)
            else { break }
            let bodyStart = headersEnd + 4
            let next = find([0x0D, 0x0A] + delimiter, in: bytes, from: bodyStart)
            let bodyEnd = next ?? bytes.count
            parts.append(
                MultipartPart(
                    headers: headers(String(decoding: bytes[headersStart + 2..<headersEnd], as: UTF8.self)),
                    body: Data(bytes[bodyStart..<bodyEnd])
                ))
            guard let next else { break }
            position = next + 2
        }
        return parts
    }

    private static func headers(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard let first = needle.first, needle.count <= haystack.count else { return nil }
        var index = start
        while index + needle.count <= haystack.count {
            if haystack[index] == first, haystack[index..<index + needle.count].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }
}

/// Lays bytes out the way hex editors do: an offset, sixteen bytes in hex, and the same bytes as text.
public enum HexDump {
    public static let bytesPerRow = 16

    public static func rowCount(forSize size: Int) -> Int {
        (size + bytesPerRow - 1) / bytesPerRow
    }

    /// The row at `index`: its offset, its bytes in hex in two groups of eight, and its bytes as
    /// text, with a dot for each byte that isn't printable ASCII.
    public static func row(_ index: Int, of data: Data) -> (offset: String, hex: String, text: String) {
        let start = data.startIndex + index * bytesPerRow
        let end = min(start + bytesPerRow, data.endIndex)
        let bytes = start < end ? data[start..<end] : Data()
        var hex = ""
        var text = ""
        for (position, byte) in bytes.enumerated() {
            if position == 8 {
                hex += " "
            }
            hex += hexDigits[Int(byte >> 4)]
            hex += hexDigits[Int(byte & 0x0F)]
            hex += " "
            text.append((0x20..<0x7F).contains(byte) ? Character(Unicode.Scalar(byte)) : ".")
        }
        let offset = String(index * bytesPerRow, radix: 16, uppercase: true)
        return (String(repeating: "0", count: max(0, 8 - offset.count)) + offset, String(hex.dropLast()), text)
    }

    private static let hexDigits = Array("0123456789ABCDEF").map(String.init)
}
