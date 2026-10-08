import NIOCore
import NIOHTTP1
import NIOHTTP2
import ReqlyModel

/// What two requests share when they share a connection to a server.
struct PoolKey: Hashable {
    var authority: Authority
    /// The slow network the connection goes over, if slow network is on for it.
    var network: NetworkProfile?
    /// Straight to the server, or through the upstream proxy.
    var path: ServerPath
    /// ``EngineContext/connectionGeneration`` when the connection opened.
    var generation: Int
}

/// An HTTP/2 connection to a server. The requests on its event loop share it, each over a
/// stream of its own.
final class HTTP2Connection {
    let key: PoolKey
    let channel: any Channel
    let multiplexer: NIOHTTP2Handler.StreamMultiplexer
    /// The server's IP address and port.
    let address: String?
    let tlsVersion: String?
    /// The server said it's going away, so no new requests start on this connection.
    var isGoingAway = false
    /// The streams on the connection that are still open.
    var openStreams = 0
    /// The client certificate Reqly has for the server, by name, and whether the server got it.
    var clientCertificate = ClientCertificateUse.noCertificate
    /// What went wrong with the connection, such as the server's TLS alert, for the streams that
    /// end because of it.
    var failure: (any Error)?

    init(
        key: PoolKey, channel: any Channel, multiplexer: NIOHTTP2Handler.StreamMultiplexer, tlsVersion: String?
    ) {
        self.key = key
        self.channel = channel
        self.multiplexer = multiplexer
        self.address = channel.remoteAddress?.addressAndPort
        self.tlsVersion = tlsVersion
    }

    var isUsable: Bool { channel.isActive && !isGoingAway }
}

/// The HTTP/2 connections to servers on one event loop, and the ones on their way.
///
/// Requests to the same server share one connection. While the first request's connection
/// opens, the others wait for it: if the server speaks HTTP/2 they share it, and otherwise they
/// open connections of their own.
final class ServerPool {
    enum Claim {
        case ready(HTTP2Connection)
        /// Another request is opening a connection to this server. Wait for it.
        case wait
        /// Open a connection, offering HTTP/2, for the requests that wait too.
        case open
        /// The server chose HTTP/1.1 before, so there's nothing to share.
        case openAlone
    }

    private var ready: [PoolKey: HTTP2Connection] = [:]
    private var waiting: [PoolKey: [(HTTP2Connection?) -> Void]] = [:]
    /// Servers that chose HTTP/1.1 when HTTP/2 was offered.
    private var http1Servers: Set<Authority> = []

    func claim(_ key: PoolKey) -> Claim {
        if let connection = ready[key] {
            if connection.isUsable {
                return .ready(connection)
            }
            ready[key] = nil
        }
        if waiting[key] != nil {
            return .wait
        }
        if http1Servers.contains(key.authority) {
            return .openAlone
        }
        waiting[key] = []
        return .open
    }

    func wait(for key: PoolKey, _ use: @escaping (HTTP2Connection?) -> Void) {
        waiting[key, default: []].append(use)
    }

    /// The connection opening for `key` is up: HTTP/2 to share, or none, because the server
    /// chose HTTP/1.1 or the connection failed. The requests waiting for it go on.
    func opened(_ key: PoolKey, _ connection: HTTP2Connection?, serverChoseHTTP1: Bool) {
        if let connection {
            ready[key] = connection
        }
        if serverChoseHTTP1 {
            if http1Servers.count > 10_000 {
                http1Servers.removeAll()
            }
            http1Servers.insert(key.authority)
        }
        for use in waiting.removeValue(forKey: key) ?? [] {
            use(connection)
        }
    }

    /// Shares a connection that opened outside the pool, unless the pool has one to the server
    /// already.
    func adopt(_ connection: HTTP2Connection) {
        if ready[connection.key]?.isUsable != true {
            ready[connection.key] = connection
        }
    }

    func contains(_ connection: HTTP2Connection) -> Bool {
        ready[connection.key] === connection
    }

    func remove(_ connection: HTTP2Connection) {
        if ready[connection.key] === connection {
            ready[connection.key] = nil
        }
    }

