import CertificateAuthority
import Foundation
import NIOCore
import NIOSSL
import ReqlyModel
import Synchronization

/// State shared by every connection of one proxy server. Safe to use from any event loop.
final class EngineContext: Sendable {
    private let continuation: AsyncStream<ProxyEvent>.Continuation
    private let lastExchange = Atomic<UInt64>(0)
    private let lastConnection = Atomic<UInt64>(0)
    private let port = Atomic<Int>(0)
    /// The ports reverse proxies listen on.
    private let reversePorts = Mutex<Set<Int>>([])
    private let stopping = Atomic<Bool>(false)
    private let loopbackIsDevice = Atomic<Bool>(false)
    private let loopbackGoesUpstream = Atomic<Bool>(false)
    private let channels = Mutex<[ObjectIdentifier: any Channel]>([:])
    private let decryption = Mutex<(authority: CertificateAuthority?, hosts: DecryptedHosts)>((nil, .init()))
    /// The TLS setup Reqly presents to apps, one per decrypted host.
    private let serverContexts = Mutex<[String: NIOSSLContext]>([:])
    /// Open tunnels, by app connection: whether each one is decrypted, and the slow network a
    /// tunnel that isn't goes over.
    private let tunnels = Mutex<[ObjectIdentifier: Tunnel]>([:])
    private let ruleSet = Mutex<RuleSet>(RuleSet())
    /// Exchanges held at breakpoints, and how to wake each one.
    private let pauses = Mutex<[ExchangeID: @Sendable (PausedDecision) -> Void]>([:])
    /// Decides whether a device on the network may connect. Without it, devices are turned away.
    private let admission = Mutex<(@Sendable (ClientAddress) async -> Bool)?>(nil)
    /// The Mac's own addresses, and when they were read. The Mac can join another network
    /// meanwhile, so they're read again every few seconds.
    private let ownAddresses = Mutex<(read: Date, addresses: Set<String>)>((.distantPast, []))
    /// The HTTP/2 connections to servers, a pool for each event loop.
    private let pools = Mutex<[ObjectIdentifier: (loop: any EventLoop, pool: NIOLoopBound<ServerPool>)]>([:])
    /// The proxy that connections to servers go through, if there is one.
    private let upstream = Mutex<UpstreamProxy?>(nil)
    /// The client certificates, in order, and the TLS setups that present them that no connection
    /// holds now, by place in the list and protocols offered. `version` goes up with each new list.
    private let identities = Mutex<(list: [ClientIdentity], idle: [Int: [ClientCertificateTLS]], version: Int)>(
        ([], [:], 0))
    /// Goes up when connections to servers start going another way, through another proxy or
    /// with other certificates, so the connections opened before aren't reused.
    private let generation = Atomic<Int>(0)
    /// Each script's `shared` object, as JSON, by its rule, kept from one run to the next.
    private let scriptStates = Mutex<[UUID: String]>([:])
    /// How connections to servers check certificates: the way macOS does.
    private let clientConfiguration: TLSConfiguration
    /// The TLS setup for connections to servers, offering HTTP/2 and HTTP/1.1.
    let upstreamTLS: NIOSSLContext?
    /// The same, offering HTTP/1.1 only: for requests that switch protocols, such as to
    /// WebSocket, and for the requests Reqly sends itself.
    let upstreamTLSForHTTP1: NIOSSLContext?

    init(continuation: AsyncStream<ProxyEvent>.Continuation, extraTrustedRoots: [[UInt8]] = []) {
        self.continuation = continuation
        var configuration = TLSConfiguration.makeClientConfiguration()
        if !extraTrustedRoots.isEmpty {
            let roots = extraTrustedRoots.compactMap { try? NIOSSLCertificate(bytes: $0, format: .der) }
            configuration.additionalTrustRoots = [.certificates(roots)]
        }
        clientConfiguration = configuration
        configuration.applicationProtocols = ["h2", "http/1.1"]
        upstreamTLS = try? NIOSSLContext(configuration: configuration)
        configuration.applicationProtocols = ["http/1.1"]
        upstreamTLSForHTTP1 = try? NIOSSLContext(configuration: configuration)
    }

