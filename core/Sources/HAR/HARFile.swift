import Foundation

/// The parts of a HAR 1.2 file that Reqly reads and writes. Reading is forgiving, since tools
/// leave out different fields; writing fills in every field the format requires.
///
/// The format: http://www.softwareishard.com/blog/har-12-spec/
struct HARFile: Codable {
    var log: Log

    struct Log: Codable {
        var version: String?
        var creator: Creator?
        var entries: [Entry]
    }

    struct Creator: Codable {
        var name: String
        var version: String
    }

    struct Entry: Codable {
        var startedDateTime: String
        /// Milliseconds, like every time in the file.
        var time: Double?
        var request: Request
        var response: Response
        var cache: Cache?
        var timings: Timings?
        var serverIPAddress: String?
        var connection: String?
        var comment: String?
        /// Why the request failed, in the custom field Chrome writes.
        var error: String?
        /// `websocket` for a WebSocket connection, as Chrome writes it.
        var resourceType: String?
        /// A WebSocket connection's messages, in the custom field Chrome writes.
        var webSocketMessages: [WebSocketMessage]?
        /// The name of the client certificate presented to the server, in a custom field Reqly adds.
        var clientCertificate: String?
        /// The reverse proxy the app sent the request to, such as `localhost:8080`, in a custom
        /// field Reqly adds.
        var reverseProxy: String?
        /// `true` for a request Reqly sent itself, such as one from the composer, in a custom field
        /// Reqly adds. Left out for an app's request.
        var sentByReqly: Bool?

        enum CodingKeys: String, CodingKey {
            case startedDateTime, time, request, response, cache, timings, serverIPAddress, connection, comment
            case error = "_error"
            case resourceType = "_resourceType"
            case webSocketMessages = "_webSocketMessages"
            case clientCertificate = "_clientCertificate"
            case reverseProxy = "_reverseProxy"
            case sentByReqly = "_sentByReqly"
        }
    }

    /// A WebSocket message the way Chrome writes it: `send` or `receive`, the time in seconds
    /// since 1970, the frame's opcode, and the data, in base64 for a binary message.
    struct WebSocketMessage: Codable {
        var type: String
        var time: Double
        var opcode: Int
        var data: String
        /// A close message's code, which Reqly adds.
        var closeCode: Int?

        enum CodingKeys: String, CodingKey {
            case type, time, opcode, data
            case closeCode = "_closeCode"
        }
    }

    struct Request: Codable {
        var method: String
        var url: String
        var httpVersion: String?
        var cookies: [Cookie]?
        var headers: [NameValue]?
        var queryString: [NameValue]?
        var postData: PostData?
        var headersSize: Int?
        var bodySize: Int?
    }

    struct Response: Codable {
        var status: Int
        var statusText: String?
        var httpVersion: String?
        var cookies: [Cookie]?
        var headers: [NameValue]?
        var content: Content?
        var redirectURL: String?
        var headersSize: Int?
        var bodySize: Int?
    }

    struct Content: Codable {
        /// The body's size once unpacked.
        var size: Int?
        /// Bytes saved by compression.
        var compression: Int?
        var mimeType: String?
        /// The unpacked body, as text or in base64.
        var text: String?
        var encoding: String?
    }

    struct PostData: Codable {
        var mimeType: String?
        var text: String?
        /// `base64` when the body isn't text. HAR 1.2 has no such field, so other tools ignore it.
        var encoding: String?
    }

    struct Timings: Codable {
        var blocked: Double?
        var dns: Double?
        var connect: Double?
        var send: Double?
        var wait: Double?
        var receive: Double?
        /// Also counted in `connect`, as the format asks.
        var ssl: Double?
    }

    struct Cookie: Codable {
        var name: String
        var value: String
        var path: String?
        var domain: String?
        var httpOnly: Bool?
        var secure: Bool?
    }

    struct NameValue: Codable {
        var name: String
        var value: String
    }

    struct Cache: Codable {}
}
