import BodyKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS
import ReqlyModel
import Scripts

/// A request Reqly sends itself, such as one you composed or send again.
public struct OutgoingRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: Headers
    public var body: Data

    public init(method: String, url: URL, headers: Headers = Headers(), body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// The request again, as an app sent it. An encrypted connection has no request to send.
    public init?(resending request: RequestHead, body: Data) {
        guard request.method != "CONNECT", let url = request.url else { return nil }
        self.init(method: request.method, url: url, headers: request.headers, body: body)
    }
}

/// Sends an ``OutgoingRequest`` straight to its server, and reports it the way the proxy reports
/// an app's request, so it's recorded and timed like any other. The rules act on it as they do
/// on an app's requests.
enum SentRequest {
    /// How long the server may go quiet before Reqly gives up on the response.
    static let responseTimeout = TimeAmount.seconds(60)

    static func start(
        _ request: OutgoingRequest, engine: EngineContext, group: any EventLoopGroup
    ) -> (exchange: ExchangeID, connection: ConnectionID) {
        let exchange = engine.makeExchangeID()
        let connection = engine.makeConnectionID()
        let now = Date()
        engine.emit(.connectionOpened(connection, client: ClientAddress(ip: "", port: 0), at: now))
        let scheme = request.url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https", let host = request.url.host(), !host.isEmpty else {
            let head = RequestHead(
                method: request.method, scheme: scheme, host: request.url.host() ?? "", port: 0,
                target: request.url.absoluteString, headers: request.headers)
            engine.emit(.requestHead(exchange, connection, head, at: now))
            engine.emit(.sentByReqly(exchange))
            engine.emit(.failed(exchange, .invalidRequest("Reqly can send only http and https URLs."), at: now))
            engine.emit(.connectionClosed(connection, at: now))
            return (exchange, connection)
        }
        let authority = Authority(host: host.lowercased(), port: request.url.port ?? (scheme == "https" ? 443 : 80))
        var target = request.url.path(percentEncoded: true)
        if target.isEmpty {
            target = "/"
        }
        if let query = request.url.query(percentEncoded: true) {
            target += "?" + query
        }
        let destination = Destination(scheme: scheme, authority: authority, originForm: target)
        let head = RequestHead(
            method: request.method, scheme: scheme, host: authority.host, port: authority.port, target: target,
            headers: framed(request.headers, body: request.body, host: destination.hostHeader))
        engine.emit(.requestHead(exchange, connection, head, at: now))
        engine.emit(.sentByReqly(exchange))
        if !request.body.isEmpty {
            engine.emit(.requestBody(exchange, request.body))
        }
        engine.emit(.requestEnd(exchange, at: now))

        let rules = engine.rules
        let plan = RulePlan(rules.matching(method: head.method, host: head.host, port: head.port, target: head.target))
        let network = rules.networkConditions(for: head.host)
        let loop = group.next()
        loop.execute {
            let sent = SentExchange(
                exchange: exchange, connection: connection, engine: engine, loop: loop, plan: plan, network: network)
            sent.begin(head, body: request.body, to: destination)
        }
        return (exchange, connection)
    }

    /// The headers to send: the Host header if it's missing, and a Content-Length that matches
    /// the body, whatever the headers said before. Headers meant for a proxy are left out, since
    /// the request goes straight to the server.
    static func framed(_ headers: Headers, body: Data, host: String) -> Headers {
        var headers = headers
        for name in ["Content-Length", "Transfer-Encoding", "Proxy-Connection", "Proxy-Authorization"] {
            headers.remove(named: name)
        }
        if !headers.contains("Host") {
            headers = Headers([HeaderField(name: "Host", value: host)] + headers.fields)
        }
        if !body.isEmpty {
            headers.append(name: "Content-Length", value: String(body.count))
        }
        return headers
    }
}

/// One request Reqly sends itself, from the rules acting on it to its response. It lives on
/// one event loop.
final class SentExchange {
    let exchange: ExchangeID
    let connection: ConnectionID
    let engine: EngineContext
    let loop: any EventLoop
    let plan: RulePlan
    let network: NetworkProfile?
    /// The exchange completed or failed.
    private(set) var isFinished = false
    private var isClosed = false
    /// What the server sent after the response body, recorded as the exchange finishes.
    var trailers: Headers?
    /// The client certificate Reqly has for the server, by name, and whether the server got it.
    var clientCertificate = ClientCertificateUse.noCertificate
    /// The request as it went to the server, kept for scripts' `onResponse`.
    private var scriptRequest: ScriptRequest?

    init(
        exchange: ExchangeID, connection: ConnectionID, engine: EngineContext, loop: any EventLoop, plan: RulePlan,
        network: NetworkProfile?
    ) {
        self.exchange = exchange
        self.connection = connection
        self.engine = engine
        self.loop = loop
        self.plan = plan
        self.network = network
    }

