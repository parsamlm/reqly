import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ProxyEngine
import ReqlyModel
import Synchronization
import Testing

enum TestError: Error {
    case connectionClosed
    case timedOut
    case noFreePort
}

/// A proxy and a small website to send traffic to, started fresh for each test.
struct Harness {
    let proxy: ProxyServer
    let proxyPort: Int
    let origin: OriginServer
    let log: EventLog

    /// Where the test website lives, as an absolute URL for proxy requests.
    var originURL: String { "http://127.0.0.1:\(origin.port)" }
}

func withHarness(
    group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    _ body: (Harness) async throws -> Void
) async throws {
    let proxy = ProxyServer(group: group)
    let log = EventLog(proxy.events)
    let proxyPort = try await proxy.start(ProxyServer.Configuration(port: 0))
    let origin = try await OriginServer.start()
    do {
        try await body(Harness(proxy: proxy, proxyPort: proxyPort, origin: origin, log: log))
    } catch {
        await proxy.stop()
        await origin.stop()
        throw error
    }
    await proxy.stop()
    await origin.stop()
}

/// A port that refuses connections. Nothing listens on port 1, and the system never hands it to
/// a test's own listener, as it might a port that was only free when it was picked.
let refusingPort = 1

/// How long a test waits for what it expects before it fails. On a busy CI machine, running
/// the whole suite at once can hold a test up for several seconds.
let waitLimit = Duration.seconds(30)

/// Waits until `condition` holds, checking every 10 ms.
func waitUntil(timeout: Duration = waitLimit, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// The ports `freePort()` has handed out, so no two tests get the same one.
private let handedOutPorts = Mutex<Set<Int>>([])

/// A port that's free to listen on, for a test's own listener. It comes from 20000–29999, below
/// the ranges the system picks from for port 0 and for outgoing connections (32768 and up on
/// Linux, 49152 and up on the Mac), so no other test's listener or connection takes it before
/// the test listens on it.
func freePort() async throws -> Int {
    for _ in 0..<200 {
        let port = Int.random(in: 20_000..<30_000)
        guard handedOutPorts.withLock({ $0.insert(port).inserted }) else { continue }
        if let channel = try? await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: port)
            .get()
        {
            try await channel.close()
            return port
        }
    }
    throw TestError.noFreePort
}

// MARK: - The test website

/// A tiny HTTP server that plays the part of a real website.
final class OriginServer: Sendable {
    let port: Int
    private let channel: any Channel

    private init(channel: any Channel) {
        self.channel = channel
        self.port = channel.localAddress!.port!
    }

    static func start() async throws -> OriginServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(OriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return OriginServer(channel: channel)
    }

    func stop() async {
        try? await channel.close()
    }
}

final class OriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()
        case .body(var buffer):
            body.writeBuffer(&buffer)
        case .end:
            if let head {
                respond(to: head, context: context)
            }
        }
    }

    private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
        switch head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri {
        case "/hello":
            send("hello", context: context, withBody: head.method != .HEAD, thenClose: !head.isKeepAlive)
        case "/echo":
            send(String(buffer: body), headers: ["X-Method": head.method.rawValue], context: context)
        case "/chunked":
            let responseHead = HTTPResponseHead(
                version: .http1_1, status: .ok, headers: ["Transfer-Encoding": "chunked"])
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            for piece in ["a", "b", "c"] {
                context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: piece)))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        case "/close":
            send("bye", headers: ["Connection": "close"], context: context, thenClose: true)
        case "/no-content":
            // As Google answers its logging pings: 204, with a Content-Length of 0.
            send(
                "", status: .noContent,
                headers: ["Content-Type": "text/html; charset=UTF-8", "Alt-Svc": "h3=\":443\"; ma=2592000"],
                context: context)
        case "/request-header":
            // Tells what a rule did to the request on its way.
            send(head.headers["X-Rewritten"].first ?? "missing", context: context)
        case "/bytes":
            // As many bytes as `n` asks for, then closes when `close=1`, for slow network.
            let query = URLComponents(string: head.uri)?.queryItems ?? []
            let count = query.first { $0.name == "n" }?.value.flatMap(Int.init) ?? 0
            let close = query.contains { $0.name == "close" && $0.value == "1" }
            send(
                String(repeating: "x", count: count), headers: close ? ["Connection": "close"] : [:],
                context: context, thenClose: close)
        case "/version":
            // Tells which version of HTTP the request came over.
            send("HTTP/\(head.version.major).\(head.version.minor)", context: context)
        case "/trailers":
            // Answers as gRPC does: the body, then the status in trailers.
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .ok))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "ok")))), promise: nil)
            context.writeAndFlush(
                wrapOutboundOut(.end(["grpc-status": "0", "grpc-message": "fine"])), promise: nil)
        case "/host":
            // Tells which Host the request named.
            send(head.headers["Host"].first ?? "missing", context: context)
        case "/redirect":
            // Sends the app to /hello, by its full URL, as many servers do.
            let host = head.headers["Host"].first ?? "missing"
            send("", status: .found, headers: ["Location": "http://\(host)/hello?from=redirect"], context: context)
        case "/cookies":
            // Tells which Cookie headers arrived, one per line.
            send(head.headers["Cookie"].joined(separator: "\n"), context: context)
        case "/chunked-close":
            // As some CDNs answer a request that asks to close: chunked, then closed right away.
            let responseHead = HTTPResponseHead(
                version: .http1_1, status: .ok, headers: ["Transfer-Encoding": "chunked", "Connection": "close"])
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "bye")))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in
                context.close(promise: nil)
            }
        default:
            send("not found", status: .notFound, context: context)
        }
    }

    private func send(
        _ text: String,
        status: HTTPResponseStatus = .ok,
        headers extra: HTTPHeaders = [:],
        context: ChannelHandlerContext,
        withBody: Bool = true,
        thenClose: Bool = false
    ) {
        var headers = extra
        headers.add(name: "Content-Length", value: String(text.utf8.count))
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        if withBody {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
        }
        let written = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: written)
        if thenClose {
            written.futureResult.assumeIsolated().whenComplete { _ in context.close(promise: nil) }
        }
    }
}

