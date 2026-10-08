import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ReqlyModel
import Synchronization
import Testing

@testable import ProxyEngine

/// An upstream proxy: Reqly sends its connections to servers through another proxy, as some
/// networks ask.
@Suite(.timeLimit(.minutes(1))) struct UpstreamProxyTests {
    func through(_ upstream: TestUpstreamProxy, username: String? = nil, password: String? = nil) -> UpstreamProxy {
        UpstreamProxy(
            host: "127.0.0.1", port: upstream.port, username: username, password: password,
            bypassesLocalAddresses: false)
    }

    @Test func sendsPlainHTTPToTheProxyWithTheWholeURL() async throws {
        let upstream = try await TestUpstreamProxy.start(credentials: "reqly:secret")
        defer { Task { await upstream.stop() } }
        try await withHarness { harness in
            harness.proxy.sendLoopbackUpstream(true)
            harness.proxy.setUpstreamProxy(through(upstream, username: "reqly", password: "secret"))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.body == "via upstream: GET \(harness.originURL)/hello HTTP/1.1")
            #expect(upstream.requests.map(\.authorization) == ["Basic cmVxbHk6c2VjcmV0"])
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.upstreamProxy) == ["127.0.0.1:\(upstream.port)"])
        }
    }

    @Test func opensTunnelsThroughTheProxy() async throws {
        let upstream = try await TestUpstreamProxy.start()
        defer { Task { await upstream.stop() } }
        try await withHarness { harness in
            harness.proxy.sendLoopbackUpstream(true)
            harness.proxy.setUpstreamProxy(through(upstream))
            let reply = try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send("CONNECT 127.0.0.1:\(harness.origin.port) HTTP/1.1\r\n\r\n")
                let opened = try await app.read(through: "\r\n\r\n")
                try await app.send("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                return opened + (try await app.readToEnd())
            }
            #expect(reply.hasPrefix("HTTP/1.1 200"))
            #expect(reply.hasSuffix("hello"))
            #expect(upstream.requests.map(\.line) == ["CONNECT 127.0.0.1:\(harness.origin.port) HTTP/1.1"])
        }
    }

    @Test func decryptsWhatGoesThroughTheProxysTunnel() async throws {
        let upstream = try await TestUpstreamProxy.start()
        defer { Task { await upstream.stop() } }
        try await withDecryptingHarness(http2Origin: true) { harness in
            harness.proxy.sendLoopbackUpstream(true)
            harness.proxy.setUpstreamProxy(through(upstream))
            let multiplexer = try await harness.openSecureConnection(inside: .http2)
            let response = try await sendOverStream(
                multiplexer, .GET, "/version", authority: harness.origin.authority)
            // The server's HTTP/2 goes through the tunnel too.
            #expect(response.body == "HTTP/2.0")
            #expect(upstream.requests.map(\.line) == ["CONNECT \(harness.origin.authority) HTTP/1.1"])
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.serverProtocol) == ["HTTP/2"])
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test func saysWhenTheProxyWantsToKnowWhoYouAre() async throws {
        let upstream = try await TestUpstreamProxy.start(credentials: "reqly:secret")
        defer { Task { await upstream.stop() } }
        try await withHarness { harness in
            harness.proxy.sendLoopbackUpstream(true)
            for (password, words) in [(nil, "asks for a user name and password"), ("wrong", "didn't accept")] {
                harness.proxy.setUpstreamProxy(
                    through(upstream, username: password == nil ? nil : "reqly", password: password))
                let reply = try await withRawConnection(port: harness.proxyPort) { app in
                    try await app.send("CONNECT 127.0.0.1:\(harness.origin.port) HTTP/1.1\r\n\r\n")
                    return try await app.readToEnd()
                }
                #expect(reply.hasPrefix("HTTP/1.1 502"))
                #expect(reply.contains(words))
            }
            let failures = try await harness.log.wait { $0.compactMap(\.failure).count == 2 }.compactMap(\.failure)
            guard case .cannotConnect(let reason) = failures.first else {
                Issue.record("Expected a connection failure, got \(failures)")
                return
            }
            #expect(
                reason
                    == "the upstream proxy at 127.0.0.1:\(upstream.port) asks for a user name and password. Add them in Settings, under Upstream Proxy."
            )
        }
    }

    @Test func reachesBypassedHostsDirectly() async throws {
        let upstream = try await TestUpstreamProxy.start()
        defer { Task { await upstream.stop() } }
        try await withHarness { harness in
            harness.proxy.sendLoopbackUpstream(true)
            var proxy = through(upstream)
            proxy.bypass = [HostPattern(rawValue: "localhost")!]
            harness.proxy.setUpstreamProxy(proxy)
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "http://localhost:\(harness.origin.port)/hello")
            }
            #expect(response.body == "hello")
            #expect(upstream.requests.isEmpty)
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.upstreamProxy).isEmpty)
        }
    }

    @Test func saysWhenTheProxyIsntThere() async throws {
        let port = refusingPort
        try await withHarness { harness in
            harness.proxy.sendLoopbackUpstream(true)
            harness.proxy.setUpstreamProxy(UpstreamProxy(host: "127.0.0.1", port: port, bypassesLocalAddresses: false))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.status == 502)
            let failures = try await harness.log.wait { $0.contains { $0.failure != nil } }.compactMap(\.failure)
            #expect(failures == [.cannotConnect("the upstream proxy at 127.0.0.1:\(port) refused the connection.")])
        }
    }

    @Test func sendsComposedRequestsThroughTheProxy() async throws {
        let upstream = try await TestUpstreamProxy.start()
        defer { Task { await upstream.stop() } }
        try await withHarness { harness in
            harness.proxy.sendLoopbackUpstream(true)
            harness.proxy.setUpstreamProxy(through(upstream))
            _ = harness.proxy.send(OutgoingRequest(method: "GET", url: URL(string: "\(harness.originURL)/hello")!))
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            let body = events.compactMap(\.responseData).reduce(Data(), +)
            #expect(String(decoding: body, as: UTF8.self) == "via upstream: GET \(harness.originURL)/hello HTTP/1.1")
            #expect(events.compactMap(\.upstreamProxy) == ["127.0.0.1:\(upstream.port)"])
        }
    }

    @Test func leavesThisMacAndLocalAddressesAlone() {
        let proxy = UpstreamProxy(
            host: "proxy.example.com", port: 8080, bypass: [HostPattern(rawValue: "*.corp.example.com")!])
        for host in [
            "localhost", "127.0.0.1", "::1", "printer.local", "192.168.1.20", "10.0.0.5", "172.20.1.1",
            "intranet.corp.example.com", "fd12::1",
        ] {
            #expect(proxy.bypasses(host), "\(host)")
        }
        for host in ["api.weatherly.dev", "8.8.8.8", "172.32.0.1", "corp.example.com"] {
            #expect(!proxy.bypasses(host), "\(host)")
        }
        #expect(proxy.authorization == nil)
        #expect(UpstreamProxy(host: "p", port: 1, username: "a", password: "b").authorization == "Basic YTpi")
        #expect(UpstreamProxy(host: "::1", port: 3128).address == "[::1]:3128")
    }
}

