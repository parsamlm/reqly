import Foundation
import NIOCore
import NIOPosix
import ProxyEngine
import ReqlyModel
import Testing

/// WebSocket connections: Reqly passes the bytes on untouched and reads each message as it goes.
@Suite(.timeLimit(.minutes(1))) struct WebSocketTests {
    @Test func readsEachMessageBothWays() async throws {
        let server = try await EchoingWebSocketServer.start(extensions: nil)
        defer { Task { await server.stop() } }
        try await withHarness { harness in
            try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send(server.upgradeRequest)
                #expect(try await app.read(through: "\r\n\r\n").hasPrefix("HTTP/1.1 101"))
                var frames: [UInt8] = []
                frames += frame(0x1, Array("hello".utf8))
                // A binary message in two pieces, with a ping between them.
                frames += frame(0x2, [1, 2, 3], isFinal: false)
                frames += frame(0x9, Array("p".utf8))
                frames += frame(0x0, [4, 5])
                frames += frame(0x8, [0x03, 0xE8] + Array("bye".utf8))
                try await app.send(bytes: frames)
                _ = try await harness.log.wait { $0.compactMap(\.webSocketMessage).count == 8 }
            }
            let events = try await harness.log.wait { $0.contains { $0.name == "tunnelClosed" } }
            let messages = events.compactMap(\.webSocketMessage)
            for direction in [WebSocketMessage.Direction.sent, .received] {
                let oneWay = messages.filter { $0.direction == direction }
                #expect(oneWay.map(\.kind) == [.text, .ping, .binary, .close])
                #expect(oneWay[0].text == "hello")
                #expect(oneWay[1].data == Data("p".utf8))
                #expect(oneWay[2].data == Data([1, 2, 3, 4, 5]))
                #expect(oneWay[3].closeCode == 1000)
                #expect(oneWay[3].text == "bye")
            }
            // The upgrade itself is the exchange, as before.
            #expect(events.compactMap(\.responseHead).first?.status == 101)
        }
    }

    @Test func unpacksCompressedMessages() async throws {
        let server = try await EchoingWebSocketServer.start(extensions: "permessage-deflate")
        defer { Task { await server.stop() } }
        // The second message refers back to the first, as permessage-deflate allows.
        let first: [UInt8] = [
            170, 86, 74, 206, 44, 169, 84, 178, 82, 114, 204, 45, 46, 73, 45, 74, 73, 204, 85, 210, 81, 42, 73, 205,
            45, 72, 45, 74, 44, 41, 45, 74, 85, 178, 50, 52, 209, 51, 170, 5, 0,
        ]
        let second: [UInt8] = [170, 38, 70, 153, 113, 45, 0]
        try await withHarness { harness in
            try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send(server.upgradeRequest)
                _ = try await app.read(through: "\r\n\r\n")
                try await app.send(
                    bytes: frame(0x1, first, isCompressed: true) + frame(0x1, second, isCompressed: true))
                _ = try await harness.log.wait { $0.compactMap(\.webSocketMessage).count == 4 }
            }
            let messages = try await harness.log.wait { $0.compactMap(\.webSocketMessage).count == 4 }
                .compactMap(\.webSocketMessage)
            #expect(
                messages.filter { $0.direction == .sent }.map(\.text) == [
                    #"{"city":"Amsterdam","temperature":14.2}"#, #"{"city":"Amsterdam","temperature":14.3}"#,
                ])
            #expect(messages.filter { $0.direction == .received }.compactMap(\.text).count == 2)
            // The size is what went over the wire.
            #expect(messages.first?.size == first.count)
        }
    }
}

/// A WebSocket frame. Frames from apps are masked, as WebSocket asks.
func frame(
    _ opcode: UInt8, _ payload: [UInt8], isFinal: Bool = true, isCompressed: Bool = false, isMasked: Bool = true
) -> [UInt8] {
    var bytes: [UInt8] = [(isFinal ? 0x80 : 0) | (isCompressed ? 0x40 : 0) | opcode]
    let mask: UInt8 = isMasked ? 0x80 : 0
    let length = payload.count
    if length < 126 {
        bytes.append(mask | UInt8(length))
    } else if length < 65_536 {
        bytes += [mask | 126, UInt8(length >> 8), UInt8(length & 0xFF)]
    } else {
        bytes.append(mask | 127)
        bytes += (0..<8).reversed().map { UInt8((length >> ($0 * 8)) & 0xFF) }
    }
    guard isMasked else { return bytes + payload }
    let key: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
    return bytes + key + payload.enumerated().map { $0.element ^ key[$0.offset % 4] }
}

extension RawConversation {
    func send(bytes: [UInt8]) async throws {
        try await outbound.write(ByteBuffer(bytes: bytes))
    }
}

/// A WebSocket server that agrees to the upgrade, then sends back every byte it gets.
final class EchoingWebSocketServer: Sendable {
    let port: Int
    private let channel: any Channel

    private init(channel: any Channel) {
        self.channel = channel
        port = channel.localAddress!.port!
    }

    /// An app's request to switch to WebSocket, sent to the proxy.
    var upgradeRequest: String {
        "GET http://127.0.0.1:\(port)/live HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    }

    static func start(extensions: String?) async throws -> EchoingWebSocketServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoingWebSocketHandler(extensions: extensions))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return EchoingWebSocketServer(channel: channel)
    }

    func stop() async {
        try? await channel.close()
    }
}

final class EchoingWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let extensions: String?
    private var request = ""
    private var hasUpgraded = false

    init(extensions: String?) {
        self.extensions = extensions
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if hasUpgraded {
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
            return
        }
        request += buffer.readString(length: buffer.readableBytes) ?? ""
        guard request.contains("\r\n\r\n") else { return }
        hasUpgraded = true
        var response =
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
        if let extensions {
            response += "Sec-WebSocket-Extensions: \(extensions)\r\n"
        }
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: response + "\r\n")), promise: nil)
    }
}