    /// Takes no new requests on any connection: they go another way now. A connection closes
    /// once the requests on it are done.
    func retireAll() {
        for connection in ready.values {
            connection.isGoingAway = true
            if connection.openStreams == 0 {
                connection.channel.close(promise: nil)
            }
        }
        ready.removeAll()
        http1Servers.removeAll()
    }

    /// Closes every connection, as when the proxy stops.
    func closeAll() {
        for connection in ready.values {
            connection.channel.close(promise: nil)
        }
        ready.removeAll()
    }
}

/// Watches a shared HTTP/2 connection: it leaves the pool once it closes, or once the server
/// says it's going away.
final class HTTP2ConnectionWatcher: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private let connection: HTTP2Connection
    private weak var pool: ServerPool?

    init(connection: HTTP2Connection, pool: ServerPool) {
        self.connection = connection
        self.pool = pool
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .goAway = unwrapInboundIn(data).payload {
            connection.isGoingAway = true
            pool?.remove(connection)
        }
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        pool?.remove(connection)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        connection.failure = error
        context.fireErrorCaught(error)
    }
}

/// HTTP/2 allows TE only to say the client takes trailers. Any other value goes.
final class HTTP2RequestCleaner: ChannelOutboundHandler {
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard case .head(var head) = unwrapOutboundIn(data), head.headers.contains(name: "TE") else {
            context.write(data, promise: promise)
            return
        }
        let takesTrailers = head.headers["TE"].contains { $0.lowercased().contains("trailers") }
        head.headers.remove(name: "TE")
        if takesTrailers {
            head.headers.add(name: "te", value: "trailers")
        }
        context.write(wrapOutboundOut(.head(head)), promise: promise)
    }
}

/// A connection to a server that's opening, offering HTTP/2. It tells the requests waiting on
/// the pool, once, how it turned out.
///
/// To a name with several addresses, such as an IPv6 and an IPv4 one, the connection may try
/// more than one, each with a ``ServerNegotiationHandler`` of its own. A try that fails says
/// nothing about the connection while another may still open, so only the try that connects
/// reports, or the connection's dial does, once every try has failed.
final class ServerOpening {
    let key: PoolKey
    /// The pool to offer the connection to. Without one, it's the request's alone.
    private weak var pool: ServerPool?
    private(set) var isDone = false

    init(key: PoolKey, pool: ServerPool?) {
        self.key = key
        self.pool = pool
    }

    /// The server chose: a connection to share, or none, as when the connection failed.
    func finish(_ shared: HTTP2Connection?, serverChoseHTTP1: Bool) {
        guard !isDone else { return }
        isDone = true
        pool?.opened(key, shared, serverChoseHTTP1: serverChoseHTTP1)
    }
}

/// Sits behind the TLS handler of a try at a new connection to a server until the server has
/// chosen HTTP/2 or HTTP/1.1. Once the try has connected, it reports a connection that fails
/// to the request that opened it, and to the requests waiting on the pool through `opening`.
final class ServerNegotiationHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    private weak var client: ClientConnectionHandler?
    private weak var connection: ServerConnection?
    private let opening: ServerOpening
    /// Whether this try connected. Only one of the connection's tries does: the others fail
    /// or close before they connect, and the dial reports if none did.
    private var isConnected = false

    init(client: ClientConnectionHandler, connection: ServerConnection, opening: ServerOpening) {
        self.client = client
        self.connection = connection
        self.opening = opening
    }

    /// The server chose: a connection to share, or none.
    func finish(_ shared: HTTP2Connection?, serverChoseHTTP1: Bool) {
        opening.finish(shared, serverChoseHTTP1: serverChoseHTTP1)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Through an upstream proxy's tunnel, the handler joins once the connection is open.
        if context.channel.isActive {
            isConnected = true
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        isConnected = true
        context.fireChannelActive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if isConnected, !opening.isDone {
            finish(nil, serverChoseHTTP1: false)
            client?.serverFailed(error, from: connection)
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if isConnected, !opening.isDone {
            finish(nil, serverChoseHTTP1: false)
            client?.serverInactive(connection)
        }
        context.fireChannelInactive()
    }

    /// A connection that goes before the server has chosen still answers the requests waiting
    /// on it.
    func handlerRemoved(context: ChannelHandlerContext) {
        if isConnected {
            finish(nil, serverChoseHTTP1: false)
        }
    }
}
