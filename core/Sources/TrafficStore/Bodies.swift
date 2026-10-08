import BodyKit
import Foundation
import ReqlyModel

/// Which of an exchange's two bodies.
public enum BodyPart: Int, Sendable, Hashable, CaseIterable {
    case request = 0
    case response = 1
}

/// Bytes that arrived for one body, to add to what the store already keeps of it.
public struct BodyChunk: Sendable, Hashable {
    public var exchange: ExchangeID
    public var part: BodyPart
    public var data: Data

    public init(exchange: ExchangeID, part: BodyPart, data: Data) {
        self.exchange = exchange
        self.part = part
        self.data = data
    }

    /// The chunks joined into one piece of data for each body, in the order each body first appears.
    static func merged(_ chunks: [BodyChunk]) -> [(key: BodyKey, data: Data)] {
        var order: [BodyKey] = []
        var joined: [BodyKey: Data] = [:]
        for chunk in chunks {
            let key = BodyKey(exchange: chunk.exchange, part: chunk.part)
            if joined[key] == nil {
                order.append(key)
                joined[key] = chunk.data
            } else {
                joined[key]!.append(chunk.data)
            }
        }
        return order.map { ($0, joined[$0]!) }
    }
}

struct BodyKey: Hashable {
    var exchange: ExchangeID
    var part: BodyPart

    /// The name of the body's file, for a body too big for the database.
    var fileName: String {
        "\(exchange.rawValue)-\(part == .request ? "request" : "response")"
    }
}

/// The text the search index keeps for an exchange.
enum SearchText {
    /// Content types that are never text, so their bodies aren't worth unpacking.
    private static let binaryTypes = [
        "image/", "audio/", "video/", "font/", "application/octet-stream", "application/pdf",
        "application/zip", "application/gzip", "application/grpc", "application/protobuf",
        "application/x-protobuf", "application/wasm",
    ]

    static func url(of exchange: Exchange) -> String {
        let request = exchange.request
        return request.url?.absoluteString ?? "\(request.scheme)://\(request.authority)\(request.target)"
    }

    /// The request line, the status line and every header, one per line.
    static func headers(of exchange: Exchange) -> String {
        let request = exchange.request
        var lines = ["\(request.method) \(request.target) \(request.version)"]
        lines += request.headers.map { "\($0.name): \($0.value)" }
        if let response = exchange.response {
            lines.append("\(response.version) \(response.status) \(response.reason)")
            lines += response.headers.map { "\($0.name): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Up to `limit` bytes of a body's text, unpacked, or `nil` when the body isn't text.
    static func body(_ data: Data, headers: Headers, limit: Int) -> String? {
        if let type = headers["Content-Type"]?.lowercased(), binaryTypes.contains(where: type.hasPrefix) {
            return nil
        }
        guard let unpacked = BodyDecoder.decode(data, contentEncoding: headers["Content-Encoding"]) else {
            return nil
        }
        // A cut at the limit may split a character, so up to three bytes may go.
        let isCut = unpacked.count > limit
        let kept = unpacked.prefix(limit)
        for trim in 0...(isCut ? 3 : 0) {
            if let text = String(data: kept.dropLast(trim), encoding: .utf8) {
                return text
            }
        }
        return nil
    }
}

/// A WebSocket message on its way to the store, with its place among its exchange's messages.
public struct StoredMessage: Sendable, Hashable {
    public var exchange: ExchangeID
    /// Counts from 0, in the order the messages went.
    public var number: Int
    public var message: WebSocketMessage

    public init(exchange: ExchangeID, number: Int, message: WebSocketMessage) {
        self.exchange = exchange
        self.number = number
        self.message = message
    }
}
