import BodyKit
import Foundation
import ReqlyModel

/// A request or a response held at a breakpoint, as the editor shows it, and the message to go
/// on with once you've edited it. The Mac's paused editor and the Windows app's work the same.
public struct PausedEdit: Sendable {
    public struct Header: Hashable, Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let original: PausedMessage
    /// The name of the breakpoint's rule.
    public let breakpoint: String
    public var method = ""
    public var url = ""
    public var status = ""
    public var reason = ""
    public var headers: [Header] = []
    public var body = ""
    /// A body that isn't text. It goes on as it was.
    public let binaryBody: Data?
    /// The headers as they were, to mark the ones you change.
    public let originalHeaders: [Header]
    /// The body's text as the editor first showed it. A body still the same goes on byte for byte.
    private let originalText: String

    /// Reqly sets these from the body as the message goes on, so they aren't for editing.
    public static let framingHeaders: Set<String> = ["content-length", "transfer-encoding"]

    public init(_ message: PausedMessage, breakpoint: String) {
        original = message
        self.breakpoint = breakpoint
        let fields: Headers
        let data: Data
        switch message {
        case .request(let request, let body):
            method = request.method
            url = request.url?.absoluteString ?? ""
            (fields, data) = (request.headers, body)
        case .response(let response, let body):
            status = String(response.status)
            reason = response.reason
            (fields, data) = (response.headers, body)
        }
        let editable = fields.filter { !Self.framingHeaders.contains($0.name.lowercased()) }
            .map { Header(name: $0.name, value: $0.value) }
        headers = editable
        originalHeaders = editable
        let contentType = fields["Content-Type"]
        if data.isEmpty {
            binaryBody = nil
            originalText = ""
        } else if let text = BodyText.decode(data, contentType: contentType) {
            // JSON is easier to edit laid out.
            let shown =
                BodyKind.detect(data, contentType: contentType) == .json
                ? ((try? JSONValue.parse(data))?.formatted().text ?? text) : text
            body = shown
            binaryBody = nil
            originalText = shown
        } else {
            binaryBody = data
            originalText = ""
        }
    }

    public var part: MessagePart { original.part }

    /// Why an edited message can't go on.
    public enum Problem: Error, Hashable, Sendable {
        case url
        case status

        public var message: String {
            switch self {
            case .url: "Enter a URL that starts with http:// or https://."
            case .status: "Enter a status from 100 to 599."
            }
        }
    }

    /// The body to go on with: the original bytes unless you changed the text.
    private var editedBody: Data {
        switch original {
        case .request(_, let data), .response(_, let data):
            if let binaryBody { return binaryBody }
            return body == originalText ? data : Data(body.utf8)
        }
    }

    private var editedHeaders: Headers {
        Headers(
            headers.compactMap { header in
                let name = header.name.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : HeaderField(name: name, value: header.value)
            })
    }

    /// The message as you edited it, or what to fix.
    public func edited() throws(Problem) -> PausedMessage {
        switch original {
        case .request(let request, _):
            guard let url = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
                let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                let host = url.host, !host.isEmpty
            else { throw .url }
            var edited = request
            edited.method = method
            edited.scheme = scheme
            edited.host = host.lowercased()
            edited.port = url.port ?? (scheme == "https" ? 443 : 80)
            let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
            edited.target = url.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
            var fields = editedHeaders
            // The Host header follows the URL to another server, unless you set it yourself.
            if edited.authority != request.authority, fields["Host"] == request.authority {
                fields = Headers(
                    fields.map {
                        $0.name.lowercased() == "host" ? HeaderField(name: $0.name, value: edited.authority) : $0
                    })
            }
            edited.headers = fields
            return .request(edited, body: editedBody)
        case .response(let response, _):
            guard let code = Int(status.trimmingCharacters(in: .whitespaces)), (100...599).contains(code) else {
                throw .status
            }
            var edited = response
            edited.status = code
            edited.reason = reason
            edited.headers = editedHeaders
            return .response(edited, body: editedBody)
        }
    }
}
