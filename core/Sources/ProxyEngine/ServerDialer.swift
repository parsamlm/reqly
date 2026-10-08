import Foundation
import NIOCore
import NIOPosix
import ReqlyModel

/// The way a connection reaches its server.
enum ServerPath: Hashable, Sendable {
    /// Straight to the server.
    case direct
    /// Through a tunnel the upstream proxy opens with `CONNECT`: once it's open, what's sent
    /// reaches the server.
    case tunnel(UpstreamProxy)
    /// To the upstream proxy itself, for plain HTTP requests, which it gets with the full URL.
    case forwardingProxy(UpstreamProxy)

    /// The way to `authority` for traffic that's encrypted or switches protocols, which needs a
    /// tunnel, or for plain HTTP, which the proxy can forward.
    init(to authority: Authority, needsTunnel: Bool, engine: EngineContext) {
        guard let proxy = engine.upstreamProxy(for: authority.host) else {
            self = .direct
            return
        }
        self = needsTunnel ? .tunnel(proxy) : .forwardingProxy(proxy)
    }

    var proxy: UpstreamProxy? {
        switch self {
        case .direct: nil
        case .tunnel(let proxy), .forwardingProxy(let proxy): proxy
        }
    }
}

/// Opens connections to servers, straight there or through the upstream proxy.
enum ServerDialer {
    /// Connects to `authority` the way `path` says, with slow network first in the pipeline,
    /// then hands the channel to `configure` for what goes over it.
    ///
    /// Through a tunnel, `configure` runs once the proxy has opened it, so a TLS handshake
    /// added there starts with the server. Otherwise it runs as the connection opens.
    static func connect(
        to authority: Authority, path: ServerPath, network: NetworkProfile?, on loop: any EventLoop,
        resolved: @escaping @Sendable (Date) -> Void,
        configure: @escaping @Sendable (any Channel) throws -> Void
    ) -> EventLoopFuture<any Channel> {
        let proxy = path.proxy
        let target = proxy.map { Authority(host: $0.host, port: $0.port) } ?? authority
        let resolver = ClientConnectionHandler.timedResolver(for: target, on: loop, resolved: resolved)
        let isTunnel = if case .tunnel = path { true } else { false }
        let connected = ClientBootstrap(group: loop)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(20))
            .resolver(resolver)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try ThrottleHandler.slow(channel, to: network)
                    if !isTunnel {
                        try configure(channel)
                    }
                }
            }
            .connect(host: target.host, port: target.port)
            .afterOpening(over: network)
        guard let proxy else { return connected }
        let reaching = connected.flatMapErrorThrowing { error in
            throw UpstreamProxyError(proxy: proxy.address, problem: .unreachable(error))
        }
        guard isTunnel else { return reaching }
        // Everything from here runs on the connection's event loop, which is the caller's.
        return reaching.assumeIsolated().flatMap { channel -> EventLoopFuture<any Channel> in
            let tunnel = UpstreamTunnelHandler(target: authority, proxy: proxy, promise: loop.makePromise())
            do {
                try channel.pipeline.syncOperations.addHandler(tunnel)
            } catch {
                channel.close(promise: nil)
                return loop.makeFailedFuture(error)
            }
            return tunnel.opened.assumeIsolated().flatMapThrowing { () -> any Channel in
                let pipeline = channel.pipeline.syncOperations
                try configure(channel)
                // Bytes the server sent along with the proxy's answer go on to what's configured.
                pipeline.removeHandler(tunnel, promise: nil)
                return channel
            }
            .flatMapErrorThrowing { error -> any Channel in
                channel.close(promise: nil)
                throw error
            }
            .nonisolated()
        }
        .nonisolated()
    }
}

/// Why the upstream proxy didn't open the way to a server.
struct UpstreamProxyError: Error {
    enum Problem {
        /// Reqly couldn't reach the proxy itself.
        case unreachable(any Error)
        /// The proxy asks for a user name and password, and Reqly has none.
        case signInRequired
        /// The proxy didn't accept the user name and password.
        case signInRefused
        /// The proxy refused, with this status and reason.
        case refused(Int, String)
        case closed
        case timedOut
    }

    /// The proxy's address, such as `proxy.example.com:8080`.
    var proxy: String
    var problem: Problem