    /// Lets the rules act on the request, then sends it.
    func begin(_ request: RequestHead, body: Data, to destination: Destination) {
        if let answer = plan.localAnswer {
            answerLocally(answer)
            return
        }
        var destination = destination
        var head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method), uri: request.target)
        for field in request.headers {
            head.headers.add(name: field.name, value: field.value)
        }
        if let (rule, remote) = plan.mapRemote, let mapped = destination.mapped(to: remote) {
            destination = mapped
            head.uri = mapped.originForm
            head.headers.replaceOrAdd(name: "Host", value: mapped.hostHeader)
            engine.emit(
                .ruleApplied(exchange, AppliedRule(name: rule.name, kind: .mapRemote, detail: "Sent to \(mapped.url)")))
        }
        for applied in RuleActions.rewrite(&head, with: plan.requestRewrites) {
            engine.emit(.ruleApplied(exchange, applied))
        }
        if plan.holdsResponse {
            // A body that isn't compressed can be read and changed.
            head.headers.replaceOrAdd(name: "Accept-Encoding", value: "identity")
        }
        var body = body
        for applied in RuleActions.rewrite(&body, part: .request, with: plan.requestRewrites) {
            engine.emit(.ruleApplied(exchange, applied))
        }
        let scripts = plan.requestScripts
        guard !scripts.isEmpty else {
            pauseOrSend(head, body: body, to: destination)
            return
        }
        let sent = NIOLoopBound(self, eventLoop: loop)
        let request = ScriptRequest(head, destination: destination, body: body)
        let (engine, exchange, loop) = (self.engine, self.exchange, self.loop)
        let (original, planned) = (head, destination)
        Task {
            let result = await engine.runRequestScripts(scripts, on: request, for: exchange)
            loop.execute {
                let sent = sent.value
                switch result {
                case .answer(let answer):
                    sent.deliver(answer.head, body: answer.body)
                    sent.closeConnection()
                case .send(let request):
                    let (head, destination) = request.applied(to: original, destination: planned)
                    sent.pauseOrSend(head, body: request.body, to: destination)
                }
            }
        }
    }

    /// Pauses the whole request at its breakpoint, if it has one, or sends it.
    private func pauseOrSend(_ head: HTTPRequestHead, body: Data, to destination: Destination) {
        guard let rule = plan.requestBreakpoint else {
            send(head, body: body, to: destination)
            return
        }
        let message = PausedMessage.request(
            RequestHead(head, scheme: destination.scheme, authority: destination.authority, target: head.uri),
            body: body)
        pause(message, at: rule) { [self] decision in
            switch decision {
            case .resume(.request(let edited, let editedBody)):
                note(from: message, to: .request(edited, body: editedBody), at: rule)
                var head = head
                head.method = HTTPMethod(rawValue: edited.method)
                head.uri = edited.target
                head.headers = HTTPHeaders(edited.headers.map { ($0.name, $0.value) })
                let editedDestination = Destination(
                    scheme: edited.scheme, authority: Authority(host: edited.host, port: edited.port),
                    originForm: edited.target)
                send(head, body: editedBody, to: editedDestination)
            case .resume(.response):
                send(head, body: body, to: destination)
            case .cancel:
                fail(.cancelledAtBreakpoint(part: .request))
                closeConnection()
            }
        }
    }

    /// Answers here, for a Block or Map Local rule, without asking the server.
    private func answerLocally(_ answer: RulePlan.LocalAnswer) {
        let sent = NIOLoopBound(self, eventLoop: loop)
        answer.reply(on: loop) { reply, applied in
            let sent = sent.value
            sent.engine.emit(.ruleApplied(sent.exchange, applied))
            switch reply {
            case .respond(let status, let contentType, let body):
                var head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status))
                head.headers.add(name: "Content-Type", value: contentType)
                sent.deliver(head, body: body)
            case .closeConnection(let rule):
                sent.fail(.blocked(rule: rule))
            }
            sent.closeConnection()
        }
    }

    /// Connects to the server and sends the whole request, framed for its body as it is now.
    private func send(_ head: HTTPRequestHead, body: Data, to destination: Destination) {
        guard !isFinished else { return }
        if !plan.responseScripts.isEmpty {
            scriptRequest = ScriptRequest(head, destination: destination, body: body)
        }
        var head = head
        head.headers.remove(name: "Transfer-Encoding")
        head.headers.remove(name: "Content-Length")
        if !body.isEmpty {
            head.headers.add(name: "Content-Length", value: String(body.count))
        }
        let authority = destination.authority
        var tls: ServerTLS?
        if destination.usesTLS {
            guard let chosen = engine.clientTLS(for: authority.host, offeringHTTP2: false) else {
                fail(.secureConnectionFailed("Reqly couldn't set up TLS."))
                closeConnection()
                return
            }
            tls = chosen
            // The exchange names the client certificate only once the server has asked for it.
            clientCertificate = chosen.certificateUse
        }
        let path = ServerPath(
            to: authority, needsTunnel: destination.usesTLS || head.headers.contains(name: "Upgrade"), engine: engine)
        if case .forwardingProxy(let proxy) = path {
            // A proxy takes plain HTTP requests with the full URL.
            head.uri = "http://\(destination.hostHeader)\(head.uri)"
            if let authorization = proxy.authorization {
                head.headers.replaceOrAdd(name: "Proxy-Authorization", value: authorization)
            }
        }
        let serverHostname = authority.isIPAddress ? nil : authority.host
        let network = self.network
        engine.emit(.serverConnecting(exchange, at: Date()))
        if let proxy = path.proxy {
            engine.emit(.upstreamProxy(exchange, proxy.address))
        }
        let sent = NIOLoopBound(self, eventLoop: loop)
        let connecting = ServerDialer.connect(
            to: authority, path: path, network: network, on: loop,
            resolved: { [engine, exchange] time in
                engine.emit(.serverResolved(exchange, at: time))
            },
            configure: { [tls] channel in
                let pipeline = channel.pipeline.syncOperations
                try tls?.addHandler(to: channel, serverHostname: serverHostname)
                let decoder = HTTPResponseDecoder(
                    leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .forward)
                try pipeline.addHandlers([
                    HTTPRequestEncoder(),
                    ByteToMessageHandler(decoder),
                    IdleStateHandler(readTimeout: SentRequest.responseTimeout),
                    SentRequestHandler(sent: sent.value),
                ])
            }
        )
        tls?.hold(until: connecting) { name in
            sent.value.serverAskedForCertificate(name)
        }
        connecting.assumeIsolated().whenComplete { [self] result in
            switch result {
            case .success(let channel):
                engine.emit(.serverConnected(exchange, address: channel.remoteAddress?.addressAndPort, at: Date()))
                channel.write(HTTPClientRequestPart.head(head), promise: nil)
                if !body.isEmpty {
                    channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
                }
                channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenSuccess { [engine, exchange] in
                    engine.emit(.requestSent(exchange, at: Date()))
                }
            case .failure(let error):
                fail(ClientConnectionHandler.connectFailure(for: error, certificate: clientCertificate))
                closeConnection()
            }
        }
    }

    /// The server's response arrived whole, as the rules asked: unpacked, rewritten, and
    /// paused if a breakpoint asks.
    func release(_ head: HTTPResponseHead, body: Data, channel: any Channel) {
        var head = head
        var body = body
        // The server may compress the body anyway. Unpacked, its text can be changed.
        if let encoding = head.headers.first(name: "Content-Encoding"), encoding.lowercased() != "identity",
            let unpacked = BodyDecoder.decode(body, contentEncoding: encoding)
        {
            body = unpacked
            head.headers.remove(name: "Content-Encoding")
        }
        for applied in RuleActions.rewrite(&body, part: .response, with: plan.responseRewrites) {
            engine.emit(.ruleApplied(exchange, applied))
        }
        let scripts = plan.responseScripts
        guard !scripts.isEmpty, let request = scriptRequest else {
            pauseOrDeliver(head, body: body, channel: channel)
            return
        }
        let sent = NIOLoopBound(self, eventLoop: loop)
        let response = ScriptResponse(head, body: body)
        let (engine, exchange, loop) = (self.engine, self.exchange, self.loop)
        let received = head
        Task {
            let changed = await engine.runResponseScripts(scripts, on: response, to: request, for: exchange)
            loop.execute {
                sent.value.pauseOrDeliver(changed.applied(to: received), body: changed.body, channel: channel)
            }
        }
    }

    /// Pauses the whole response at its breakpoint, if it has one, or records it.
    private func pauseOrDeliver(_ head: HTTPResponseHead, body: Data, channel: any Channel) {
        guard let rule = plan.responseBreakpoint else {
            deliver(head, body: body)
            channel.close(promise: nil)
            return
        }
        let message = PausedMessage.response(ResponseHead(head), body: body)
        pause(message, at: rule) { [self] decision in
            switch decision {
            case .resume(.response(let edited, let editedBody)):
                note(from: message, to: .response(edited, body: editedBody), at: rule)
                var head = head
                head.status = HTTPResponseStatus(statusCode: edited.status, reasonPhrase: edited.reason)
                head.headers = HTTPHeaders(edited.headers.map { ($0.name, $0.value) })
                deliver(head, body: editedBody)
            case .resume(.request):
                deliver(head, body: body)
            case .cancel:
                fail(.cancelledAtBreakpoint(part: .response))
            }
            channel.close(promise: nil)
        }
    }

    /// Records a whole response, framed for its body as it is now.
    private func deliver(_ head: HTTPResponseHead, body: Data) {
        guard !isFinished else { return }
        var head = head
        head.headers.remove(name: "Transfer-Encoding")
        head.headers.remove(name: "Content-Length")
        let hasBody = !(100..<200).contains(head.status.code) && head.status.code != 204 && head.status.code != 304
        if hasBody {
            head.headers.add(name: "Content-Length", value: String(body.count))
        }
        engine.emit(.responseHead(exchange, ResponseHead(head), at: Date()))
        if hasBody, !body.isEmpty {
            engine.emit(.responseBody(exchange, body))
        }
        finish()
    }

    /// The server asked for a client certificate, and Reqly presented the one named `name`.
    func serverAskedForCertificate(_ name: String) {
        clientCertificate = .presented(name)
        engine.emit(.clientCertificate(exchange, name))
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        if let trailers {
            engine.emit(.responseTrailers(exchange, trailers))
        }
        engine.emit(.responseEnd(exchange, at: Date()))
    }

    func fail(_ failure: ExchangeFailure) {
        guard !isFinished else { return }
        isFinished = true
        engine.emit(.failed(exchange, failure, at: Date()))
    }

    /// Reports the connection closed, once, whether or not one ever opened.
    func closeConnection() {
        guard !isClosed else { return }
        isClosed = true
        engine.emit(.connectionClosed(connection, at: Date()))
    }

    private func pause(_ message: PausedMessage, at rule: Rule, then decided: @escaping (PausedDecision) -> Void) {
        engine.emit(
            .ruleApplied(
                exchange,
                AppliedRule(name: rule.name, kind: .breakpoint, detail: "Paused the \(message.part.rawValue).")))
        let waiting = NIOLoopBound((sent: self, decided: decided), eventLoop: loop)
        engine.pause(exchange, message, breakpoint: rule.name) { [loop] decision in
            loop.execute {
                let (sent, decided) = waiting.value
                guard !sent.isFinished else { return }
                if case .resume(let message) = decision {
                    sent.engine.emit(.resumed(sent.exchange, message.part))
                }
                decided(decision)
            }
        }
    }

    /// Records what you changed at a breakpoint.
    private func note(from original: PausedMessage, to edited: PausedMessage, at rule: Rule) {
        guard let detail = RuleActions.edits(from: original, to: edited) else { return }
        engine.emit(.ruleApplied(exchange, AppliedRule(name: rule.name, kind: .breakpoint, detail: detail)))
    }
}