    func emit(_ event: ProxyEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    func makeExchangeID() -> ExchangeID {
        ExchangeID(rawValue: lastExchange.add(1, ordering: .relaxed).newValue)
    }

    func makeConnectionID() -> ConnectionID {
        ConnectionID(rawValue: lastConnection.add(1, ordering: .relaxed).newValue)
    }

    /// The port the server listens on, once it has started.
    var listenPort: Int {
        get { port.load(ordering: .relaxed) }
        set { port.store(newValue, ordering: .relaxed) }
    }

    /// For tests: connections from this Mac count as a device's on the network.
    var treatsLoopbackAsDevices: Bool {
        get { loopbackIsDevice.load(ordering: .relaxed) }
        set { loopbackIsDevice.store(newValue, ordering: .relaxed) }
    }

    /// For tests: connections to this Mac go through the upstream proxy too.
    var sendsLoopbackUpstream: Bool {
        get { loopbackGoesUpstream.load(ordering: .relaxed) }
        set { loopbackGoesUpstream.store(newValue, ordering: .relaxed) }
    }

    /// Whether a connection comes from a device on the network, which needs letting in.
    func isDevice(_ client: ClientAddress) -> Bool {
        !client.isLoopback || treatsLoopbackAsDevices
    }

    /// Set while the server shuts down, so interrupted exchanges fail as `.captureStopped`.
    var isStopping: Bool {
        get { stopping.load(ordering: .relaxed) }
        set { stopping.store(newValue, ordering: .relaxed) }
    }

    /// Decrypts connections to the hosts that `hosts` decrypts, with certificates from `authority`.
    ///
    /// Open tunnels that the change affects close, so apps reconnect under the new rules right
    /// away instead of reusing a connection that is decrypted, or not, the old way.
    func setDecryption(authority: CertificateAuthority?, hosts: DecryptedHosts) {
        decryption.withLock { $0 = (authority, hosts) }
        // The certificates may come from a new root now.
        serverContexts.withLock { $0.removeAll() }
        let outdated = tunnels.withLock { tunnels in
            tunnels.values.filter { $0.decrypted != (authority != nil && hosts.decrypts($0.host)) }.map(\.channel)
        }
        for channel in outdated {
            channel.close(promise: nil)
        }
    }

    private struct Tunnel {
        let channel: any Channel
        let host: String
        let decrypted: Bool
        let network: NetworkProfile?
        /// The upstream proxy a tunnel that isn't decrypted goes through, if any.
        let proxy: UpstreamProxy?
    }

    /// Remembers an open tunnel until it closes, so a change to what's decrypted, to slow
    /// network, or to the upstream proxy can close it.
    func registerTunnel(
        _ channel: any Channel, host: String, decrypted: Bool, network: NetworkProfile? = nil,
        proxy: UpstreamProxy? = nil
    ) {
        let key = ObjectIdentifier(channel)
        tunnels.withLock {
            $0[key] = Tunnel(channel: channel, host: host, decrypted: decrypted, network: network, proxy: proxy)
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.tunnels.withLock { _ = $0.removeValue(forKey: key) }
        }
    }

    /// The rules for exchanges that start from now on.
    var rules: RuleSet {
        ruleSet.withLock { $0 }
    }

    /// Changes the rules for exchanges that start from now on.
    ///
    /// A tunnel that isn't decrypted goes over the network it opened on. One that slow network
    /// now treats differently closes, so its app reconnects under the new conditions.
    func setRules(_ rules: RuleSet) {
        ruleSet.withLock { $0 = rules }
        let outdated = tunnels.withLock { tunnels in
            tunnels.values.filter { !$0.decrypted && $0.network != rules.networkConditions(for: $0.host) }
                .map(\.channel)
        }
        for channel in outdated {
            channel.close(promise: nil)
        }
    }

    // MARK: - Scripts

    func sharedState(of rule: Rule) -> String? {
        scriptStates.withLock { $0[rule.id] }
    }

    func setSharedState(_ state: String, of rule: Rule) {
        scriptStates.withLock { states in
            if states.count > 1_000 {
                states.removeAll()
            }
            states[rule.id] = state
        }
    }

    // MARK: - Connections to servers

    /// How many times connections to servers have started going another way. A connection is
    /// reused only while this hasn't changed since it opened.
    var connectionGeneration: Int {
        generation.load(ordering: .relaxed)
    }

    /// The upstream proxy a connection to `host` goes through, or `nil` to go straight to it.
    func upstreamProxy(for host: String) -> UpstreamProxy? {
        guard let proxy = upstream.withLock({ $0 }), !proxy.bypasses(host, includingThisMac: !sendsLoopbackUpstream),
            !isLoop(Authority(host: proxy.host, port: proxy.port))
        else { return nil }
        return proxy
    }

    /// Sends connections to servers through `proxy` from now on, or straight to them without
    /// one. Tunnels that aren't decrypted and now go another way close, so apps reconnect.
    func setUpstreamProxy(_ proxy: UpstreamProxy?) {
        upstream.withLock { $0 = proxy }
        startNewConnections()
        let open = tunnels.withLock { Array($0.values) }
        for tunnel in open where !tunnel.decrypted && tunnel.proxy != upstreamProxy(for: tunnel.host) {
            tunnel.channel.close(promise: nil)
        }
    }

    /// Presents these certificates to the servers they're for, from now on.
    func setClientIdentities(_ list: [ClientIdentity]) {
        identities.withLock { $0 = (list, [:], $0.version + 1) }
        startNewConnections()
    }

    /// The TLS setup for a connection to `host`, offering HTTP/2 or only HTTP/1.1. If Reqly has
    /// a client certificate for the host, the setup presents it when the server asks for one, and
    /// the connection holds the setup until it closes.
    func clientTLS(for host: String, offeringHTTP2: Bool) -> ServerTLS? {
        let found = identities.withLock {
            state -> (key: Int, identity: ClientIdentity, version: Int, idle: ClientCertificateTLS?)? in
            guard let index = state.list.firstIndex(where: { $0.hosts.matches(host) }) else { return nil }
            let key = index * 2 + (offeringHTTP2 ? 1 : 0)
            return (key, state.list[index], state.version, state.idle[key]?.popLast())
        }
        guard let found else {
            return (offeringHTTP2 ? upstreamTLS : upstreamTLSForHTTP1).map { ServerTLS(context: $0, certificate: nil) }
        }
        if let idle = found.idle {
            return ServerTLS(context: idle.context, certificate: idle)
        }
        var configuration = clientConfiguration
        configuration.applicationProtocols = offeringHTTP2 ? ["h2", "http/1.1"] : ["http/1.1"]
        configuration.certificateChain = found.identity.chain.map { .certificate($0) }
        configuration.privateKey = .privateKey(found.identity.key)
        let (key, version) = (found.key, found.version)
        let made = try? ClientCertificateTLS(configuration: configuration, name: found.identity.name) {
            [weak self] released in
            self?.identities.withLock { state in
                // A few are kept, for the connections that open together.
                guard state.version == version, state.idle[key, default: []].count < 8 else { return }
                state.idle[key, default: []].append(released)
            }
        }
        return made.map { ServerTLS(context: $0.context, certificate: $0) }
    }

    /// Connections to servers that open from now on go the new way. The shared ones take no new
    /// requests, and close once the ones on them are done.
    private func startNewConnections() {
        generation.add(1, ordering: .relaxed)
        for (loop, pool) in pools.withLock({ Array($0.values) }) {
            loop.execute {
                pool.value.retireAll()
            }
        }
    }

    /// Holds an exchange at a breakpoint. `resume` runs once ``decide(_:_:)`` is called for it.
    func pause(
        _ exchange: ExchangeID, _ message: PausedMessage, breakpoint: String,
        resume: @escaping @Sendable (PausedDecision) -> Void
    ) {
        pauses.withLock { $0[exchange] = resume }
        emit(.paused(exchange, message, breakpoint: breakpoint))
    }

    func decide(_ exchange: ExchangeID, _ decision: PausedDecision) {
        let resume = pauses.withLock { $0.removeValue(forKey: exchange) }
        resume?(decision)
    }

    /// Lets go of a pause that ended some other way, such as the app closing the connection.
    func forgetPause(_ exchange: ExchangeID) {
        pauses.withLock { _ = $0.removeValue(forKey: exchange) }
    }

    func shouldDecrypt(_ host: String) -> Bool {
        decryption.withLock { $0.authority != nil && $0.hosts.decrypts(host) }
    }

    /// The TLS setup that presents a certificate for `host`, signed by Reqly's root, to the app.
    func serverTLS(for host: String) throws -> NIOSSLContext {
        if let context = serverContexts.withLock({ $0[host] }) {
            return context
        }
        guard let authority = decryption.withLock({ $0.authority }) else { throw NIOSSLError.failedToLoadCertificate }
        let identity = try authority.identity(for: host)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try identity.certificateChain.map {
                .certificate(try NIOSSLCertificate(bytes: $0, format: .der))
            },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem))
        )
        configuration.applicationProtocols = ["h2", "http/1.1"]
        let context = try NIOSSLContext(configuration: configuration)
        serverContexts.withLock { contexts in
            if contexts.count > 2_000 { contexts.removeAll() }
            contexts[host] = context
        }
        return context
    }

    /// Would connecting here reach this proxy again, or one of its reverse proxies?
    func isLoop(_ authority: Authority) -> Bool {
        let ports = reversePorts.withLock { $0 }
        guard authority.port == listenPort || ports.contains(authority.port) else { return false }
        return authority.isLoopback || isOwnAddress(authority.host)
    }

    /// The ports reverse proxies listen on now.
    func setReversePorts(_ ports: Set<Int>) {
        reversePorts.withLock { $0 = ports }
    }

    /// Whether `host` is one of the Mac's own IP addresses, on any of its networks.
    func isOwnAddress(_ host: String) -> Bool {
        let now = Date()
        let addresses = ownAddresses.withLock { cached in
            if now.timeIntervalSince(cached.read) > 5 {
                let devices = (try? System.enumerateDevices()) ?? []
                cached = (now, Set(devices.compactMap { $0.address?.ipAddress }))
            }
            return cached.addresses
        }
        return addresses.contains(host)
    }

    var deviceAdmission: (@Sendable (ClientAddress) async -> Bool)? {
        get { admission.withLock { $0 } }
        set { admission.withLock { $0 = newValue } }
    }

    /// Reqly's root certificate, for devices to download, while there is one to decrypt with.
    var rootCertificate: (der: [UInt8], name: String)? {
        guard let root = decryption.withLock({ $0.authority?.root }), let der = try? root.certificateDER else {
            return nil
        }
        return (der, root.name)
    }

    func register(_ channel: any Channel) {
        channels.withLock { $0[ObjectIdentifier(channel)] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.channels.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(channel)) }
        }
    }

    /// Closes the connections from devices on the network, such as when they may no longer connect.
    func closeDeviceConnections() {
        let devices = channels.withLock { channels in
            channels.values.filter { channel in
                channel.remoteAddress?.ipAddress.map { !ClientAddress(ip: $0, port: 0).isLoopback } ?? false
            }
        }
        for channel in devices {
            channel.close(promise: nil)
        }
    }

    /// The pool of HTTP/2 connections on the event loop the caller runs on.
    func serverPool(on loop: any EventLoop) -> ServerPool {
        let key = ObjectIdentifier(loop)
        if let existing = pools.withLock({ $0[key] }) {
            return existing.pool.value
        }
        let pool = ServerPool()
        pools.withLock { $0[key] = (loop, NIOLoopBound(pool, eventLoop: loop)) }
        return pool
    }

    /// Closes the shared HTTP/2 connections to servers, as when the proxy stops.
    func closeServerConnections() {
        for (loop, pool) in pools.withLock({ Array($0.values) }) {
            loop.execute {
                pool.value.closeAll()
            }
        }
    }

    /// Closes every app connection that is still open.
    func closeAllConnections() async {
        let open = channels.withLock { Array($0.values) }
        await withTaskGroup(of: Void.self) { group in
            for channel in open {
                group.addTask { try? await channel.close() }
            }
        }
    }
}
