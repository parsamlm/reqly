import CertificateAuthority
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
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

/// What either side sends right behind the HTTP that switches the connection to WebSocket, in the
/// same write, goes through as what comes later does. Over plain HTTP and inside decrypted tunnels.
@Suite(.timeLimit(.minutes(1))) struct WebSocketFirstBytesTests {
    /// A server that greets first, as chat and live-price servers do.
    @Test(arguments: [false, true]) func passesOnWhatTheServerSendsWithItsAnswer(decrypted: Bool) async throws {
        let greeting = frame(0x1, Array("welcome".utf8), isMasked: false)
        try await withWebSocketServer(decrypted: decrypted, greeting: greeting) { server, app, log in
            try await app.send(server.upgradeRequest(decrypted: decrypted))
            let received = await app.received.wait { $0.afterHead == greeting }
            #expect(received.text.hasPrefix("HTTP/1.1 101"))
            #expect(received.afterHead == greeting)
            let messages = try await log.wait { $0.contains { $0.webSocketMessage != nil } }
                .compactMap(\.webSocketMessage)
            #expect(messages.first?.direction == .received)
            #expect(messages.first?.text == "welcome")
        }
    }

    /// An app that sends its first message without waiting for the server's answer.
    @Test(arguments: [false, true]) func passesOnWhatTheAppSendsWithItsRequest(decrypted: Bool) async throws {
        let message = frame(0x1, Array("hello".utf8))
        try await withWebSocketServer(decrypted: decrypted) { server, app, log in
            try await app.send(bytes: Array(server.upgradeRequest(decrypted: decrypted).utf8) + message)
            let atServer = await server.received.wait { $0 == message }
            try #require(atServer == message)
            // The server sends it back, so the app has its answer and the message too.
            let atApp = await app.received.wait { $0.afterHead == message }
            #expect(atApp.afterHead == message)
            let messages = try await log.wait { $0.compactMap(\.webSocketMessage).count == 2 }
                .compactMap(\.webSocketMessage)
            #expect(messages.map(\.direction) == [.sent, .received])
            #expect(messages.map(\.text) == ["hello", "hello"])
        }
    }

    /// A server that turns the app away: it answers, says why, and closes at once. What it said
    /// reaches the app ahead of the close, and the Messages tab has it, slow network or not. The
    /// tunnel ends with the server, not when a TLS server gives up waiting for Reqly to close too.
    @Test(arguments: [false, true], [false, true])
    func passesOnWhatTheServerSendsBeforeItCloses(decrypted: Bool, slow: Bool) async throws {
        let goodbye =
            frame(0x1, Array("welcome".utf8), isMasked: false)
            + frame(0x8, [0x03, 0xF0] + Array("not allowed".utf8), isMasked: false)
        try await withWebSocketServer(decrypted: decrypted, slow: slow, greeting: goodbye, closes: true) {
            server, app, log in
            let start = ContinuousClock.now
            try await app.send(server.upgradeRequest(decrypted: decrypted))
            let received = await app.received.wait { $0.afterHead == goodbye }
            #expect(received.text.hasPrefix("HTTP/1.1 101"))
            #expect(received.afterHead == goodbye)
            let events = try await log.wait { $0.contains { $0.name == "tunnelClosed" } }
            // NIOSSL waits 5 seconds for the other side's close.
            #expect(ContinuousClock.now - start < .seconds(3))
            let messages = events.compactMap(\.webSocketMessage)
            #expect(messages.map(\.direction) == [.received, .received])
            #expect(messages.map(\.kind) == [.text, .close])
            #expect(messages.last?.closeCode == 1008)
            #expect(messages.last?.text == "not allowed")
        }
    }

    /// Runs `body` with a WebSocket server, and a connection to it through the proxy: plain, or
    /// over TLS in a tunnel the proxy decrypts, and over a slow network if `slow`.
    private func withWebSocketServer(
        decrypted: Bool,
        slow: Bool = false,
        greeting: [UInt8]? = nil,
        closes: Bool = false,
        _ body: (EchoingWebSocketServer, CollectingConnection, EventLog) async throws -> Void
    ) async throws {
        let rules = RuleSet(
            kindsOn: [.slowNetwork],
            network: NetworkConditions(
                profile: NetworkProfile(
                    name: "Far", downloadBytesPerSecond: nil, uploadBytesPerSecond: nil, latency: 300)))
        guard decrypted else {
            let server = try await EchoingWebSocketServer.start(greeting: greeting, closesAfterGreeting: closes)
            defer { Task { await server.stop() } }
            try await withHarness { harness in
                if slow {
                    harness.proxy.setRules(rules)
                }
                try await withCollectingConnection(port: harness.proxyPort) { app in
                    try await body(server, app, harness.log)
                }
            }
            return
        }
        try await withDecryptingHarness { harness in
            // The proxy trusts the website's root, so the WebSocket server's certificate comes from it too.
            let server = try await EchoingWebSocketServer.start(
                greeting: greeting, closesAfterGreeting: closes, tls: try testServerTLS(from: harness.origin.root))
            defer { Task { await server.stop() } }
            if slow {
                harness.proxy.setRules(rules)
            }
            try await harness.withSecureCollectingConnection(to: server.authority) { app in
                try await body(server, app, harness.log)
            }
        }
    }
}

