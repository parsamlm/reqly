import BodyKit
import Foundation
import NIOCore
import NIOHTTP1
import ReqlyModel

/// What a server agreed to when it switched a connection to WebSocket.
struct WebSocketSettings: Equatable {
    /// Messages may be compressed with permessage-deflate.
    var compresses = false
    /// Each message from the server is compressed on its own, not against the ones before.
    var serverResetsContext = false
    /// Each message from the app is compressed on its own.
    var clientResetsContext = false

    /// The settings for a response that switches to WebSocket, or `nil` for any other response.
    init?(response head: HTTPResponseHead) {
        guard head.status == .switchingProtocols,
            head.headers["Upgrade"].contains(where: { $0.lowercased().contains("websocket") })
        else { return nil }
        let extensions = head.headers["Sec-WebSocket-Extensions"].joined(separator: ",").lowercased()
        // Such as `permessage-deflate; client_max_window_bits=15; server_no_context_takeover`.
        let deflate = extensions.split(separator: ",").first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("permessage-deflate")
        }
        if let deflate {
            compresses = true
            serverResetsContext = deflate.contains("server_no_context_takeover")
            clientResetsContext = deflate.contains("client_no_context_takeover")
        }
    }
}

/// Reads the WebSocket frames going one way over a connection, from copies of its bytes, and
/// puts its messages back together. The bytes themselves pass on untouched.
final class WebSocketReader {
    /// Each message's bytes are kept up to this. Its size counts all of them.
    static let messageLimit = 16 << 20
    /// A frame or a compressed message bigger than this stops the reading, so a connection
    /// can't fill the memory.
    static let frameLimit = 64 << 20

    private let direction: WebSocketMessage.Direction
    private let compresses: Bool
    private let resetsContext: Bool
    private var buffer = ByteBuffer()
    private var deflate: DeflateStream?
    /// The data message being put together from its frames.
    private var message: (kind: WebSocketMessage.Kind, data: Data, size: Int, isCompressed: Bool)?
    /// Something that isn't WebSocket came along, so nothing more is read.
    private var hasStopped = false

    init(direction: WebSocketMessage.Direction, settings: WebSocketSettings) {
        self.direction = direction
        compresses = settings.compresses
        resetsContext = direction == .sent ? settings.clientResetsContext : settings.serverResetsContext
    }

    /// Reads more bytes, and returns the messages they finish.
    func read(_ bytes: ByteBuffer, at time: Date) -> [WebSocketMessage] {
        guard !hasStopped else { return [] }
        var bytes = bytes
        buffer.writeBuffer(&bytes)
        var messages: [WebSocketMessage] = []
        while !hasStopped, let frame = nextFrame() {
            if let message = take(frame, at: time) {
                messages.append(message)
            }
        }
        buffer.discardReadBytes()
        return messages
    }

    private struct Frame {
        var isFinal: Bool
        /// Set on the first frame of a compressed message.
        var isCompressed: Bool
        var opcode: UInt8
        var payload: [UInt8]
    }

    private func nextFrame() -> Frame? {
        let start = buffer.readerIndex
        guard let first = buffer.getInteger(at: start, as: UInt8.self),
            let second = buffer.getInteger(at: start + 1, as: UInt8.self)
        else { return nil }
        var offset = 2
        var length = Int(second & 0x7F)
        if length == 126 {
            guard let extended = buffer.getInteger(at: start + 2, as: UInt16.self) else { return nil }
            length = Int(extended)
            offset = 4
        } else if length == 127 {
            guard let extended = buffer.getInteger(at: start + 2, as: UInt64.self) else { return nil }
            guard extended <= UInt64(Self.frameLimit) else {
                hasStopped = true
                return nil
            }
            length = Int(extended)
            offset = 10
        }
        guard length <= Self.frameLimit else {
            hasStopped = true
            return nil
        }
        var mask: [UInt8] = []
        if second & 0x80 != 0 {
            guard let key = buffer.getBytes(at: start + offset, length: 4) else { return nil }
            mask = key
            offset += 4
        }
        guard buffer.readableBytes >= offset + length,
            var payload = buffer.getBytes(at: start + offset, length: length)
        else { return nil }
        if !mask.isEmpty {
            for index in payload.indices {
                payload[index] ^= mask[index & 3]
            }
        }
        buffer.moveReaderIndex(forwardBy: offset + length)
        return Frame(
            isFinal: first & 0x80 != 0, isCompressed: first & 0x40 != 0, opcode: first & 0x0F, payload: payload)
    }

    /// Adds a frame to its message, and returns the message once it's whole. Control frames are
    /// messages of their own, even between the frames of another message.
    private func take(_ frame: Frame, at time: Date) -> WebSocketMessage? {
        switch frame.opcode {
        case 0x8:
            let code = frame.payload.count >= 2 ? Int(frame.payload[0]) << 8 | Int(frame.payload[1]) : nil
            let reason = Data(frame.payload.dropFirst(min(2, frame.payload.count)))
            return WebSocketMessage(
                direction: direction, kind: .close, time: time, data: reason, size: frame.payload.count, closeCode: code
            )
        case 0x9, 0xA:
            return WebSocketMessage(
                direction: direction, kind: frame.opcode == 0x9 ? .ping : .pong, time: time,
                data: Data(frame.payload))
        case 0x1, 0x2:
            message = (frame.opcode == 0x1 ? .text : .binary, Data(), 0, compresses && frame.isCompressed)
            return add(frame, at: time)
        case 0x0 where message != nil:
            return add(frame, at: time)
        default:
            hasStopped = true
            return nil
        }
    }

    private func add(_ frame: Frame, at time: Date) -> WebSocketMessage? {
        guard var current = message else { return nil }
        current.size += frame.payload.count
        // A compressed message is kept whole until it's unpacked; others only up to the limit.
        let room = (current.isCompressed ? Self.frameLimit : Self.messageLimit) - current.data.count
        if room < frame.payload.count, current.isCompressed {
            hasStopped = true
            return nil
        }
        current.data.append(contentsOf: frame.payload.prefix(max(room, 0)))
        guard frame.isFinal else {
            message = current
            return nil
        }
        message = nil
        var data = current.data
        if current.isCompressed {
            if deflate == nil || resetsContext {
                deflate = DeflateStream()
            }
            // A sender's sync flush ends with these four bytes, which permessage-deflate leaves out.
            data.append(contentsOf: [0x00, 0x00, 0xff, 0xff])
            guard let unpacked = deflate?.decompress(data, limit: Self.frameLimit) else {
                // Without its context, nothing after this unpacks either.
                hasStopped = true
                return WebSocketMessage(
                    direction: direction, kind: current.kind, time: time, data: current.data, size: current.size)
            }
            data = unpacked.prefix(Self.messageLimit)
        }
        return WebSocketMessage(direction: direction, kind: current.kind, time: time, data: data, size: current.size)
    }
}
