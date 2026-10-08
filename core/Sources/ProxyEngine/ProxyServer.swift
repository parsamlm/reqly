import CertificateAuthority
import Foundation
import NIOCore
import NIOPosix
import ReqlyModel

/// Reqly's HTTP proxy. Apps send their traffic here while capturing is on; the server relays
/// it to the real servers and reports what it sees through `events`.
public actor ProxyServer {
    public struct Configuration: Sendable, Hashable {
        /// The address to listen on. Only the Mac itself can reach 127.0.0.1; devices on the
        /// network reach 0.0.0.0, once ``ProxyServer/setDeviceAdmission(_:)`` lets them in.
        public var host: String
        /// The port to listen on. Use 0 to let the system pick a free port.
        public var port: Int

        public init(host: String = "127.0.0.1", port: Int = 9090) {
            self.host = host
            self.port = port
        }
    }

    public enum ServerError: Error, Equatable {
        case alreadyRunning
        /// Another app already listens on this port.
        case portInUse(Int)
    }

    /// Why a reverse proxy isn't listening.
    public enum ReverseProxyProblem: Error, Hashable, Sendable {
        /// Another app, or another reverse proxy, already listens on the port.
        case portInUse(Int)
        /// The port is the proxy's own.
        case proxyPort(Int)
        /// Its server isn't an http or https address.
        case invalidServer

        public var message: String {
            switch self {
            case .portInUse(let port): "Port \(port) is in use by another app or reverse proxy."
            case .proxyPort(let port): "Port \(port) is the port Reqly's proxy uses."
            case .invalidServer: "The server must be an address that starts with http:// or https://."
            }
        }
    }

    /// Everything the server relays, in order for each exchange. One consumer reads it for the
    /// server's whole life, across starts and stops.
    public nonisolated let events: AsyncStream<ProxyEvent>

    private let engine: EngineContext
    private let group: any EventLoopGroup
    private var listener: (any Channel)?
    private var listeningHost = "127.0.0.1"
    private var reverseProxies: [ReverseProxy] = []
    /// The reverse proxies' listeners, on this Mac's IPv4 and IPv6 loopback addresses.
    private var reverseListeners: [any Channel] = []
    /// Why reverse proxies that are on aren't listening.
    public private(set) var reverseProxyProblems: [ReverseProxy.ID: ReverseProxyProblem] = [:]

    /// - Parameter extraTrustedRoots: Root certificates, in DER, to trust when checking servers, on
    ///   top of the ones the Mac trusts. Tests use it for their own HTTPS servers.
    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton, extraTrustedRoots: [[UInt8]] = []) {
        let (events, continuation) = AsyncStream.makeStream(of: ProxyEvent.self)
        self.events = events
        self.engine = EngineContext(continuation: continuation, extraTrustedRoots: extraTrustedRoots)
        self.group = group
    }

    /// Decrypts connections to the hosts that `hosts` decrypts, with certificates from
    /// `authority`. Without an authority nothing is decrypted. Open tunnels that the change
    /// affects close, so apps reconnect the new way.
    public nonisolated func setDecryption(authority: CertificateAuthority?, hosts: DecryptedHosts) {
        engine.setDecryption(authority: authority, hosts: hosts)
    }

    /// Decrypts connections to hosts that match any of `hosts`.
    public nonisolated func setDecryption(authority: CertificateAuthority?, hosts: [HostPattern]) {
        setDecryption(authority: authority, hosts: DecryptedHosts(hosts))
    }

    /// The rules for traffic from now on. Exchanges already on their way keep the rules they
    /// started with.
    public nonisolated func setRules(_ rules: RuleSet) {
        engine.setRules(rules)
    }

    /// Lets an exchange held at a breakpoint go on, or stops it. An exchange that isn't held,
    /// for example because its app went away, is left alone.
    public nonisolated func decide(_ exchange: ExchangeID, _ decision: PausedDecision) {
        engine.decide(exchange, decision)
    }

    /// Decides whether a device on the network may send its traffic through Reqly, once for
    /// each connection. Nothing from the device is read until it's decided. Without a decider,
    /// devices are turned away.
    public nonisolated func setDeviceAdmission(_ admit: (@Sendable (ClientAddress) async -> Bool)?) {
        engine.deviceAdmission = admit
    }

    /// Sends connections to servers through `proxy` from now on, or straight to them without
    /// one. Open tunnels that now go another way close, so apps reconnect.
    public nonisolated func setUpstreamProxy(_ proxy: UpstreamProxy?) {
        engine.setUpstreamProxy(proxy)
    }

    /// Presents these client certificates to the servers they're for, from now on.
    public nonisolated func setClientIdentities(_ identities: [ClientIdentity]) {
        engine.setClientIdentities(identities)
    }

    /// Listens on each reverse proxy that's on, while the server runs, and returns why any
    /// that are on can't.
    @discardableResult
    public func setReverseProxies(_ proxies: [ReverseProxy]) async -> [ReverseProxy.ID: ReverseProxyProblem] {
        reverseProxies = proxies
        if listener != nil {
            await openReverseProxies()
        }
        return reverseProxyProblems
    }

    private func openReverseProxies() async {
        await closeReverseProxies()
        var problems: [ReverseProxy.ID: ReverseProxyProblem] = [:]
        var ports: Set<Int> = []
        let engine = self.engine
        for proxy in reverseProxies where proxy.isOn {
            guard let route = ReverseRoute(proxy) else {
                problems[proxy.id] = .invalidServer
                continue
            }
            guard proxy.localPort != engine.listenPort else {
                problems[proxy.id] = .proxyPort(proxy.localPort)
                continue
            }
            guard !ports.contains(proxy.localPort) else {
                problems[proxy.id] = .portInUse(proxy.localPort)
                continue
            }
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 256)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try ClientConnectionHandler.configureReverse(channel, engine: engine, route: route)
                    }
                }
            do {
                // Only this Mac can reach it, so the firewall never asks about it.
                reverseListeners.append(try await bootstrap.bind(host: "127.0.0.1", port: proxy.localPort).get())
            } catch {
                problems[proxy.id] = .portInUse(proxy.localPort)
                continue
            }
            ports.insert(proxy.localPort)
            // Apps that look up "localhost" may try its IPv6 address first.
            if let ipv6 = try? await bootstrap.bind(host: "::1", port: proxy.localPort).get() {
                reverseListeners.append(ipv6)
            }
        }
        engine.setReversePorts(ports)
        reverseProxyProblems = problems
    }

    private func closeReverseProxies() async {
        let listeners = reverseListeners
        reverseListeners = []
        for listener in listeners {
            try? await listener.close()
        }
        engine.setReversePorts([])
    }

    /// For tests: connections to this Mac go through the upstream proxy too, since the test
    /// servers all run on it.
    nonisolated func sendLoopbackUpstream(_ sends: Bool) {
        engine.sendsLoopbackUpstream = sends
    }

    /// For tests: connections from this Mac count as a device's on the network.
    nonisolated func treatLoopbackAsDevices(_ treats: Bool) {
        engine.treatsLoopbackAsDevices = treats
    }

    deinit {
        engine.finish()
    }

    public var isRunning: Bool { listener != nil }

    /// Sends a request from Reqly itself, such as one you composed, and reports it through
    /// `events` like an app's. It works whether or not the server is listening.
    ///
    /// - Returns: The IDs the request's events carry.
    public nonisolated func send(_ request: OutgoingRequest) -> (exchange: ExchangeID, connection: ConnectionID) {
        SentRequest.start(request, engine: engine, group: group)
    }

    /// Starts listening and returns the port, which matters when the configuration asks for port 0.
    @discardableResult
    public func start(_ configuration: Configuration = Configuration()) async throws -> Int {
        guard listener == nil else { throw ServerError.alreadyRunning }
        engine.isStopping = false
        let channel = try await bind(host: configuration.host, port: configuration.port)
        listener = channel
        listeningHost = configuration.host
        let port = channel.localAddress?.port ?? configuration.port
        engine.listenPort = port
        await openReverseProxies()
        return port
    }

    /// Moves the listener to another address on the same port: 0.0.0.0 for devices on the
    /// network too, or 127.0.0.1 for this Mac only. Open connections stay, except the devices'
    /// when they may no longer connect.
    public func listen(on host: String) async throws {
        guard let current = listener, host != listeningHost else { return }
        let port = engine.listenPort
        listener = nil
        try? await current.close()
        do {
            listener = try await bind(host: host, port: port)
            listeningHost = host
        } catch {
            // Back where it was, so capturing goes on.
            listener = try? await bind(host: listeningHost, port: port)
            throw error
        }
        if host == "127.0.0.1" {
            engine.closeDeviceConnections()
        }
    }

    private func bind(host: String, port: Int) async throws -> any Channel {
        let engine = self.engine
        do {
            return try await ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 256)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try ClientConnectionHandler.configure(channel, engine: engine)
                    }
                }
                .bind(host: host, port: port)
                .get()
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            throw ServerError.portInUse(port)
        }
    }

    /// Stops listening and closes every open connection. Exchanges still in progress fail
    /// with `.captureStopped`.
    public func stop() async {
        guard let listener else { return }
        self.listener = nil
        engine.isStopping = true
        try? await listener.close()
        await closeReverseProxies()
        reverseProxyProblems = [:]
        await engine.closeAllConnections()
        engine.closeServerConnections()
    }
}