/// TLS for a test server at 127.0.0.1 that speaks HTTP/1.1, with a certificate from `root`.
func testServerTLS(from root: RootIdentity) throws -> NIOSSLContext {
    let identity = try CertificateAuthority(root: root).identity(for: "127.0.0.1")
    var configuration = TLSConfiguration.makeServerConfiguration(
        certificateChain: try identity.certificateChain.map {
            .certificate(try NIOSSLCertificate(bytes: $0, format: .der))
        },
        privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem))
    )
    configuration.applicationProtocols = ["http/1.1"]
    return try NIOSSLContext(configuration: configuration)
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
    /// What the server got after the app's request, from every connection.
    let received: ReceivedBytes
    private let channel: any Channel

    private init(channel: any Channel, received: ReceivedBytes) {
        self.channel = channel
        self.received = received
        port = channel.localAddress!.port!
    }

    var authority: String { "127.0.0.1:\(port)" }

    /// An app's request to switch to WebSocket, sent to the proxy.
    var upgradeRequest: String { upgradeRequest(decrypted: false) }

    /// An app's request to switch to WebSocket: to the proxy, with the full URL, or inside a
    /// decrypted tunnel, with only the path.
    func upgradeRequest(decrypted: Bool) -> String {
        "GET \(decrypted ? "" : "http://\(authority)")/live HTTP/1.1\r\nHost: \(authority)\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    }

    /// - Parameters:
    ///   - extensions: What it answers in Sec-WebSocket-Extensions.
    ///   - greeting: Bytes it sends in the same write as its 101, as a server that speaks first does.
    ///   - closesAfterGreeting: Closes the connection right after its 101 and greeting.
    ///   - tls: Makes it a wss:// server.
    static func start(
        extensions: String? = nil, greeting: [UInt8]? = nil, closesAfterGreeting: Bool = false,
        tls: NIOSSLContext? = nil
    ) async throws -> EchoingWebSocketServer {
        let received = ReceivedBytes()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    if let tls {
                        try pipeline.addHandler(NIOSSLServerHandler(context: tls))
                    }
                    try pipeline.addHandler(
                        EchoingWebSocketHandler(
                            extensions: extensions, greeting: greeting, closesAfterGreeting: closesAfterGreeting,
                            received: received))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return EchoingWebSocketServer(channel: channel, received: received)
    }

    func stop() async {
        try? await channel.close()
    }
}

final class EchoingWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let extensions: String?
    private let greeting: [UInt8]?
    private let closesAfterGreeting: Bool
    private let received: ReceivedBytes
    private var request = ByteBuffer()
    private var hasUpgraded = false

    init(extensions: String?, greeting: [UInt8]?, closesAfterGreeting: Bool, received: ReceivedBytes) {
        self.extensions = extensions
        self.greeting = greeting
        self.closesAfterGreeting = closesAfterGreeting
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if hasUpgraded {
            received.append(buffer)
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
            return
        }
        request.writeBuffer(&buffer)
        guard let end = request.readableBytesView.firstRange(of: Array("\r\n\r\n".utf8)) else { return }
        hasUpgraded = true
        var response =
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
        if let extensions {
            response += "Sec-WebSocket-Extensions: \(extensions)\r\n"
        }
        // The greeting goes in the same write as the answer.
        var answer = ByteBuffer(string: response + "\r\n")
        answer.writeBytes(greeting ?? [])
        context.writeAndFlush(wrapOutboundOut(answer), promise: nil)
        guard !closesAfterGreeting else {
            context.close(promise: nil)
            return
        }
        // What the app sent along with its request, it gets back too.
        request.moveReaderIndex(forwardBy: end.upperBound - request.readableBytesView.startIndex)
        if request.readableBytes > 0 {
            received.append(request)
            context.writeAndFlush(wrapOutboundOut(request), promise: nil)
        }
        request = ByteBuffer()
    }
}
