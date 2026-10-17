import BodyKit
import Foundation
import ReqlyModel

/// A message as text, with its header names marked for coloring.
public struct RawMessage: Sendable {
    public private(set) var text = ""
    public private(set) var tokens: [SyntaxToken] = []

    /// About how many rows the text takes, with lines longer than 100 characters wrapping.
    public var rowCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().reduce(0) {
            $0 + max(1, ($1.count + 99) / 100)
        }
    }

    /// Bodies longer than this show only their start.
    public static let textLimit = 256 * 1024

    /// Whether secret header values, such as cookies, show as dots.
    private let hidesSecrets: Bool

    public init(request: RequestHead, body: Data, hidingSecrets: Bool) {
        hidesSecrets = hidingSecrets
        append(line: "\(request.method) \(request.target) \(request.version)")
        append(request.headers)
        append(body: body, headers: request.headers, tab: "Request")
    }

    public init(response: ResponseHead, body: Data, trailers: Headers?, hidingSecrets: Bool) {
        hidesSecrets = hidingSecrets
        append(line: "\(response.version) \(response.status) \(response.reason)".trimmingCharacters(in: .whitespaces))
        append(response.headers)
        append(body: body, headers: response.headers, tab: "Response")
        if let trailers, !trailers.isEmpty {
            append(line: "")
            append(trailers)
        }
    }

    private mutating func append(line: String) {
        text += line + "\n"
    }

    private mutating func append(_ headers: Headers) {
        for field in headers {
            let start = (text as NSString).length
            tokens.append(SyntaxToken(kind: .key, location: start, length: (field.name as NSString).length))
            let value = hidesSecrets && field.isSecret ? String(repeating: "•", count: 8) : field.value
            append(line: "\(field.name): \(value)")
        }
    }

    /// The body as text, or a line about it when it isn't text. Its own tab shows it in full.
    private mutating func append(body: Data, headers: Headers, tab: String) {
        guard !body.isEmpty else { return }
        append(line: "")
        let encoding = headers["Content-Encoding"].flatMap { $0.lowercased() == "identity" ? nil : $0 }
        let size = ByteCount.text(Int64(body.count))
        if let encoding {
            note("\(size) of \(encoding)-compressed data. The \(tab) tab shows it unpacked.")
            return
        }
        let kind = BodyKind.detect(body, contentType: headers["Content-Type"])
        switch kind {
        case .image, .protobuf, .grpc, .binary:
            note("\(size) of \(kind == .binary ? "binary" : kind.name) data. The \(tab) tab shows it.")
        default:
            let shown = body.prefix(Self.textLimit)
            // A cut can fall inside a character, so up to three bytes may need to go.
            guard
                let decoded = (0...3).lazy.compactMap({
                    BodyText.decode(shown.dropLast($0), contentType: headers["Content-Type"])
                }).first
            else {
                note("\(size) of binary data. The \(tab) tab shows it.")
                return
            }
            text += decoded.hasSuffix("\n") ? decoded : decoded + "\n"
            if body.count > shown.count {
                append(line: "")
                note("Shows the first \(ByteCount.text(Int64(shown.count))) of \(size).")
            }
        }
    }

    /// A line about the body, in place of bytes that aren't text.
    private mutating func note(_ words: String) {
        let start = (text as NSString).length
        let line = "‹\(words)›"
        tokens.append(SyntaxToken(kind: .comment, location: start, length: (line as NSString).length))
        append(line: line)
    }
}