// MARK: - Clients that act like apps

struct TestResponse: Sendable {
    var status: Int
    var headers: HTTPHeaders
    var data: Data
    var trailers: HTTPHeaders?

    var body: String { String(decoding: data, as: UTF8.self) }
}

/// Opens a connection to the proxy and talks HTTP on it, the way an app would.
func withProxyConnection<Result: Sendable>(
    port: Int,
    _ body: (inout HTTPConversation) async throws -> Result
) async throws -> Result {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(
                    wrappingChannelSynchronously: channel
                )
            }
        }
    return try await channel.executeThenClose { inbound, outbound in
        var conversation = HTTPConversation(inbound: inbound.makeAsyncIterator(), outbound: outbound)
        return try await body(&conversation)
    }
}

struct HTTPConversation {
    var inbound: NIOAsyncChannelInboundStream<HTTPClientResponsePart>.AsyncIterator
    let outbound: NIOAsyncChannelOutboundWriter<HTTPClientRequestPart>

    mutating func send(
        _ method: HTTPMethod,
        _ uri: String,
        headers extra: HTTPHeaders = [:],
        body: String? = nil
    ) async throws -> TestResponse {
        var headers = extra
        if let body {
            headers.add(name: "Content-Length", value: String(body.utf8.count))
        }
        var parts: [HTTPClientRequestPart] = [
            .head(HTTPRequestHead(version: .http1_1, method: method, uri: uri, headers: headers))
        ]
        if let body {
            parts.append(.body(.byteBuffer(ByteBuffer(string: body))))
        }
        parts.append(.end(nil))
        // In one write, as apps send a request, so a proxy that answers and closes as soon as it
        // has read the head never finds the rest still to be written.
        try await outbound.write(contentsOf: parts)
        return try await readResponse()
    }

    mutating func readResponse() async throws -> TestResponse {
        var head: HTTPResponseHead?
        var body = ByteBuffer()
        while let part = try await inbound.next() {
            switch part {
            case .head(let received):
                head = received
            case .body(var buffer):
                body.writeBuffer(&buffer)
            case .end(let trailers):
                guard let head else { throw TestError.connectionClosed }
                return TestResponse(
                    status: Int(head.status.code), headers: head.headers, data: Data(body.readableBytesView),
                    trailers: trailers)
            }
        }
        throw TestError.connectionClosed
    }
}

/// Opens a plain TCP connection to the proxy, for tunnels.
func withRawConnection<Result: Sendable>(
    port: Int,
    _ body: (inout RawConversation) async throws -> Result
) async throws -> Result {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }
    return try await channel.executeThenClose { inbound, outbound in
        var conversation = RawConversation(inbound: inbound.makeAsyncIterator(), outbound: outbound)
        return try await body(&conversation)
    }
}

struct RawConversation {
    var inbound: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private var unread = ""

    init(
        inbound: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator,
        outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    ) {
        self.inbound = inbound
        self.outbound = outbound
    }

    func send(_ text: String) async throws {
        try await outbound.write(ByteBuffer(string: text))
    }

    /// Reads until `marker` arrives and returns everything up to and including it.
    mutating func read(through marker: String) async throws -> String {
        while !unread.contains(marker) {
            guard let buffer = try await inbound.next() else { throw TestError.connectionClosed }
            unread += String(buffer: buffer)
        }
        let end = unread.range(of: marker)!.upperBound
        defer { unread = String(unread[end...]) }
        return String(unread[..<end])
    }

    /// Reads until the other side closes the connection.
    mutating func readToEnd() async throws -> String {
        while let buffer = try await inbound.next() {
            unread += String(buffer: buffer)
        }
        defer { unread = "" }
        return unread
    }
}

