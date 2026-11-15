import Foundation

/// A WebSocket's frames, as RFC 6455 has them, for the self-check's test server and its client:
/// each one whole, never in pieces, since neither sends long messages.
enum WebSocketFrame {
    enum Opcode: UInt8, Sendable {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    struct Frame: Sendable {
        var opcode: Opcode
        var payload: [UInt8]
    }

    /// A whole frame with `payload`, masked as a client's must be, or not, as a server's are.
    static func encode(_ opcode: Opcode, _ payload: [UInt8], masked: Bool = false) -> [UInt8] {
        var frame: [UInt8] = [0x80 | opcode.rawValue]
        let mask: UInt8 = masked ? 0x80 : 0
        switch payload.count {
        case ..<126: frame.append(mask | UInt8(payload.count))
        case ..<65536: frame += [mask | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default: frame += [mask | 127] + (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
        }
        guard masked else { return frame + payload }
        let key = (0..<4).map { _ in UInt8.random(in: 0...255) }
        return frame + key + payload.enumerated().map { $1 ^ key[$0 % 4] }
    }

    /// The next frame on `wire`, unmasked, or `nil` once the connection ends, or a frame comes
    /// with an opcode no WebSocket has.
    static func read(from wire: HTTPWire) -> Frame? {
        guard let head = wire.bytes(2), let opcode = Opcode(rawValue: head[0] & 0x0F) else { return nil }
        var length = Int(head[1] & 0x7F)
        if length == 126 {
            guard let more = wire.bytes(2) else { return nil }
            length = Int(more[0]) << 8 | Int(more[1])
        } else if length == 127 {
            guard let more = wire.bytes(8) else { return nil }
            length = more.reduce(0) { $0 << 8 | Int($1) }
        }
        let key = head[1] & 0x80 != 0 ? wire.bytes(4) : nil
        if head[1] & 0x80 != 0, key == nil {
            return nil
        }
        guard let payload = wire.bytes(length) else { return nil }
        guard let key else { return Frame(opcode: opcode, payload: payload) }
        return Frame(opcode: opcode, payload: payload.enumerated().map { $1 ^ key[$0 % 4] })
    }

    /// The `Sec-WebSocket-Accept` a server answers `key` with: SHA-1 of the key and the RFC's
    /// GUID, in base64.
    static func accept(for key: String) -> String {
        Data(sha1(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// SHA-1, which a WebSocket's upgrade uses, and nothing else of the self-check does.
    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var padded = message + [0x80]
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        let bits = UInt64(message.count) * 8
        padded += (0..<8).reversed().map { UInt8((bits >> (UInt64($0) * 8)) & 0xFF) }
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            var w = (0..<16).map { index in
                (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(padded[chunk + index * 4 + $1]) }
            }
            for index in 16..<80 {
                let value = w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]
                w.append(value << 1 | value >> 31)
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for index in 0..<80 {
                let (f, k): (UInt32, UInt32) =
                    switch index {
                    case ..<20: ((b & c) | (~b & d), 0x5A82_7999)
                    case ..<40: (b ^ c ^ d, 0x6ED9_EBA1)
                    case ..<60: ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                    default: (b ^ c ^ d, 0xCA62_C1D6)
                    }
                let next = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[index]
                (e, d, c, b, a) = (d, c, b << 30 | b >> 2, a, next)
            }
            h = [h[0] &+ a, h[1] &+ b, h[2] &+ c, h[3] &+ d, h[4] &+ e]
        }
        return h.flatMap { word in (0..<4).reversed().map { UInt8((word >> (UInt32($0) * 8)) & 0xFF) } }
    }
}
