import BodyKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import NIOTLS
import ReqlyModel
import Scripts

/// Handles one connection from an app. On Reqly's proxy port it reads the app's HTTP requests,
/// forwards plain HTTP to the server, and turns `CONNECT` requests into tunnels: encrypted
/// tunnels that pass through untouched, or decrypted ones for the hosts the user chose.
///
/// Inside a decrypted tunnel it handles the app's requests over HTTP/1.1, or one HTTP/2 stream
/// each, and sends them on to the server over TLS.
///
/// The connection to the server runs on the same event loop, so the handlers on both sides
/// talk to each other directly.
final class ClientConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// What the connection carries.
    enum Mode {
        /// Reqly's proxy port: absolute-form HTTP requests and `CONNECT`.
        case proxy
        /// Requests from a decrypted tunnel to `authority`, over HTTP/1.1 or an HTTP/2 stream.
        case decrypted(Authority, http2: Bool)
        /// A reverse proxy's port: every request goes to its one server.
        case reverse(ReverseRoute)
    }

    /// Sets up a new connection to Reqly's proxy port.
    static func configure(_ channel: any Channel, engine: EngineContext) throws {
        let id = engine.makeConnectionID()
        // No pipelining helper: this handler queues pipelined requests itself, and the fewer
        // HTTP handlers there are, the simpler it is to hand the connection over to a tunnel.
        let encoder = HTTPResponseEncoder()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let handler = ClientConnectionHandler(
            id: id, mode: .proxy, engine: engine, encoder: encoder, decoder: decoder)
        try channel.pipeline.syncOperations.addHandlers([encoder, decoder, handler])

        engine.register(channel)
        let address = channel.remoteAddress
        let client = ClientAddress(ip: address?.ipAddress ?? "", port: address?.port ?? 0)
        @Sendable func open() {
            engine.emit(.connectionOpened(id, client: client, at: Date()))
            channel.closeFuture.whenComplete { _ in
                engine.emit(.connectionClosed(id, at: Date()))
            }
        }
        guard engine.isDevice(client) else {
            open()
            return
        }
        // A device on the network: nothing is read from it until it's allowed, and a device
        // that isn't leaves no trace in the traffic.
        try channel.syncOptions?.setOption(ChannelOptions.autoRead, value: false)
        guard let admit = engine.deviceAdmission else {
            channel.close(promise: nil)
            return
        }
        try channel.pipeline.syncOperations.addHandler(
            DeviceAdmissionHandler(client: client, admit: admit, open: open), position: .first)
    }

    /// Sets up a new connection to a reverse proxy's port, which only this Mac can reach.
    static func configureReverse(_ channel: any Channel, engine: EngineContext, route: ReverseRoute) throws {
        let id = engine.makeConnectionID()
        let encoder = HTTPResponseEncoder()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let handler = ClientConnectionHandler(
            id: id, mode: .reverse(route), engine: engine, encoder: encoder, decoder: decoder)
        try channel.pipeline.syncOperations.addHandlers([encoder, decoder, handler])
        engine.register(channel)
        let address = channel.remoteAddress
        // The app connected to the reverse proxy's port, which is how Reqly finds which app it is.
        let client = ClientAddress(ip: address?.ipAddress ?? "", port: address?.port ?? 0, localPort: route.localPort)
        engine.emit(.connectionOpened(id, client: client, at: Date()))
        channel.closeFuture.whenComplete { _ in
            engine.emit(.connectionClosed(id, at: Date()))
        }
    }

    /// Sets up HTTP/1.1 inside a decrypted tunnel, once the app accepted Reqly's certificate.
    static func configureDecrypted(
        _ channel: any Channel, engine: EngineContext, connectionID: ConnectionID, authority: Authority
    ) throws {
        let encoder = HTTPResponseEncoder()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let handler = ClientConnectionHandler(
            id: connectionID, mode: .decrypted(authority, http2: false), engine: engine, encoder: encoder,
            decoder: decoder)
        try channel.pipeline.syncOperations.addHandlers([encoder, decoder, handler])
    }

    /// Sets up one HTTP/2 stream inside a decrypted tunnel.
    static func configureDecryptedStream(
        _ stream: any Channel, engine: EngineContext, connectionID: ConnectionID, authority: Authority
    ) throws {
        let handler = ClientConnectionHandler(
            id: connectionID, mode: .decrypted(authority, http2: true), engine: engine, encoder: nil, decoder: nil)
        try stream.pipeline.syncOperations.addHandlers([HTTP2FramePayloadToHTTP1ServerCodec(), handler])
    }

    private enum State {
        /// Waiting for the next request.
        case idle
        /// Relaying a request and its response.
        case forwarding(Forwarding)
        /// Read the head of a `CONNECT` request for a tunnel; waiting for its end.
        case tunnelRequested(ExchangeID, Authority)
        case tunnelConnecting(ExchangeID, Authority)
        /// Read the head of a `CONNECT` request for a host Reqly decrypts; waiting for its end.
        case decryptRequested(PendingConnect)
        /// Handing the connection over to a tunnel. This handler is on its way out.
        case switching
        case closed
    }

    private struct Forwarding {
        let exchange: ExchangeID
        let appKeepsAlive: Bool
        /// What the rules do to this exchange.
        var plan = RulePlan([])
        /// Where the request goes, once the rules have had their say.
        var destination: Destination?
        /// The slow network it goes over, if slow network is on for the host the app asked for.
        var network: NetworkProfile?
        /// The request as it goes to the server, kept while it's held.
        var serverHead: HTTPRequestHead?
        /// The request's body while it's held, for a breakpoint or a body rewrite. `nil` once
        /// it's gone to the server, or when nothing holds it.
        var heldRequestBody: Data?
        /// The response while it's held, for a breakpoint or a body rewrite.
        var heldResponse: (head: HTTPResponseHead, body: Data)?
        /// The server sent all of a held response, so its connection closing doesn't matter.
        var responseComplete = false
        /// Waiting at a breakpoint for you to decide.
        var isPaused = false
        var requestEnded = false
        /// The app has the response's head.
        var responseStarted = false
        /// Set before the response's end goes to the app. On an HTTP/2 stream, writing the end
        /// closes the stream right away, and that's no failure.
        var responseEnded = false
        var serverKeepsAlive = true
        var switchingProtocols = false
        /// What the server agreed to, when it switched to WebSocket.
        var webSocket: WebSocketSettings?
        /// The request as it went to the server, kept for scripts' `onResponse`.
        var scriptRequest: ScriptRequest?
    }

    private let id: ConnectionID
    private let mode: Mode
    private let engine: EngineContext
    /// The HTTP/1 handlers in front of this one. An HTTP/2 stream has a codec instead.
    private let encoder: HTTPResponseEncoder?
    private let decoder: ByteToMessageHandler<HTTPRequestDecoder>?
    private var context: ChannelHandlerContext?
    private var state = State.idle
    private var server: ServerConnection?
    /// Requests the app sent before the current response finished (HTTP pipelining).
    private var queued: [HTTPServerRequestPart] = []
    /// What to do once you decide at a breakpoint.
    private var onDecision: ((PausedDecision) -> Void)?

    private init(
        id: ConnectionID,
        mode: Mode,
        engine: EngineContext,
        encoder: HTTPResponseEncoder?,
        decoder: ByteToMessageHandler<HTTPRequestDecoder>?
    ) {
        self.id = id
        self.mode = mode
        self.engine = engine
        self.encoder = encoder
        self.decoder = decoder
    }

    private var isHTTP2: Bool {
        if case .decrypted(_, http2: true) = mode { true } else { false }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    // MARK: - From the app

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if case .forwarding(let forwarding) = state, forwarding.requestEnded {
            queued.append(part)
            return
        }
        handle(part, context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        server?.channel?.flush()
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        let failure: ExchangeFailure = engine.isStopping ? .captureStopped : .appClosed
        switch state {
        case .forwarding(let forwarding):
            if forwarding.isPaused {
                engine.forgetPause(forwarding.exchange)
                onDecision = nil
            }
            if !forwarding.responseEnded {
                engine.emit(.failed(forwarding.exchange, failure, at: Date()))
            }
        case .tunnelRequested(let exchange, _), .tunnelConnecting(let exchange, _):
            engine.emit(.failed(exchange, failure, at: Date()))
        case .idle, .decryptRequested, .switching, .closed:
            break
        }
        state = .closed
        closeServer()
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // A slow app: stop reading from the server until the app catches up.
        _ = server?.channel?.setOption(.autoRead, value: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if error is HTTPParserError, case .idle = state {
            respond(.badRequest, "Reqly couldn't read this request.", context: context, close: true)
        } else {
            context.close(promise: nil)
        }
    }

    private func handle(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        switch (state, part) {
        case (.idle, .head(let head)):
            begin(head, context: context)
        case (.forwarding(var forwarding), .body(let buffer)):
            engine.emit(.requestBody(forwarding.exchange, Data(buffer.readableBytesView)))
            if forwarding.heldRequestBody != nil {
                forwarding.heldRequestBody?.append(contentsOf: buffer.readableBytesView)
                state = .forwarding(forwarding)
            } else {
                if forwarding.plan.localAnswer == nil {
                    server?.send(.body(.byteBuffer(buffer)))
                }
                if let body = forwarding.scriptRequest?.body, body.count < ScriptRunner.bodyLimit {
                    forwarding.scriptRequest?.body.append(contentsOf: buffer.readableBytesView)
                    state = .forwarding(forwarding)
                }
            }
        case (.forwarding(var forwarding), .end(let trailers)):
            forwarding.requestEnded = true
            state = .forwarding(forwarding)
            engine.emit(.requestEnd(forwarding.exchange, at: Date()))
            if let answer = forwarding.plan.localAnswer {
                answerLocally(answer, for: forwarding.exchange, context: context)
            } else if let body = forwarding.heldRequestBody {
                releaseHeldRequest(body, context: context)
            } else {
                sendEnd(trailers, for: forwarding.exchange, context: context)
            }
        case (.tunnelRequested(let exchange, let authority), .end):
            engine.emit(.requestEnd(exchange, at: Date()))
            openTunnel(exchange, to: authority, context: context)
        case (.decryptRequested(let pending), .end):
            openDecryptedTunnel(pending, context: context)
        case (.tunnelRequested, .body), (.decryptRequested, .body), (.idle, .body), (.idle, .end):
            // A CONNECT body, or the rest of a request that was already answered.
            break
        default:
            context.close(promise: nil)
        }
    }

    private func begin(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        var head = head
        if isHTTP2 {
            head.headers = Self.joiningCookies(head.headers)
        }
        let target: ProxyTarget
        switch mode {
        case .proxy:
            if head.method == .CONNECT {
                beginConnect(head, context: context)
                return
            }
            guard let proxyTarget = ProxyTarget(absoluteForm: head.uri) else {
                // Not a proxy request: someone opened Reqly's address in a browser, such as a
                // phone that's setting up.
                serveSetupPage(head, path: head.uri, context: context)
                return
            }
            if engine.isLoop(proxyTarget.authority), head.method == .GET || head.method == .HEAD {
                // The same page, for a device that uses Reqly as its proxy already.
                serveSetupPage(head, path: proxyTarget.originForm, context: context)
                return
            }
            target = proxyTarget
        case .decrypted(let authority, _):
            if head.method == .CONNECT {
                respond(
                    .methodNotAllowed, "Reqly doesn't open tunnels inside a decrypted connection.", context: context,
                    close: true)
                return
            }
            target = ProxyTarget(authority: authority, originForm: ProxyTarget.originForm(of: head.uri))
        case .reverse(let route):
            if head.method == .CONNECT {
                respond(
                    .methodNotAllowed, "A reverse proxy sends requests to one server, so it doesn't open tunnels.",
                    context: context, close: true)
                return
            }
            target = ProxyTarget(authority: route.authority, originForm: ProxyTarget.originForm(of: head.uri))
        }

        let exchange = engine.makeExchangeID()
        let scheme =
            switch mode {
            case .proxy: "http"
            case .decrypted: "https"
            case .reverse(let route): route.server.scheme
            }
        let request = RequestHead(head, scheme: scheme, authority: target.authority, target: target.originForm)
        engine.emit(.requestHead(exchange, id, request, at: Date()))
        if case .reverse(let route) = mode {
            engine.emit(.reverseProxy(exchange, route.localAddress))
        }
        if engine.isLoop(target.authority) {
            reject(exchange, .loopDetected, status: .loopDetected, context: context)
            return
        }
        var forwarding = Forwarding(exchange: exchange, appKeepsAlive: isHTTP2 || head.isKeepAlive)
        let rules = engine.rules
        forwarding.plan = RulePlan(
            rules.matching(method: request.method, host: request.host, port: request.port, target: request.target))
        forwarding.network = rules.networkConditions(for: request.host)
        if forwarding.plan.localAnswer != nil {
            // Answered here, once the request has all arrived.
            state = .forwarding(forwarding)
            return
        }

        var serverHead = head
        serverHead.uri = target.originForm
        // Reqly talks HTTP/1.1 to servers, whichever version the app used.
        serverHead.version = .http1_1
        serverHead.headers.remove(name: "Proxy-Connection")
        if case .reverse(let route) = mode {
            // The app named the reverse proxy; the server wants its own name.
            serverHead.headers.replaceOrAdd(name: "Host", value: route.server.hostHeader)
        }
        var destination = Destination(scheme: scheme, authority: target.authority, originForm: target.originForm)
        if let (rule, remote) = forwarding.plan.mapRemote, let mapped = destination.mapped(to: remote) {
            destination = mapped
            serverHead.uri = mapped.originForm
            serverHead.headers.replaceOrAdd(name: "Host", value: mapped.hostHeader)
            engine.emit(
                .ruleApplied(exchange, AppliedRule(name: rule.name, kind: .mapRemote, detail: "Sent to \(mapped.url)")))
        }
        for applied in RuleActions.rewrite(&serverHead, with: forwarding.plan.requestRewrites) {
            engine.emit(.ruleApplied(exchange, applied))
        }
        if forwarding.plan.holdsResponse {
            // A body that isn't compressed can be read and changed.
            serverHead.headers.replaceOrAdd(name: "Accept-Encoding", value: "identity")
        }
        if engine.isLoop(destination.authority) {
            reject(exchange, .loopDetected, status: .loopDetected, context: context)
            return
        }
        forwarding.destination = destination
        if !forwarding.plan.responseScripts.isEmpty {
            // A script's onResponse gets the request too, as it went to the server.
            forwarding.scriptRequest = ScriptRequest(serverHead, destination: destination, body: Data())
        }
        if forwarding.plan.holdsRequest {
            forwarding.serverHead = serverHead
            forwarding.heldRequestBody = Data()
            state = .forwarding(forwarding)
            return
        }
        state = .forwarding(forwarding)
        sendHead(serverHead, to: destination, over: forwarding.network, for: exchange, context: context)
    }

    /// Sends a request's head to its server, over the open connection if it goes to the same one
    /// over the same network. A connection opened before slow network changed isn't reused.
    ///
    /// An HTTP/1.1 connection carries one exchange after another. Over HTTP/2, each exchange gets
    /// a stream of its own on a connection the requests to that server share.
    private func sendHead(
        _ serverHead: HTTPRequestHead, to destination: Destination, over network: NetworkProfile?,
        for exchange: ExchangeID, context: ChannelHandlerContext
    ) {
        // HTTP/2 can't switch protocols, as WebSocket asks, and plain HTTP is HTTP/1.1.
        let switchesProtocols = serverHead.headers.contains(name: "Upgrade")
        let path = ServerPath(
            to: destination.authority, needsTunnel: destination.usesTLS || switchesProtocols, engine: engine)
        var serverHead = serverHead
        if case .forwardingProxy(let proxy) = path {
            // A proxy takes plain HTTP requests with the full URL.
            serverHead.uri = "http://\(destination.hostHeader)\(serverHead.uri)"
            if let authorization = proxy.authorization {
                serverHead.headers.replaceOrAdd(name: "Proxy-Authorization", value: authorization)
            }
        }
        if let proxy = path.proxy {
            engine.emit(.upstreamProxy(exchange, proxy.address))
        }
        let generation = engine.connectionGeneration
        if let server, !server.isStream, server.authority == destination.authority,
            server.usesTLS == destination.usesTLS, server.network == network, server.path == path,
            server.generation == generation, server.isOpen
        {
            engine.emit(.serverReused(exchange, address: server.address, tlsVersion: server.tlsVersion))
            engine.emit(.serverProtocol(exchange, "HTTP/1.1"))
            if let certificate = server.clientCertificate.presentedName {
                engine.emit(.clientCertificate(exchange, certificate))
            }
            server.send(.head(serverHead))
        } else {
            closeServer()
            let connection = ServerConnection(
                authority: destination.authority, usesTLS: destination.usesTLS, network: network,
                onlyHTTP1: !destination.usesTLS || switchesProtocols, path: path, generation: generation)
            connection.send(.head(serverHead))
            server = connection
            open(connection, for: exchange, context: context)
        }
    }

    /// Opens the way to the server: a stream on the HTTP/2 connection the requests to it share,
    /// or a connection of its own.
    private func open(_ connection: ServerConnection, for exchange: ExchangeID, context: ChannelHandlerContext) {
        guard !connection.onlyHTTP1 else {
            connect(connection, for: exchange, offeringHTTP2: false, pool: nil, context: context)
            return
        }
        let pool = engine.serverPool(on: context.eventLoop)
        switch pool.claim(connection.poolKey) {
        case .ready(let shared):
            reuse(shared, for: connection, exchange: exchange)
        case .wait:
            pool.wait(for: connection.poolKey) { [weak self] shared in
                guard let self, connection === self.server, let context = self.context else { return }
                if let shared, shared.isUsable {
                    self.reuse(shared, for: connection, exchange: exchange)
                } else {
                    // The server chose HTTP/1.1, or the connection failed: try one of its own.
                    self.connect(connection, for: exchange, offeringHTTP2: true, pool: nil, context: context)
                }
            }
        case .open:
            connect(connection, for: exchange, offeringHTTP2: true, pool: pool, context: context)
        case .openAlone:
            connect(connection, for: exchange, offeringHTTP2: false, pool: nil, context: context)
        }
    }

    /// Starts the exchange on a stream of a shared HTTP/2 connection.
    private func reuse(_ shared: HTTP2Connection, for connection: ServerConnection, exchange: ExchangeID) {
        engine.emit(.serverReused(exchange, address: shared.address, tlsVersion: shared.tlsVersion))
        engine.emit(.serverProtocol(exchange, "HTTP/2"))
        if let certificate = shared.clientCertificate.presentedName {
            engine.emit(.clientCertificate(exchange, certificate))
        }
        connection.tlsVersion = shared.tlsVersion
        openStream(on: shared, for: connection)
    }

    private func openStream(on shared: HTTP2Connection, for connection: ServerConnection) {
        guard let context else { return }
        connection.isStream = true
        connection.shared = shared
        connection.clientCertificate = shared.clientCertificate
        let owners = NIOLoopBound((client: self, connection: connection), eventLoop: context.eventLoop)
        let opened = context.eventLoop.makePromise(of: (any Channel).self)
        shared.multiplexer.createStreamChannel(promise: opened) { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandlers([
                    HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https),
                    HTTP2RequestCleaner(),
                    ServerResponseHandler(client: owners.value.client, connection: owners.value.connection),
                ])
            }
        }
        opened.futureResult.assumeIsolated().whenComplete { result in
            guard connection === self.server, self.context != nil else {
                if case .success(let stream) = result { stream.close(promise: nil) }
                return
            }
            switch result {
            case .success(let stream):
                connection.connected(to: stream)
                // A connection the pool no longer shares, or never did, closes after its last stream.
                let pool = self.engine.serverPool(on: stream.eventLoop)
                shared.openStreams += 1
                stream.closeFuture.assumeIsolated().whenComplete { _ in
                    shared.openStreams -= 1
                    if shared.openStreams == 0, !pool.contains(shared) {
                        shared.channel.close(promise: nil)
                    }
                }
            case .failure(let error):
                self.closeServer()
                self.fail(.cannotConnect(Self.describe(error)))
            }
        }
    }

    private func sendEnd(_ trailers: HTTPHeaders?, for exchange: ExchangeID, context: ChannelHandlerContext) {
        guard let server else { return }
        let sent = context.eventLoop.makePromise(of: Void.self)
        server.send(.end(trailers), flush: true, promise: sent)
        sent.futureResult.assumeIsolated().whenSuccess {
            // Once the response is over, the request's timing is too.
            guard case .forwarding(let current) = self.state, current.exchange == exchange else { return }
            self.engine.emit(.requestSent(exchange, at: Date()))
        }
    }

    private func beginConnect(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let authority = Authority(head.uri[...], defaultPort: 443) else {
            respond(.badRequest, "Reqly couldn't read the address in this request.", context: context, close: true)
            return
        }
        let request = RequestHead(head, scheme: "https", authority: authority, target: head.uri)
        if engine.isLoop(authority) {
            let exchange = engine.makeExchangeID()
            engine.emit(.requestHead(exchange, id, request, at: Date()))
            reject(exchange, .loopDetected, status: .loopDetected, context: context)
        } else if engine.shouldDecrypt(authority.host) {
            // No exchange for the tunnel itself: the requests inside it become the exchanges.
            state = .decryptRequested(PendingConnect(authority: authority, request: request, started: Date()))
        } else {
            let exchange = engine.makeExchangeID()
            engine.emit(.requestHead(exchange, id, request, at: Date()))
            if let (rule, block) = tunnelBlock(for: request) {
                blockTunnel(exchange, rule: rule, block: block, context: context)
            } else {
                state = .tunnelRequested(exchange, authority)
            }
        }
    }

    /// The Block rule that stops a tunnel before it opens. Inside a tunnel that isn't decrypted
    /// there are no methods or paths to see, so only a rule for the whole host does.
    private func tunnelBlock(for request: RequestHead) -> (Rule, Block)? {
        let rules = engine.rules.matching(method: request.method, host: request.host, port: request.port, target: "/")
        for rule in rules {
            guard case .block(let block) = rule.action else { continue }
            let path = rule.match.path.trimmingCharacters(in: .whitespaces)
            if path.isEmpty || path == "*" || path == "/*" {
                return (rule, block)
            }
        }
        return nil
    }

    private func blockTunnel(_ exchange: ExchangeID, rule: Rule, block: Block, context: ChannelHandlerContext) {
        engine.emit(.requestEnd(exchange, at: Date()))
        switch block {
        case .status(let code):
            engine.emit(
                .ruleApplied(exchange, AppliedRule(name: rule.name, kind: .block, detail: "Answered with \(code).")))
            let note = "Reqly blocked this connection with the rule “\(rule.name)”."
            respond(HTTPResponseStatus(statusCode: code), note, context: context, close: true, recordingAs: exchange)
        case .closeConnection:
            engine.emit(
                .ruleApplied(exchange, AppliedRule(name: rule.name, kind: .block, detail: "Closed the connection.")))
            engine.emit(.failed(exchange, .blocked(rule: rule.name), at: Date()))
            state = .closed
            context.close(promise: nil)
        }
    }

    private func drainQueue(context: ChannelHandlerContext) {
        let parts = queued
        queued = []
        for part in parts {
            if case .forwarding(let forwarding) = state, forwarding.requestEnded {
                queued.append(part)
            } else {
                handle(part, context: context)
            }
        }
    }

    // MARK: - Relaying requests

    /// Opens a connection of the exchange's own. Offering HTTP/2, the pipeline waits for the
    /// server to choose; a connection it shares goes to `pool`, for the requests that wait on it.
    /// They hear how the whole connection turned out, not how each address it tried did.
    private func connect(
        _ connection: ServerConnection, for exchange: ExchangeID, offeringHTTP2: Bool, pool: ServerPool?,
        context: ChannelHandlerContext
    ) {
        engine.emit(.serverConnecting(exchange, at: Date()))
        var tls: ServerTLS?
        if connection.usesTLS {
            guard let chosen = engine.clientTLS(for: connection.authority.host, offeringHTTP2: offeringHTTP2) else {
                pool?.opened(connection.poolKey, nil, serverChoseHTTP1: false)
                server = nil
                fail(.secureConnectionFailed("Reqly couldn't set up TLS."))
                return
            }
            tls = chosen
            // The exchange names the client certificate only once the server has asked for it.
            connection.clientCertificate = chosen.certificateUse
        }
        let negotiates = offeringHTTP2 && tls != nil
        let serverHostname = connection.authority.isIPAddress ? nil : connection.authority.host
        // The connection's tries share it, so the requests waiting on the pool hear from it once.
        let opening = ServerOpening(key: connection.poolKey, pool: pool)
        let owners = NIOLoopBound(
            (client: self, connection: connection, pool: pool, opening: opening), eventLoop: context.eventLoop)
        let connecting = ServerDialer.connect(
            to: connection.authority, path: connection.path, network: connection.network, on: context.eventLoop,
            resolved: { time in
                let (client, connection, _, _) = owners.value
                guard connection === client.server, client.context != nil else { return }
                client.engine.emit(.serverResolved(exchange, at: time))
            },
            configure: { [tls] channel in
                let pipeline = channel.pipeline.syncOperations
                try tls?.addHandler(to: channel, serverHostname: serverHostname)
                if negotiates {
                    let (client, connection, pool, opening) = owners.value
                    let negotiation = ServerNegotiationHandler(client: client, connection: connection, opening: opening)
                    try pipeline.addHandler(negotiation)
                    try pipeline.addHandler(
                        ApplicationProtocolNegotiationHandler { result, channel in
                            channel.eventLoop.makeCompletedFuture {
                                try client.serverChose(
                                    result, channel: channel, connection: connection, exchange: exchange,
                                    pool: pool, negotiation: negotiation)
                            }
                        })
                    return
                }
                let decoder = HTTPResponseDecoder(
                    leftOverBytesStrategy: .forwardBytes,
                    informationalResponseStrategy: .forward
                )
                try pipeline.addHandlers([
                    HTTPRequestEncoder(),
                    ByteToMessageHandler(decoder),
                    ServerResponseHandler(client: owners.value.client, connection: owners.value.connection),
                ])
            }
        )
        tls?.hold(until: connecting) { name in
            let (client, connection, _, _) = owners.value
            client.serverAskedForCertificate(name, on: connection, exchange: exchange)
        }
        connecting.assumeIsolated().whenComplete { result in
            if case .failure = result {
                // Every try failed, or the upstream proxy didn't open its tunnel.
                opening.finish(nil, serverChoseHTTP1: false)
            }
            self.serverConnectCompleted(connection, exchange: exchange, negotiates: negotiates, result: result)
        }
    }

    private func serverConnectCompleted(
        _ connection: ServerConnection,
        exchange: ExchangeID,
        negotiates: Bool,
        result: Result<any Channel, any Error>
    ) {
        guard connection === server, context != nil else {
            // The app moved on to another server, or went away, while this connection opened.
            // A connection that negotiates may still serve the requests waiting on it.
            if case .success(let channel) = result, !negotiates { channel.close(promise: nil) }
            return
        }
        switch result {
        case .success(let channel):
            // Before the parts go out: once they're written, the request is sent.
            engine.emit(.serverConnected(exchange, address: channel.remoteAddress?.addressAndPort, at: Date()))
            // Offering HTTP/2, the parts wait until the server has chosen.
            if !negotiates {
                engine.emit(.serverProtocol(exchange, "HTTP/1.1"))
                connection.connected(to: channel)
            }
        case .failure(let error):
            closeServer()
            fail(Self.connectFailure(for: error, certificate: connection.clientCertificate))
        }
    }

    /// The server asked for a client certificate, and Reqly presented the one named `name`.
    fileprivate func serverAskedForCertificate(_ name: String, on connection: ServerConnection, exchange: ExchangeID) {
        connection.clientCertificate = .presented(name)
        guard connection === server, context != nil else { return }
        engine.emit(.clientCertificate(exchange, name))
    }

    /// Why a connection to a server didn't open. `certificate` says whether Reqly has a client
    /// certificate for the server's host.
    static func connectFailure(for error: any Error, certificate: ClientCertificateUse) -> ExchangeFailure {
        if let error = error as? UpstreamProxyError {
            return .cannotConnect(error.reason)
        }
        if error is NIOSSLError || error is BoringSSLError {
            return serverFailure(for: error, certificate: certificate)
        }
        return .cannotConnect(describe(error))
    }

    /// The server chose a protocol in the TLS handshake: HTTP/2, to share through the pool, or
    /// HTTP/1.1, for this exchange alone.
    fileprivate func serverChose(
        _ result: ALPNResult, channel: any Channel, connection: ServerConnection, exchange: ExchangeID,
        pool: ServerPool?, negotiation: ServerNegotiationHandler
    ) throws {
        let pipeline = channel.pipeline.syncOperations
        let version = (try? pipeline.nioSSL_tlsVersion()) ?? nil
        let isCurrent = connection === server && context != nil
        if case .negotiated("h2") = result {
            let multiplexer = try pipeline.configureHTTP2Pipeline(
                mode: .client, connectionConfiguration: Self.http2Configuration, streamConfiguration: .init()
            ) { stream in
                // Servers don't start streams of their own here, since server push is off.
                stream.close(promise: nil)
                return stream.eventLoop.makeSucceededVoidFuture()
            }
            let shared = HTTP2Connection(
                key: connection.poolKey, channel: channel, multiplexer: multiplexer, tlsVersion: version?.number)
            shared.clientCertificate = connection.clientCertificate
            let owningPool = pool ?? engine.serverPool(on: channel.eventLoop)
            try pipeline.addHandler(HTTP2ConnectionWatcher(connection: shared, pool: owningPool))
            negotiation.finish(pool == nil ? nil : shared, serverChoseHTTP1: false)
            pipeline.removeHandler(negotiation, promise: nil)
            // A connection opened outside the pool is shared too, if the pool has none to the server.
            owningPool.adopt(shared)
            guard isCurrent else {
                if !owningPool.contains(shared) { channel.close(promise: nil) }
                return
            }
            serverSecured(version, from: connection)
            engine.emit(.serverProtocol(exchange, "HTTP/2"))
            openStream(on: shared, for: connection)
        } else {
            negotiation.finish(nil, serverChoseHTTP1: true)
            pipeline.removeHandler(negotiation, promise: nil)
            guard isCurrent else {
                channel.close(promise: nil)
                return
            }
            let decoder = HTTPResponseDecoder(
                leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .forward)
            try pipeline.addHandlers([
                HTTPRequestEncoder(), ByteToMessageHandler(decoder),
                ServerResponseHandler(client: self, connection: connection),
            ])
            serverSecured(version, from: connection)
            engine.emit(.serverProtocol(exchange, "HTTP/1.1"))
            connection.connected(to: channel)
        }
    }

    /// Settings for HTTP/2 connections to servers: room for big headers, and no server push.
    private static let http2Configuration: NIOHTTP2Handler.ConnectionConfiguration = {
        var configuration = NIOHTTP2Handler.ConnectionConfiguration()
        configuration.initialSettings = [
            HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
            HTTP2Setting(parameter: .maxHeaderListSize, value: 1 << 18),
            HTTP2Setting(parameter: .enablePush, value: 0),
        ]
        return configuration
    }()

    /// Times the lookup of a server's name. An IP address needs no lookup, so it gets NIO's
    /// resolver, which turns it straight into an address.
    static func timedResolver(
        for authority: Authority,
        on loop: any EventLoop,
        resolved: @escaping @Sendable (Date) -> Void
    ) -> (any Resolver & Sendable)? {
        #if os(Windows)
            return nil
        #else
            return authority.isIPAddress ? nil : TimedResolver(loop: loop, resolved: resolved)
        #endif
    }

    func serverRead(_ part: HTTPClientResponsePart, from connection: ServerConnection?) {
        guard connection === server, case .forwarding(var forwarding) = state, let context else { return }
        switch part {
        case .head(var head):
            if head.status.code < 200, head.status != .switchingProtocols {
                // An interim response such as 100 Continue: pass it on and keep waiting.
                context.writeAndFlush(wrapOutboundOut(.head(appHead(head))), promise: nil)
                return
            }
            forwarding.serverKeepsAlive = head.version.major >= 2 || head.isKeepAlive
            forwarding.switchingProtocols = head.status == .switchingProtocols
            forwarding.webSocket = WebSocketSettings(response: head)
            for applied in RuleActions.rewrite(&head, with: forwarding.plan.responseRewrites) {
                engine.emit(.ruleApplied(forwarding.exchange, applied))
            }
            rewriteRedirect(&head)
            if forwarding.plan.holdsResponse, !forwarding.switchingProtocols {
                forwarding.heldResponse = (head, Data())
                state = .forwarding(forwarding)
                return
            }
            forwarding.responseStarted = true
            state = .forwarding(forwarding)
            engine.emit(.responseHead(forwarding.exchange, ResponseHead(head), at: Date()))
            context.write(wrapOutboundOut(.head(appHead(head))), promise: nil)
        case .body(let buffer):
            if forwarding.heldResponse != nil {
                forwarding.heldResponse?.body.append(contentsOf: buffer.readableBytesView)
                state = .forwarding(forwarding)
                return
            }
            engine.emit(.responseBody(forwarding.exchange, Data(buffer.readableBytesView)))
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        case .end(let trailers):
            if let held = forwarding.heldResponse {
                forwarding.responseComplete = true
                state = .forwarding(forwarding)
                releaseHeldResponse(held, trailers: trailers, context: context)
                return
            }
            endResponse(trailers, context: context)
        }
    }

    /// Points a redirect to a reverse proxy's server back at the reverse proxy, so the app
    /// keeps going through it.
    private func rewriteRedirect(_ head: inout HTTPResponseHead) {
        guard case .reverse(let route) = mode, route.rewritesRedirects,
            let location = head.headers.first(name: "Location"),
            var components = URLComponents(string: location),
            let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased()
        else { return }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard scheme == route.server.scheme, host == route.server.host, port == route.server.port else { return }
        components.scheme = "http"
        components.host = "localhost"
        components.port = route.localPort
        if let local = components.string {
            head.headers.replaceOrAdd(name: "Location", value: local)
        }
    }

    /// The head as the app gets it. HTTP/2 has no connection-level headers; its codec rejects
    /// them. An app on HTTP/1.1 gets an HTTP/2 server's response as HTTP/1.1.
    private func appHead(_ head: HTTPResponseHead) -> HTTPResponseHead {
        var head = head
        guard isHTTP2 else {
            if head.version.major >= 2 {
                head.version = .http1_1
            }
            return head
        }
        for name in ["Connection", "Keep-Alive", "Proxy-Connection", "Transfer-Encoding", "Upgrade"] {
            head.headers.remove(name: name)
        }
        return head
    }

    /// Ends the response the app is getting, and moves on to what comes next.
    private func endResponse(_ trailers: HTTPHeaders?, context: ChannelHandlerContext) {
        guard case .forwarding(var forwarding) = state else { return }
        forwarding.responseEnded = true
        state = .forwarding(forwarding)
        if let trailers, !trailers.isEmpty {
            engine.emit(.responseTrailers(forwarding.exchange, Headers(trailers)))
        }
        engine.emit(.responseEnd(forwarding.exchange, at: Date()))
        let written = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: written)
        // An HTTP/2 stream is closed by now, and has nothing more to do.
        guard case .forwarding = state else { return }
        finish(forwarding, written: written.futureResult, context: context)
    }

    /// The TLS handshake with the server finished.
    func serverSecured(_ version: TLSVersion?, from connection: ServerConnection?) {
        guard let connection, connection === server, case .forwarding(let forwarding) = state else { return }
        connection.tlsVersion = version?.number
        engine.emit(.serverSecured(forwarding.exchange, tlsVersion: connection.tlsVersion, at: Date()))
    }

    func serverReadComplete(from connection: ServerConnection?) {
        guard connection === server else { return }
        context?.flush()
    }

    func serverInactive(_ connection: ServerConnection?) {
        guard connection === server else { return }
        server = nil
        guard isWaitingOnServer else { return }
        // A stream ends when its connection fails, and the connection knows why.
        if let failure = connection?.shared?.failure {
            fail(Self.serverFailure(for: failure, certificate: connection?.clientCertificate ?? .noCertificate))
        } else {
            fail(.serverClosed)
        }
    }

    /// The connection to the server failed, for example because its certificate isn't valid.
    func serverFailed(_ error: any Error, from connection: ServerConnection?) {
        guard connection === server else { return }
        server = nil
        if isWaitingOnServer {
            fail(Self.serverFailure(for: error, certificate: connection?.clientCertificate ?? .noCertificate))
        }
    }

    /// Whether the current exchange needs the server still. A request that's held hasn't gone
    /// to it yet, and a held response has all arrived.
    private var isWaitingOnServer: Bool {
        guard case .forwarding(let forwarding) = state else { return false }
        return forwarding.heldRequestBody == nil && !forwarding.responseComplete && forwarding.plan.localAnswer == nil
    }

    func serverWritabilityChanged(_ isWritable: Bool, from connection: ServerConnection?) {
        // A slow server: stop reading from the app until the server catches up.
        guard connection === server, let context else { return }
        _ = context.channel.setOption(.autoRead, value: isWritable)
    }

    private func finish(_ forwarding: Forwarding, written: EventLoopFuture<Void>, context: ChannelHandlerContext) {
        if forwarding.switchingProtocols, let channel = server?.channel {
            // The server agreed to switch protocols, as for a WebSocket. Bytes pass through untouched from now on.
            server = nil
            beginTunnel(
                forwarding.exchange, server: channel, reply: nil, webSocket: forwarding.webSocket, context: context)
            return
        }
        if !forwarding.serverKeepsAlive {
            closeServer()
        }
        if forwarding.appKeepsAlive, forwarding.serverKeepsAlive || isHTTP2, forwarding.requestEnded {
            state = .idle
            drainQueue(context: context)
        } else {
            state = .closed
            written.assumeIsolated().whenComplete { _ in context.close(promise: nil) }
        }
    }

    // MARK: - Rules

    /// Answers the request here, for a Block or Map Local rule, now that it has all arrived.
    private func answerLocally(_ answer: RulePlan.LocalAnswer, for exchange: ExchangeID, context: ChannelHandlerContext)
    {
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let engine = self.engine
        answer.reply(on: context.eventLoop) { reply, applied in
            let handler = handler.value
            guard case .forwarding(let current) = handler.state, current.exchange == exchange,
                let context = handler.context
            else { return }
            engine.emit(.ruleApplied(exchange, applied))
            switch reply {
            case .respond(let status, let contentType, let body):
                handler.respondLocally(status: status, contentType: contentType, body: body, context: context)
            case .closeConnection(let rule):
                engine.emit(.failed(exchange, .blocked(rule: rule), at: Date()))
                handler.state = .closed
                context.close(promise: nil)
            }
        }
    }

    /// Answers the app here, and records the answer the way a server's is recorded.
    private func respondLocally(status: Int, contentType: String, body: Data, context: ChannelHandlerContext) {
        guard case .forwarding(var forwarding) = state else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.count))
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)
        forwarding.responseStarted = true
        state = .forwarding(forwarding)
        engine.emit(.responseHead(forwarding.exchange, ResponseHead(head), at: Date()))
        if !body.isEmpty {
            engine.emit(.responseBody(forwarding.exchange, body))
        }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !body.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
        }
        endResponse(nil, context: context)
    }

    /// Sends on a request that was held whole: rewritten, and paused if a breakpoint asks.
    private func releaseHeldRequest(_ body: Data, context: ChannelHandlerContext) {
        guard case .forwarding(let forwarding) = state, let head = forwarding.serverHead,
            let destination = forwarding.destination
        else { return }
        var body = body
        for applied in RuleActions.rewrite(&body, part: .request, with: forwarding.plan.requestRewrites) {
            engine.emit(.ruleApplied(forwarding.exchange, applied))
        }
        let scripts = forwarding.plan.requestScripts
        guard !scripts.isEmpty else {
            pauseOrSendRequest(head, body: body, to: destination, context: context)
            return
        }
        // Scripts run on threads of their own, while the request waits.
        let exchange = forwarding.exchange
        let engine = self.engine
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loop = context.eventLoop
        let request = ScriptRequest(head, destination: destination, body: body)
        Task {
            let result = await engine.runRequestScripts(scripts, on: request, for: exchange)
            loop.execute {
                handler.value.requestScriptsFinished(result, head: head, destination: destination, exchange: exchange)
            }
        }
    }

    private func requestScriptsFinished(
        _ result: ScriptedRequest, head: HTTPRequestHead, destination: Destination, exchange: ExchangeID
    ) {
        guard let context, case .forwarding(var forwarding) = state, forwarding.exchange == exchange else { return }
        switch result {
        case .answer(let answer):
            // A script answered, so the request never reaches the server.
            forwarding.heldRequestBody = nil
            state = .forwarding(forwarding)
            deliver(answer.head, body: answer.body, trailers: nil, context: context)
        case .send(let request):
            let (head, destination) = request.applied(to: head, destination: destination)
            if engine.isLoop(destination.authority) {
                reject(exchange, .loopDetected, status: .loopDetected, context: context)
                return
            }
            pauseOrSendRequest(head, body: request.body, to: destination, context: context)
        }
    }

    /// Pauses a whole request at its breakpoint, if it has one, or sends it on.
    private func pauseOrSendRequest(
        _ head: HTTPRequestHead, body: Data, to destination: Destination, context: ChannelHandlerContext
    ) {
        guard case .forwarding(let forwarding) = state else { return }
        guard let rule = forwarding.plan.requestBreakpoint else {
            sendHeldRequest(head, body: body, to: destination, context: context)
            return
        }
        let request = RequestHead(head, scheme: destination.scheme, authority: destination.authority, target: head.uri)
        let message = PausedMessage.request(request, body: body)
        pause(message, at: rule, context: context) { [self] decision in
            switch decision {
            case .resume(.request(let edited, let editedBody)):
                noteEdits(from: message, to: .request(edited, body: editedBody), at: rule)
                var head = head
                head.method = HTTPMethod(rawValue: edited.method)
                head.uri = edited.target
                head.headers = HTTPHeaders(edited.headers.map { ($0.name, $0.value) })
                let editedDestination = Destination(
                    scheme: edited.scheme, authority: Authority(host: edited.host, port: edited.port),
                    originForm: edited.target)
                sendHeldRequest(head, body: editedBody, to: editedDestination, context: context)
            case .resume(.response):
                sendHeldRequest(head, body: body, to: destination, context: context)
            case .cancel:
                fail(.cancelledAtBreakpoint(part: .request))
            }
        }
    }

    /// Sends a whole request, framed for its body as it is now.
    private func sendHeldRequest(
        _ head: HTTPRequestHead, body: Data, to destination: Destination, context: ChannelHandlerContext
    ) {
        guard case .forwarding(var forwarding) = state else { return }
        forwarding.heldRequestBody = nil
        forwarding.destination = destination
        if forwarding.scriptRequest != nil {
            forwarding.scriptRequest = ScriptRequest(head, destination: destination, body: body)
        }
        state = .forwarding(forwarding)
        var head = head
        head.headers.remove(name: "Transfer-Encoding")
        head.headers.remove(name: "Content-Length")
        if !body.isEmpty {
            head.headers.add(name: "Content-Length", value: String(body.count))
        }
        sendHead(head, to: destination, over: forwarding.network, for: forwarding.exchange, context: context)
        if !body.isEmpty {
            server?.send(.body(.byteBuffer(ByteBuffer(bytes: body))))
        }
        sendEnd(nil, for: forwarding.exchange, context: context)
    }

    /// Gives the app a response that was held whole: unpacked, rewritten, and paused if a
    /// breakpoint asks.
    private func releaseHeldResponse(
        _ held: (head: HTTPResponseHead, body: Data), trailers: HTTPHeaders?, context: ChannelHandlerContext
    ) {
        guard case .forwarding(let forwarding) = state else { return }
        var head = held.head
        var body = held.body
        // The server may compress the body anyway. Unpacked, its text can be changed.
        if let encoding = head.headers.first(name: "Content-Encoding"), encoding.lowercased() != "identity",
            let unpacked = BodyDecoder.decode(body, contentEncoding: encoding)
        {
            body = unpacked
            head.headers.remove(name: "Content-Encoding")
        }
        for applied in RuleActions.rewrite(&body, part: .response, with: forwarding.plan.responseRewrites) {
            engine.emit(.ruleApplied(forwarding.exchange, applied))
        }
        let scripts = forwarding.plan.responseScripts
        guard !scripts.isEmpty, let request = forwarding.scriptRequest else {
            pauseOrDeliver(head, body: body, trailers: trailers, context: context)
            return
        }
        let exchange = forwarding.exchange
        let engine = self.engine
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loop = context.eventLoop
        let response = ScriptResponse(head, body: body)
        let received = head
        Task {
            let changed = await engine.runResponseScripts(scripts, on: response, to: request, for: exchange)
            loop.execute {
                let handler = handler.value
                guard let context = handler.context, case .forwarding(let current) = handler.state,
                    current.exchange == exchange
                else { return }
                handler.pauseOrDeliver(
                    changed.applied(to: received), body: changed.body, trailers: trailers, context: context)
            }
        }
    }

    /// Pauses a whole response at its breakpoint, if it has one, or gives it to the app.
    private func pauseOrDeliver(
        _ head: HTTPResponseHead, body: Data, trailers: HTTPHeaders?, context: ChannelHandlerContext
    ) {
        guard case .forwarding(let forwarding) = state else { return }
        guard let rule = forwarding.plan.responseBreakpoint else {
            deliver(head, body: body, trailers: trailers, context: context)
            return
        }
        let message = PausedMessage.response(ResponseHead(head), body: body)
        pause(message, at: rule, context: context) { [self] decision in
            switch decision {
            case .resume(.response(let edited, let editedBody)):
                noteEdits(from: message, to: .response(edited, body: editedBody), at: rule)
                var head = head
                head.status = HTTPResponseStatus(statusCode: edited.status, reasonPhrase: edited.reason)
                head.headers = HTTPHeaders(edited.headers.map { ($0.name, $0.value) })
                deliver(head, body: editedBody, trailers: trailers, context: context)
            case .resume(.request):
                deliver(head, body: body, trailers: trailers, context: context)
            case .cancel:
                fail(.cancelledAtBreakpoint(part: .response))
            }
        }
    }

    /// Sends a whole response to the app, framed for its body as it is now.
    private func deliver(_ head: HTTPResponseHead, body: Data, trailers: HTTPHeaders?, context: ChannelHandlerContext) {
        guard case .forwarding(var forwarding) = state else { return }
        var head = head
        let hasBody = !(100..<200).contains(head.status.code) && head.status.code != 204 && head.status.code != 304
        head.headers.remove(name: "Transfer-Encoding")
        if hasBody {
            head.headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
        }
        forwarding.responseStarted = true
        state = .forwarding(forwarding)
        engine.emit(.responseHead(forwarding.exchange, ResponseHead(head), at: Date()))
        if hasBody, !body.isEmpty {
            engine.emit(.responseBody(forwarding.exchange, body))
        }
        context.write(wrapOutboundOut(.head(appHead(head))), promise: nil)
        if hasBody, !body.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
        }
        endResponse(trailers, context: context)
    }

    /// Holds the exchange at a breakpoint. `decided` runs on this event loop once you choose.
    private func pause(
        _ message: PausedMessage, at rule: Rule, context: ChannelHandlerContext,
        then decided: @escaping (PausedDecision) -> Void
    ) {
        guard case .forwarding(var forwarding) = state else { return }
        let exchange = forwarding.exchange
        forwarding.isPaused = true
        state = .forwarding(forwarding)
        onDecision = decided
        engine.emit(
            .ruleApplied(
                exchange,
                AppliedRule(name: rule.name, kind: .breakpoint, detail: "Paused the \(message.part.rawValue).")))
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loop = context.eventLoop
        engine.pause(exchange, message, breakpoint: rule.name) { decision in
            loop.execute {
                handler.value.decide(decision, for: exchange)
            }
        }
    }

    /// Records what you changed at a breakpoint, such as "You changed the status and the body."
    private func noteEdits(from original: PausedMessage, to edited: PausedMessage, at rule: Rule) {
        guard case .forwarding(let forwarding) = state, let detail = RuleActions.edits(from: original, to: edited)
        else {
            return
        }
        engine.emit(.ruleApplied(forwarding.exchange, AppliedRule(name: rule.name, kind: .breakpoint, detail: detail)))
    }

    private func decide(_ decision: PausedDecision, for exchange: ExchangeID) {
        guard case .forwarding(var forwarding) = state, forwarding.exchange == exchange, forwarding.isPaused,
            let onDecision
        else { return }
        forwarding.isPaused = false
        state = .forwarding(forwarding)
        self.onDecision = nil
        if case .resume(let message) = decision {
            engine.emit(.resumed(exchange, message.part))
        }
        onDecision(decision)
    }

    /// Lets go of the server connection, then closes it. Closing calls `serverInactive` right
    /// away, and by then the connection mustn't belong to this exchange anymore, or a response
    /// that just finished would be reported as cut off.
    private func closeServer() {
        let closing = server
        server = nil
        closing?.close()
    }

    /// Ends the current exchange with an error. An app that hasn't seen a response yet gets a
    /// 502 that explains why; otherwise the connection closes, because the response can't be finished.
    private func fail(_ failure: ExchangeFailure) {
        guard case .forwarding(let forwarding) = state, let context else { return }
        engine.emit(.failed(forwarding.exchange, failure, at: Date()))
        closeServer()
        if forwarding.responseStarted {
            state = .closed
            context.close(promise: nil)
        } else {
            respond(.badGateway, failure.message, context: context, close: true)
        }
    }

    // MARK: - Tunnels

    private func openTunnel(_ exchange: ExchangeID, to authority: Authority, context: ChannelHandlerContext) {
        state = .tunnelConnecting(exchange, authority)
        engine.emit(.serverConnecting(exchange, at: Date()))
        let client = NIOLoopBound(self, eventLoop: context.eventLoop)
        let network = engine.rules.networkConditions(for: authority.host)
        // An encrypted tunnel goes through the upstream proxy's own tunnel, if there's one.
        let path = ServerPath(to: authority, needsTunnel: true, engine: engine)
        if let proxy = path.proxy {
            engine.emit(.upstreamProxy(exchange, proxy.address))
        }
        ServerDialer.connect(
            to: authority, path: path, network: network, on: context.eventLoop,
            resolved: { time in
                guard case .tunnelConnecting = client.value.state else { return }
                client.value.engine.emit(.serverResolved(exchange, at: time))
            },
            configure: { _ in }
        )
        .assumeIsolated()
        .whenComplete { result in
            guard case .tunnelConnecting = self.state, let context = self.context else {
                if case .success(let channel) = result { channel.close(promise: nil) }
                return
            }
            switch result {
            case .success(let channel):
                let address = channel.remoteAddress?.addressAndPort
                self.engine.emit(.serverConnected(exchange, address: address, at: Date()))
                self.engine.registerTunnel(
                    context.channel, host: authority.host, decrypted: false, network: network, proxy: path.proxy)
                let reply = ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")
                self.beginTunnel(exchange, server: channel, reply: reply, context: context)
            case .failure(let error):
                // The app's own TLS goes through the tunnel; Reqly presents no certificate in it.
                let failure = Self.connectFailure(for: error, certificate: .noCertificate)
                self.engine.emit(.failed(exchange, failure, at: Date()))
                self.respond(.badGateway, failure.message, context: context, close: true)
            }
        }
    }

    /// Hands this connection over to a tunnel: from now on bytes pass between the app and the
    /// server untouched. `reply` goes to the app once its HTTP handlers are gone.
    private func beginTunnel(
        _ exchange: ExchangeID,
        server: any Channel,
        reply: ByteBuffer?,
        webSocket: WebSocketSettings? = nil,
        context: ChannelHandlerContext
    ) {
        guard let encoder, let decoder else {
            // An HTTP/2 stream can't become a tunnel.
            server.close(promise: nil)
            context.close(promise: nil)
            return
        }
        state = .switching
        let engine = self.engine
        let app = context.channel
        let appPipeline = context.pipeline.syncOperations
        let serverPipeline = server.pipeline.syncOperations
        let (appSide, serverSide) = GlueHandler.matchedPair(
            record: TunnelRecord(exchange: exchange, engine: engine, webSocket: webSocket))
        var removals: [EventLoopFuture<Void>] = []
        do {
            try serverPipeline.addHandler(serverSide)
            try appPipeline.addHandler(appSide)
            // After a protocol switch the server connection still has HTTP handlers. Its decoder
            // goes last, so bytes the server already sent flow into the tunnel.
            if let encoder = try? serverPipeline.handler(type: HTTPRequestEncoder.self) {
                removals.append(serverPipeline.removeHandler(encoder))
            }
            if let handler = try? serverPipeline.handler(type: ServerResponseHandler.self) {
                removals.append(serverPipeline.removeHandler(handler))
            }
            if let decoder = try? serverPipeline.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self) {
                removals.append(serverPipeline.removeHandler(decoder))
            }
            // Same on the app side: the decoder goes last, so bytes the app already sent flow into the tunnel.
            removals.append(appPipeline.removeHandler(encoder))
            removals.append(appPipeline.removeHandler(context: context))
            removals.append(appPipeline.removeHandler(decoder))
        } catch {
            server.close(promise: nil)
            app.close(promise: nil)
            return
        }
        EventLoopFuture.andAllSucceed(removals, on: app.eventLoop).assumeIsolated().whenComplete { result in
            switch result {
            case .success:
                if let reply {
                    app.writeAndFlush(reply, promise: nil)
                }
                engine.emit(.tunnelOpened(exchange, at: Date()))
            case .failure:
                server.close(promise: nil)
                app.close(promise: nil)
            }
        }
    }

    /// Answers the app's `CONNECT` itself and takes the TLS handshake over with a certificate for
    /// the host, so the requests inside can be read.
    private func openDecryptedTunnel(_ pending: PendingConnect, context: ChannelHandlerContext) {
        let tlsContext: NIOSSLContext
        do {
            tlsContext = try engine.serverTLS(for: pending.authority.host)
        } catch {
            let exchange = engine.makeExchangeID()
            let failure = ExchangeFailure.secureConnectionFailed("Reqly couldn't make a certificate for this host.")
            engine.emit(.requestHead(exchange, id, pending.request, at: pending.started))
            reject(exchange, failure, status: .badGateway, context: context)
            return
        }
        guard let encoder, let decoder else { return }
        state = .switching
        let app = context.channel
        engine.registerTunnel(app, host: pending.authority.host, decrypted: true)
        let pipeline = context.pipeline.syncOperations
        let tls = NIOSSLServerHandler(context: tlsContext)
        var removals: [EventLoopFuture<Void>] = []
        do {
            try pipeline.addHandlers([
                tls, DecryptedTunnelHandler(engine: engine, connectionID: id, pending: pending),
            ])
            // The decoder goes last, so bytes the app already sent reach the TLS handler.
            removals.append(pipeline.removeHandler(encoder))
            removals.append(pipeline.removeHandler(context: context))
            removals.append(pipeline.removeHandler(decoder))
        } catch {
            app.close(promise: nil)
            return
        }
        EventLoopFuture.andAllSucceed(removals, on: app.eventLoop).assumeIsolated().whenComplete { result in
            guard case .success = result, let tlsHandler = try? app.pipeline.syncOperations.context(handler: tls) else {
                app.close(promise: nil)
                return
            }
            // Written from the TLS handler's place in the pipeline, so it goes out in plain text.
            // The app starts its TLS handshake when it reads this.
            let reply = ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")
            tlsHandler.writeAndFlush(NIOAny(reply), promise: nil)
        }
    }

    // MARK: - Answering the app directly

    private func reject(
        _ exchange: ExchangeID,
        _ failure: ExchangeFailure,
        status: HTTPResponseStatus,
        context: ChannelHandlerContext
    ) {
        engine.emit(.failed(exchange, failure, at: Date()))
        respond(status, failure.message, context: context, close: true)
    }

    /// Answers with Reqly's setup page for devices, or the certificate it offers. These are
    /// Reqly's own, so they aren't recorded as traffic.
    private func serveSetupPage(_ head: HTTPRequestHead, path: String, context: ChannelHandlerContext) {
        let path = String(path.prefix { $0 != "?" })
        guard head.method == .GET || head.method == .HEAD else {
            respond(.methodNotAllowed, "Reqly's setup page takes only GET requests.", context: context, close: true)
            return
        }
        let page = SetupPage(for: head, port: engine.listenPort, certificate: engine.rootCertificate)
        let answer = page.answer(for: path)
        let close = !head.isKeepAlive
        state = close ? .closed : .idle
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: answer.contentType)
        headers.add(name: "Content-Length", value: String(answer.body.count))
        headers.add(name: "Cache-Control", value: "no-store")
        for header in answer.headers {
            headers.add(name: header.name, value: header.value)
        }
        if close, !isHTTP2 {
            headers.add(name: "Connection", value: "close")
        }
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: answer.status, headers: headers))),
            promise: nil)
        if head.method != .HEAD {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: answer.body)))), promise: nil)
        }
        let written = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: written)
        if close {
            written.futureResult.assumeIsolated().whenComplete { _ in context.close(promise: nil) }
        }
    }

    /// Answers the app itself, for a request Reqly can't or won't forward. With `exchange`, the
    /// answer is recorded as the exchange's response.
    private func respond(
        _ status: HTTPResponseStatus, _ message: String, context: ChannelHandlerContext, close: Bool,
        recordingAs exchange: ExchangeID? = nil
    ) {
        state = close ? .closed : .idle
        let body = ByteBuffer(string: message + "\n")
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.readableBytes))
        if close, !isHTTP2 {
            headers.add(name: "Connection", value: "close")
        }
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        if let exchange {
            engine.emit(.responseHead(exchange, ResponseHead(head), at: Date()))
            engine.emit(.responseBody(exchange, Data(body.readableBytesView)))
            engine.emit(.responseEnd(exchange, at: Date()))
        }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        let written = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: written)
        if close {
            written.futureResult.assumeIsolated().whenComplete { _ in context.close(promise: nil) }
        }
    }

    /// HTTP/2 lets an app send each cookie in a header of its own, as Safari does, but an
    /// HTTP/1.1 server expects them in one Cookie header (RFC 9113, section 8.2.3).
    static func joiningCookies(_ headers: HTTPHeaders) -> HTTPHeaders {
        let cookies = headers["Cookie"]
        guard cookies.count > 1 else { return headers }
        var joined = HTTPHeaders()
        var isJoined = false
        for (name, value) in headers {
            if name.lowercased() != "cookie" {
                joined.add(name: name, value: value)
            } else if !isJoined {
                joined.add(name: name, value: cookies.joined(separator: "; "))
                isJoined = true
            }
        }
        return joined
    }

    /// A short, plain explanation of why a connection to a server failed.
    static func describe(_ error: any Error) -> String {
        if let error = error as? NIOConnectionError {
            if error.connectionErrors.isEmpty {
                return "the name \(error.host) didn't resolve."
            }
            if let refused = error.connectionErrors.first?.error as? IOError, refused.errnoCode == ECONNREFUSED {
                return "\(error.host) refused the connection."
            }
            return "\(error.host) didn't accept the connection."
        }
        if let error = error as? ChannelError, case .connectTimeout = error {
            return "the server didn't answer in time."
        }
        return String(describing: error)
    }

    /// Why the secure connection to a server failed, in plain words. `certificate` says whether
    /// Reqly has a client certificate for the server's host, and whether the server got it.
    static func serverFailure(for error: any Error, certificate: ClientCertificateUse) -> ExchangeFailure {
        let text = String(describing: error)
        if text.contains("CERTIFICATE_VERIFY_FAILED") || text.contains("unableToValidateCertificate") {
            return .serverCertificateInvalid("Your Mac doesn't trust the certificate the server sent.")
        }
        // A trusted certificate, but for other names. For a server reached by its IP address,
        // such as 127.0.0.1, the address is missing from the certificate.
        if let error = error as? NIOSSLExtraError, error == .failedToValidateHostname {
            return .serverCertificateInvalid("The certificate the server sent isn't for this host.")
        }
        // The server's alert says why it ended the handshake. Servers that turn a client
        // certificate down choose among several alerts to say so.
        switch certificate {
        case .presented:
            let rejections = [
                "CERTIFICATE_REQUIRED", "BAD_CERTIFICATE", "UNKNOWN_CA", "CERTIFICATE_UNKNOWN", "ACCESS_DENIED",
                "DECRYPT_ERROR", "UNSUPPORTED_CERTIFICATE", "CERTIFICATE_EXPIRED", "CERTIFICATE_REVOKED",
            ]
            if rejections.contains(where: { text.contains("ALERT_\($0)") }) {
                return .clientCertificateRejected
            }
        case .noCertificate:
            if text.contains("ALERT_CERTIFICATE_REQUIRED") || text.contains("ALERT_BAD_CERTIFICATE") {
                return .clientCertificateRequired
            }
            if text.contains("ALERT_HANDSHAKE_FAILURE") {
                // Servers on TLS 1.2 send this general alert when a client certificate they need
                // is missing, as well as for other problems.
                return .secureConnectionFailed(
                    "The secure handshake with the server failed. The server may require a client certificate, and Reqly has none for this host. Add one in Settings, under Client Certificates."
                )
            }
        case .ready:
            // Reqly has a certificate for the host, but the server never asked for it, so its
            // alert isn't about a client certificate.
            break
        }
        if error is NIOSSLError || error is BoringSSLError {
            return .secureConnectionFailed("The secure handshake with the server failed.")
        }
        return .serverClosed
    }
}
