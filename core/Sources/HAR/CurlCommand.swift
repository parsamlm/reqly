import Foundation
import ReqlyModel

/// Makes a cURL command that sends a request again, for pasting into a terminal.
public enum CurlCommand {
    /// The command for `request` with `body`. Headers that curl sets itself, such as
    /// `Content-Length`, are left out, and a compressed response is unpacked with `--compressed`.
    public static func make(_ request: RequestHead, body: Data) -> String {
        var options: [String] = []
        switch (request.method, body.isEmpty) {
        case ("GET", true), ("POST", false):
            break
        case ("HEAD", true):
            options.append("--head")
        default:
            options.append("-X \(quoted(request.method))")
        }
        var compressed = false
        for field in request.headers {
            let name = field.name.lowercased()
            if name == "accept-encoding" {
                compressed = true
            } else if !skippedHeaders.contains(name), !(name == "host" && field.value == request.authority) {
                options.append("-H \(quoted("\(field.name): \(field.value)"))")
            }
        }
        if !body.isEmpty {
            if let text = String(data: body, encoding: .utf8) {
                options.append("--data-raw \(quoted(text))")
            } else {
                options.append("--data-binary \(ansiQuoted(body))")
            }
        }
        if compressed {
            options.append("--compressed")
        }
        let url = request.url?.absoluteString ?? "\(request.scheme)://\(request.authority)\(request.target)"
        return (["curl \(quoted(url))"] + options).joined(separator: " \\\n  ")
    }

    /// Headers curl works out itself, and the ones only a single connection uses.
    private static let skippedHeaders: Set<String> = [
        "content-length", "connection", "proxy-connection", "keep-alive", "transfer-encoding", "upgrade",
    ]

    /// Single quotes keep everything as it is, in any shell. A quote inside ends the quoting,
    /// adds an escaped quote, and starts it again.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Bytes that aren't text, written with escapes in `$'…'`, which bash and zsh understand.
    static func ansiQuoted(_ data: Data) -> String {
        var result = "$'"
        for byte in data {
            switch byte {
            case UInt8(ascii: "\\"): result += "\\\\"
            case UInt8(ascii: "'"): result += "\\'"
            case UInt8(ascii: "\n"): result += "\\n"
            case UInt8(ascii: "\r"): result += "\\r"
            case UInt8(ascii: "\t"): result += "\\t"
            case 0x20...0x7E: result.append(Character(Unicode.Scalar(byte)))
            default: result += String(format: "\\x%02x", byte)
            }
        }
        return result + "'"
    }
}
