import Foundation

/// A message on a WebSocket connection, in one direction or the other.
public struct WebSocketMessage: Hashable, Sendable, Codable {
    public enum Direction: String, Hashable, Sendable, Codable {
        /// From the app to the server.
        case sent
        /// From the server to the app.
        case received
    }

    public enum Kind: String, Hashable, Sendable, Codable {
        case text, binary, close, ping, pong
    }

    public var direction: Direction
    public var kind: Kind
    public var time: Date
    /// What the message says, unpacked if the connection compresses messages. A message longer
    /// than Reqly keeps is cut short; `size` is its whole length.
    public var data: Data
    /// The message's length on the wire.
    public var size: Int
    /// A close message's code, such as 1000 for a normal close.
    public var closeCode: Int?

    public init(
        direction: Direction, kind: Kind, time: Date, data: Data, size: Int? = nil, closeCode: Int? = nil
    ) {
        self.direction = direction
        self.kind = kind
        self.time = time
        self.data = data
        self.size = size ?? data.count
        self.closeCode = closeCode
    }

    /// A text or close message's words, such as a close's reason.
    public var text: String? {
        switch kind {
        case .text, .close: String(data: data, encoding: .utf8)
        case .binary, .ping, .pong: nil
        }
    }
}