/// An HTTP proxy to send Reqly's traffic through. It opens tunnels with `CONNECT`, answers
/// other requests itself by telling what it got, and can ask for a user name and password.
final class TestUpstreamProxy: Sendable {
    struct Request: Sendable {
        /// Such as `CONNECT 127.0.0.1:443 HTTP/1.1`.
        var line: String
        var authorization: String?
    }

    final class Log: Sendable {
        let requests = Mutex<[Request]>([])
    }

    let port: Int
    private let channel: any Channel
    private let log: Log

    var requests: [Request] { log.requests.withLock { $0 } }

    private init(channel: any Channel, log: Log) {
        self.channel = channel
        self.log = log
        port = channel.localAddress!.port!
    }

    /// - Parameter credentials: Such as `user:password`, to ask for.
    static func start(credentials: String? = nil) async throws -> TestUpstreamProxy {
        let log = Log()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        TestUpstreamHandler(credentials: credentials, log: log))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return TestUpstreamProxy(channel: channel, log: log)
    }

    func stop() async {
        try? await channel.close()
    }
}

private final class TestUpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let credentials: String?
    private let log: TestUpstreamProxy.Log
    private var head = ""
    private var server: (any Channel)?
    private var isDone = false

    init(credentials: String?, log: TestUpstreamProxy.Log) {
        self.credentials = credentials
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        if let server {
            server.writeAndFlush(bytes, promise: nil)
            return
        }
        guard !isDone else { return }
        head += String(buffer: bytes)
        guard let end = head.range(of: "\r\n\r\n") else { return }
        isDone = true
        let lines = head[..<end.lowerBound].components(separatedBy: "\r\n")
        let line = lines[0]
        let authorization = lines.dropFirst().first { $0.lowercased().hasPrefix("proxy-authorization:") }
            .map { String($0.dropFirst("proxy-authorization:".count)).trimmingCharacters(in: .whitespaces) }
        log.requests.withLock { $0.append(TestUpstreamProxy.Request(line: line, authorization: authorization)) }
        if let credentials, authorization != "Basic " + Data(credentials.utf8).base64EncodedString() {
            let refusal =
                "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"test\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            close(after: refusal, context: context)
            return
        }
        let parts = line.split(separator: " ")
        guard parts.first == "CONNECT", parts.count == 3, let colon = parts[1].lastIndex(of: ":"),
            let port = Int(parts[1][parts[1].index(after: colon)...])
        else {
            let body = "via upstream: \(line)"
            close(
                after: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)",
                context: context)
            return
        }
        let host = String(parts[1][..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let app = context.channel
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Relay(to: app))
                }
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .success(let server):
                    handler.value.server = server
                    app.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection established\r\n\r\n"), promise: nil)
                case .failure:
                    app.writeAndFlush(ByteBuffer(string: "HTTP/1.1 502 Bad Gateway\r\n\r\n")).whenComplete { _ in
                        app.close(promise: nil)
                    }
                }
            }
    }

    private func close(after reply: String, context: ChannelHandlerContext) {
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: reply))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        server?.close(promise: nil)
        context.fireChannelInactive()
    }
}

/// Passes what one side of a tunnel reads on to the other.
private final class Relay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let partner: any Channel

    init(to partner: any Channel) {
        self.partner = partner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner.close(promise: nil)
        context.fireChannelInactive()
    }
}