// MARK: - Events

/// Collects a proxy's events so tests can wait for the ones they expect.
final class EventLog: Sendable {
    private final class Storage: Sendable {
        let events = Mutex<[ProxyEvent]>([])
    }

    private let storage = Storage()

    init(_ stream: AsyncStream<ProxyEvent>) {
        let storage = self.storage
        Task {
            for await event in stream {
                storage.events.withLock { $0.append(event) }
            }
        }
    }

    /// The events so far.
    var events: [ProxyEvent] {
        storage.events.withLock { $0 }
    }

    /// Waits until `condition` holds for the events so far, and returns them.
    @discardableResult
    func wait(
        timeout: Duration = waitLimit,
        until condition: ([ProxyEvent]) -> Bool
    ) async throws -> [ProxyEvent] {
        let deadline = ContinuousClock.now + timeout
        while true {
            let events = storage.events.withLock { $0 }
            if condition(events) {
                return events
            }
            guard ContinuousClock.now < deadline else { throw TestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

extension ProxyEvent {
    /// The exchange the event belongs to. A connection's own events have none.
    var exchange: ExchangeID? {
        switch self {
        case .connectionOpened, .connectionClosed:
            nil
        case .requestHead(let id, _, _, _), .requestBody(let id, _), .requestEnd(let id, _),
            .serverConnecting(let id, _), .serverResolved(let id, _), .serverConnected(let id, _, _),
            .serverSecured(let id, _, _), .serverReused(let id, _, _), .serverProtocol(let id, _),
            .upstreamProxy(let id, _), .reverseProxy(let id, _), .clientCertificate(let id, _),
            .sentByReqly(let id), .scriptOutput(let id, _),
            .webSocketMessage(let id, _),
            .requestSent(let id, _),
            .responseHead(let id, _, _), .responseBody(let id, _), .responseTrailers(let id, _),
            .responseEnd(let id, _), .tunnelOpened(let id, _),
            .tunnelClosed(let id, _, _, _), .failed(let id, _, _), .ruleApplied(let id, _), .paused(let id, _, _),
            .resumed(let id, _):
            id
        }
    }

    var requestHead: RequestHead? {
        if case .requestHead(_, _, let head, _) = self { head } else { nil }
    }

    var responseHead: ResponseHead? {
        if case .responseHead(_, let head, _) = self { head } else { nil }
    }

    var requestData: Data? {
        if case .requestBody(_, let data) = self { data } else { nil }
    }

    var responseData: Data? {
        if case .responseBody(_, let data) = self { data } else { nil }
    }

    var failure: ExchangeFailure? {
        if case .failed(_, let failure, _) = self { failure } else { nil }
    }

    var responseTrailers: Headers? {
        if case .responseTrailers(_, let trailers) = self { trailers } else { nil }
    }

    var isResponseEnd: Bool {
        if case .responseEnd = self { true } else { false }
    }

    var isServerConnecting: Bool {
        if case .serverConnecting = self { true } else { false }
    }

    var isSentByReqly: Bool {
        if case .sentByReqly = self { true } else { false }
    }

    /// The event's case, such as `serverConnected`, for checking the order of an exchange's steps.
    var name: String {
        String(String(describing: self).prefix { $0 != "(" })
    }

    var serverAddress: String? {
        if case .serverConnected(_, let address, _) = self { address } else { nil }
    }

    var reusedAddress: String? {
        if case .serverReused(_, let address, _) = self { address } else { nil }
    }

    var tlsVersion: String? {
        if case .serverSecured(_, let version, _) = self { version } else { nil }
    }

    var webSocketMessage: WebSocketMessage? {
        if case .webSocketMessage(_, let message) = self { message } else { nil }
    }

    var serverProtocol: String? {
        if case .serverProtocol(_, let name) = self { name } else { nil }
    }

    var upstreamProxy: String? {
        if case .upstreamProxy(_, let address) = self { address } else { nil }
    }

    var reverseProxy: String? {
        if case .reverseProxy(_, let address) = self { address } else { nil }
    }

    var clientCertificate: String? {
        if case .clientCertificate(_, let name) = self { name } else { nil }
    }

    var scriptOutput: ScriptOutput? {
        if case .scriptOutput(_, let output) = self { output } else { nil }
    }

    var appliedRule: AppliedRule? {
        if case .ruleApplied(_, let rule) = self { rule } else { nil }
    }

    var paused: (ExchangeID, PausedMessage)? {
        if case .paused(let exchange, let message, _) = self { (exchange, message) } else { nil }
    }

    var isTunnelOpened: Bool {
        if case .tunnelOpened = self { true } else { false }
    }

    var tunnelBytes: (sent: Int64, received: Int64)? {
        if case .tunnelClosed(_, let sent, let received, _) = self { (sent, received) } else { nil }
    }
}