    /// What went wrong, to follow "Couldn't connect to the server:".
    var reason: String {
        let proxy = "the upstream proxy at \(proxy)"
        switch problem {
        case .unreachable(let error):
            if let error = error as? NIOConnectionError {
                if error.connectionErrors.isEmpty {
                    return "the upstream proxy's name, \(error.host), didn't resolve."
                }
                if let refused = error.connectionErrors.first?.error as? IOError, refused.errnoCode == ECONNREFUSED {
                    return "\(proxy) refused the connection."
                }
                return "\(proxy) didn't accept the connection."
            }
            if let error = error as? ChannelError, case .connectTimeout = error {
                return "\(proxy) didn't answer in time."
            }
            return "\(proxy) couldn't be reached: \(error)"
        case .signInRequired:
            return "\(proxy) asks for a user name and password. Add them in Settings, under Upstream Proxy."
        case .signInRefused:
            return "\(proxy) didn't accept the user name and password."
        case .refused(let status, let reason):
            return "\(proxy) answered \(status)\(reason.isEmpty ? "" : " \(reason)")."
        case .closed:
            return "\(proxy) closed the connection."
        case .timedOut:
            return "\(proxy) didn't open the way to the server in time."
        }
    }
}

/// Asks the upstream proxy for a tunnel to a server with `CONNECT`, and waits for its answer.
/// Once the tunnel is open, bytes pass through untouched, and the handler leaves when it's
/// removed, handing on any bytes the server sent along with the answer.
final class UpstreamTunnelHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let target: Authority
    private let proxy: UpstreamProxy
    private let promise: EventLoopPromise<Void>
    private var answer = ByteBuffer()
    private var isOpen = false
    private var isDone = false
    private var leftOver: ByteBuffer?
    private var timeout: Scheduled<Void>?

    /// Succeeds once the proxy has opened the tunnel.
    var opened: EventLoopFuture<Void> { promise.futureResult }

    /// A proxy's answer longer than this isn't one.
    private static let answerLimit = 64 << 10

    init(target: Authority, proxy: UpstreamProxy, promise: EventLoopPromise<Void>) {
        self.target = target
        self.proxy = proxy
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            ask(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        ask(context: context)
        context.fireChannelActive()
    }

    private func ask(context: ChannelHandlerContext) {
        guard timeout == nil, !isDone else { return }
        let host = target.host.contains(":") ? "[\(target.host)]" : target.host
        var request = "CONNECT \(host):\(target.port) HTTP/1.1\r\nHost: \(host):\(target.port)\r\n"
        if let authorization = proxy.authorization {
            request += "Proxy-Authorization: \(authorization)\r\n"
        }
        request += "\r\n"
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: request)), promise: nil)
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        timeout = context.eventLoop.assumeIsolated().scheduleTask(in: .seconds(20)) { [self] in
            fail(.timedOut, context: loopContext.value)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isOpen else {
            context.fireChannelRead(data)
            return
        }
        guard !isDone else { return }
        var bytes = unwrapInboundIn(data)
        answer.writeBuffer(&bytes)
        let view = answer.readableBytesView
        guard let end = view.firstRange(of: Array("\r\n\r\n".utf8)) else {
            if answer.readableBytes > Self.answerLimit {
                fail(.refused(0, "an answer Reqly couldn't read"), context: context)
            }
            return
        }
        let head = String(decoding: view[view.startIndex..<end.lowerBound], as: UTF8.self)
        let statusLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        let reason = parts.count == 3 ? String(parts[2]) : ""
        guard (200..<300).contains(status) else {
            if status == 407 {
                fail(proxy.authorization == nil ? .signInRequired : .signInRefused, context: context)
            } else {
                fail(.refused(status, reason), context: context)
            }
            return
        }
        let consumed = end.upperBound - view.startIndex
        answer.moveReaderIndex(forwardBy: consumed)
        if answer.readableBytes > 0 {
            leftOver = answer
        }
        answer = ByteBuffer()
        isOpen = true
        isDone = true
        timeout?.cancel()
        promise.succeed()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !isOpen {
            fail(.closed, context: context)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard isOpen else {
            fail(.unreachable(error), context: context)
            return
        }
        context.fireErrorCaught(error)
    }

    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        if let leftOver {
            self.leftOver = nil
            context.fireChannelRead(wrapInboundOut(leftOver))
        }
        context.leavePipeline(removalToken: removalToken)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timeout?.cancel()
        if !isDone {
            isDone = true
            promise.fail(UpstreamProxyError(proxy: proxy.address, problem: .closed))
        }
    }

    private func fail(_ problem: UpstreamProxyError.Problem, context: ChannelHandlerContext) {
        guard !isDone else { return }
        isDone = true
        timeout?.cancel()
        promise.fail(UpstreamProxyError(proxy: proxy.address, problem: problem))
        context.close(promise: nil)
    }
}

/// Where a reverse proxy sends what it gets.
struct ReverseRoute: Sendable {
    var server: ReverseProxy.Server
    var authority: Authority
    /// The port apps connect to.
    var localPort: Int
    /// Such as `localhost:8080`.
    var localAddress: String
    var rewritesRedirects: Bool

    init?(_ proxy: ReverseProxy) {
        guard let server = proxy.server else { return nil }
        self.server = server
        authority = Authority(host: server.host, port: server.port)
        localPort = proxy.localPort
        localAddress = proxy.localAddress
        rewritesRedirects = proxy.rewritesRedirects
    }
}