/// Reports the response to a request Reqly sent, then closes the connection. A response the
/// rules need whole is held until it has all arrived.
final class SentRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let sent: SentExchange
    /// The response so far, while the rules need it whole.
    private var held: (head: HTTPResponseHead, body: Data)?
    /// The whole response arrived, so the server going quiet, or away, is no failure.
    private var hasEnded = false

    init(sent: SentExchange) {
        self.sent = sent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !sent.isFinished, !hasEnded else { return }
        switch unwrapInboundIn(data) {
        case .head(var head):
            // An interim response such as 100 Continue: the real one comes next.
            guard head.status.code >= 200 || head.status == .switchingProtocols else { return }
            for applied in RuleActions.rewrite(&head, with: sent.plan.responseRewrites) {
                sent.engine.emit(.ruleApplied(sent.exchange, applied))
            }
            if sent.plan.holdsResponse, head.status != .switchingProtocols {
                held = (head, Data())
            } else {
                sent.engine.emit(.responseHead(sent.exchange, ResponseHead(head), at: Date()))
            }
        case .body(let buffer):
            if held != nil {
                held?.body.append(contentsOf: buffer.readableBytesView)
            } else {
                sent.engine.emit(.responseBody(sent.exchange, Data(buffer.readableBytesView)))
            }
        case .end(let trailers):
            hasEnded = true
            if let trailers, !trailers.isEmpty {
                sent.trailers = Headers(trailers)
            }
            if let held {
                self.held = nil
                sent.release(held.head, body: held.body, channel: context.channel)
            } else {
                sent.finish()
                context.close(promise: nil)
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent {
            let version = (try? context.pipeline.syncOperations.nioSSL_tlsVersion()) ?? nil
            sent.engine.emit(.serverSecured(sent.exchange, tlsVersion: version?.number, at: Date()))
        } else if event is IdleStateHandler.IdleStateEvent, !hasEnded {
            sent.fail(.timedOut)
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !hasEnded {
            sent.fail(.serverClosed)
        }
        sent.closeConnection()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !hasEnded {
            sent.fail(ClientConnectionHandler.serverFailure(for: error, certificate: sent.clientCertificate))
        }
        context.close(promise: nil)
    }
}
