import NIOCore
import NIOHTTP1
import NIOSSL
import NIOTLS
import ReqlyModel

/// The way to a server for one exchange: a connection of its own, reused while the app keeps
/// asking the same server over HTTP/1.1, or a stream on an HTTP/2 connection that requests
/// share. Parts sent while it's still opening are written once it's up.
final class ServerConnection {
    let authority: Authority
    let usesTLS: Bool
    /// The slow network the connection goes over, if slow network is on for its host.
    let network: NetworkProfile?
    /// Speaks only HTTP/1.1, as plain HTTP does, and as a request to switch protocols needs.
    let onlyHTTP1: Bool
    /// Straight to the server, or through the upstream proxy.
    let path: ServerPath
    /// ``EngineContext/connectionGeneration`` when the connection was made.
    let generation: Int
    /// The client certificate Reqly has for the server, by name, and whether the server got it.
    var clientCertificate = ClientCertificateUse.noCertificate
    /// The shared HTTP/2 connection a stream is on.
    var shared: HTTP2Connection?
    /// A stream on a shared HTTP/2 connection, which carries one exchange only.
    var isStream = false
    private(set) var channel: (any Channel)?
    /// The server's IP address and port, once connected.
    private(set) var address: String?
    /// The TLS version, once the handshake finished.
    var tlsVersion: String?
    private var pending: [(part: HTTPClientRequestPart, promise: EventLoopPromise<Void>?)] = []

    init(
        authority: Authority, usesTLS: Bool, network: NetworkProfile? = nil, onlyHTTP1: Bool = true,
        path: ServerPath = .direct, generation: Int = 0
    ) {
        self.authority = authority
        self.usesTLS = usesTLS
        self.network = network
        self.onlyHTTP1 = onlyHTTP1
        self.path = path
        self.generation = generation
    }

    var poolKey: PoolKey { PoolKey(authority: authority, network: network, path: path, generation: generation) }

    deinit {
        failPending()
    }

    var isOpen: Bool { channel?.isActive ?? false }

    /// Writes a part, or keeps it until the connection is up. `promise` succeeds once the part
    /// is written to the server.
    func send(_ part: HTTPClientRequestPart, flush: Bool = false, promise: EventLoopPromise<Void>? = nil) {
        guard let channel else {
            pending.append((part, promise))
            return
        }
        channel.write(part, promise: promise)
        if flush {
            channel.flush()
        }
    }

    func connected(to channel: any Channel) {
        self.channel = channel
        address = channel.remoteAddress?.addressAndPort
        for (part, promise) in pending {
            channel.write(part, promise: promise)
        }
        pending.removeAll()
        channel.flush()
    }

    func close() {
        channel?.close(promise: nil)
        channel = nil
        failPending()
    }

    /// Parts that were never written still owe their promises an answer.
    private func failPending() {
        for (_, promise) in pending {
            promise?.fail(ChannelError.ioOnClosedChannel)
        }
        pending.removeAll()
    }
}

extension SocketAddress {
    /// The address as people write it, such as `203.0.113.24:443` or `[2001:db8::1]:443`.
    var addressAndPort: String? {
        guard let ip = ipAddress, let port else { return nil }
        return ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }
}

extension TLSVersion {
    /// The version's number, such as `1.3`.
    var number: String {
        switch self {
        case .tlsv1: "1.0"
        case .tlsv11: "1.1"
        case .tlsv12: "1.2"
        case .tlsv13: "1.3"
        }
    }
}

/// Sits on a server connection and passes the server's responses back to the app's connection handler.
final class ServerResponseHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart

    private weak var client: ClientConnectionHandler?
    private weak var connection: ServerConnection?

    init(client: ClientConnectionHandler, connection: ServerConnection) {
        self.client = client
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        client?.serverRead(unwrapInboundIn(data), from: connection)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        client?.serverReadComplete(from: connection)
    }

    func channelInactive(context: ChannelHandlerContext) {
        client?.serverInactive(connection)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent {
            let version = (try? context.pipeline.syncOperations.nioSSL_tlsVersion()) ?? nil
            client?.serverSecured(version, from: connection)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        client?.serverWritabilityChanged(context.channel.isWritable, from: connection)
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        client?.serverFailed(error, from: connection)
        context.close(promise: nil)
    }
}
