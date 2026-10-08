import CertificateAuthority
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import NIOTLS
import ReqlyModel
import Synchronization
import Testing

@testable import ProxyEngine

/// Decryption, end to end: an app asks for a tunnel, accepts Reqly's certificate, and speaks
/// HTTP/1.1 or HTTP/2 inside; Reqly reads the requests and sends them on to an HTTPS website.
/// Every certificate lives in memory. Nothing touches the keychain or the Mac's trust settings.
@Suite(.timeLimit(.minutes(1))) struct DecryptionTests {
    @Test func readsHTTP1RequestsInsideADecryptedTunnel() async throws {
        try await withDecryptingHarness { harness in
            let response = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(response.status == 200)
            #expect(response.body == "hello")

            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            let request = try #require(events.compactMap(\.requestHead).first)
            #expect(request.method == "GET")
            #expect(request.scheme == "https")
            #expect(request.target == "/hello")
            #expect(request.version == "HTTP/1.1")
            #expect(events.compactMap(\.responseData).reduce(Data(), +) == Data("hello".utf8))
            // The requests are the exchanges; the tunnel itself isn't one.
            #expect(!events.contains { $0.requestHead?.method == "CONNECT" })

            // The handshake with the server is timed between connecting and sending.
            let steps = ["serverConnected", "serverSecured", "requestSent", "responseHead"]
            #expect(events.map(\.name).filter(steps.contains) == steps)
            #expect(events.compactMap(\.tlsVersion) == ["1.3"])
        }
    }

    @Test func readsHTTP2Streams() async throws {
        try await withDecryptingHarness { harness in
            let multiplexer = try await harness.openSecureConnection(inside: .http2)
            async let hello = sendOverStream(multiplexer, .GET, "/hello", authority: harness.origin.authority)
            async let echo = sendOverStream(
                multiplexer, .POST, "/echo", authority: harness.origin.authority, body: "ping")
            let (first, second) = try await (hello, echo)
            #expect(first.status == 200)
            #expect(first.body == "hello")
            #expect(second.body == "ping")

            let events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 2 }
            let requests = events.compactMap(\.requestHead)
            #expect(requests.count == 2)
            #expect(events.compactMap(\.failure).isEmpty)
            #expect(requests.allSatisfy { $0.version == "HTTP/2" && $0.scheme == "https" })
            #expect(Set(requests.map(\.target)) == ["/hello", "/echo"])
        }
    }

    @Test func finishesHTTP2ResponsesWithoutABody() async throws {
        try await withDecryptingHarness { harness in
            let multiplexer = try await harness.openSecureConnection(inside: .http2)
            let response = try await sendOverStream(
                multiplexer, .POST, "/no-content", authority: harness.origin.authority, body: "{}")
            #expect(response.status == 204)

            // Writing the end closes the stream at once; that's the exchange finishing, not failing.
            try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            try await Task.sleep(for: .milliseconds(100))
            let events = try await harness.log.wait { _ in true }
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test func joinsSplitCookiesForTheServer() async throws {
        try await withDecryptingHarness { harness in
            let multiplexer = try await harness.openSecureConnection(inside: .http2)
            // HTTP/2 lets apps send each cookie in a header of its own, as Safari does.
            let cookies = HTTPHeaders([("cookie", "a=1"), ("cookie", "b=2"), ("cookie", "c=3")])
            let response = try await sendOverStream(
                multiplexer, .GET, "/cookies", authority: harness.origin.authority, headers: cookies)
            // HTTP/1.1 servers expect them in one header, which is also how Reqly records them.
            #expect(response.body == "a=1; b=2; c=3")
            let request = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }.compactMap(\.requestHead)
            #expect(request.first?.headers.values(named: "Cookie") == ["a=1; b=2; c=3"])
        }
    }

    @Test func recordsAnAppThatRejectsReqlysCertificate() async throws {
        try await withDecryptingHarness { harness in
            // This app trusts some other root, so it refuses the certificate Reqly presents.
            let stranger = try RootIdentity.create()
            await #expect(throws: (any Error).self) {
                _ = try await harness.withSecureConnection(inside: .http1, trusting: stranger) { app in
                    try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
                }
            }
            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(events.compactMap(\.failure) == [.certificateRejected])
            #expect(events.compactMap(\.requestHead).first?.method == "CONNECT")
        }
    }

    @Test func refusesServersWhoseCertificateTheMacDoesNotTrust() async throws {
        // This time Reqly doesn't trust the website's root.
        try await withDecryptingHarness(trustTheWebsite: false) { harness in
            let response = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(response.status == 502)
            #expect(response.body.contains("certificate"))
            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            guard case .serverCertificateInvalid = events.compactMap(\.failure).first else {
                Issue.record("Expected an invalid server certificate, got \(events.compactMap(\.failure))")
                return
            }
        }
    }

    @Test func refusesServersWhoseCertificateIsForAnotherHost() async throws {
        // Reqly trusts the website's root, but its certificate names localhost, not 127.0.0.1.
        try await withDecryptingHarness(originCertificateHost: "localhost") { harness in
            let response = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(response.status == 502)
            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(
                events.compactMap(\.failure) == [
                    .serverCertificateInvalid("The certificate the server sent isn't for this host.")
                ])
        }
    }

    @Test func stoppingDecryptionClosesDecryptedConnections() async throws {
        try await withDecryptingHarness { harness in
            try await harness.withSecureConnection(inside: .http1) { app in
                _ = try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
                // The host is no longer decrypted: its open connection closes, so the app reconnects.
                harness.proxy.setDecryption(authority: harness.authority, hosts: [])
                await #expect(throws: (any Error).self) { try await app.readResponse() }
            }
        }
    }

    @Test func decryptingAHostClosesItsEncryptedTunnels() async throws {
        try await withDecryptingHarness(decrypt: "*.weatherly.dev") { harness in
            try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send("CONNECT \(harness.origin.authority) HTTP/1.1\r\n\r\n")
                _ = try await app.read(through: "\r\n\r\n")
                try await harness.log.wait { $0.contains(where: \.isTunnelOpened) }
                // Now the host is decrypted: its encrypted tunnel closes, so the app reconnects.
                harness.proxy.setDecryption(authority: harness.authority, hosts: [HostPattern(rawValue: "127.0.0.1")!])
                _ = try await app.readToEnd()
            }
            try await harness.log.wait { $0.contains { $0.tunnelBytes != nil } }
        }
    }

    @Test func decryptsEveryHostButTheOnesSwitchedOff() async throws {
        try await withDecryptingHarness(decrypt: "*.weatherly.dev") { harness in
            let off = DecryptedHosts(
                entries: [.init(HostPattern(rawValue: "127.0.0.1")!, isOn: false)], includesEveryHost: true)
            harness.proxy.setDecryption(authority: harness.authority, hosts: off)
            let reply = try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send("CONNECT \(harness.origin.authority) HTTP/1.1\r\n\r\n")
                return try await app.read(through: "\r\n\r\n")
            }
            #expect(reply.hasPrefix("HTTP/1.1 200"))
            try await harness.log.wait { $0.contains(where: \.isTunnelOpened) }

            // Every host, with nothing switched off, includes this one.
            harness.proxy.setDecryption(authority: harness.authority, hosts: DecryptedHosts(includesEveryHost: true))
            let response = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(response.body == "hello")
        }
    }

    @Test func saysWhyAnAppsHandshakeFailed() {
        struct HandshakeError: Error, CustomStringConvertible {
            let description: String
        }
        let alert = HandshakeError(
            description:
                "handshakeFailed(sslError([Error: 268436496 error:10000410:SSL routines:OPENSSL_internal:SSLV3_ALERT_HANDSHAKE_FAILURE]))"
        )
        guard case .secureConnectionFailed(let reason) = DecryptedTunnelHandler.failure(for: alert) else {
            Issue.record("Expected a failed handshake")
            return
        }
        #expect(reason.contains("(handshake failure)"))
        #expect(reason.contains("current certificate"))
        #expect(
            DecryptedTunnelHandler.tlsReason(in: "error:100000b8:SSL routines:OPENSSL_internal:NO_SHARED_CIPHER")
                == "no shared cipher")
        #expect(DecryptedTunnelHandler.tlsReason(in: "uncleanShutdown") == nil)
        let rejection = HandshakeError(
            description: "error:10000416:SSL routines:OPENSSL_internal:SSLV3_ALERT_CERTIFICATE_UNKNOWN")
        #expect(DecryptedTunnelHandler.failure(for: rejection) == .certificateRejected)
        #expect(ExchangeFailure.certificateRejected.isDecryptionFailure)
        #expect(!ExchangeFailure.timedOut.isDecryptionFailure)
    }

    @Test func tunnelsHostsItDoesNotDecrypt() async throws {
        try await withDecryptingHarness(decrypt: "*.weatherly.dev") { harness in
            let reply = try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send("CONNECT \(harness.origin.authority) HTTP/1.1\r\n\r\n")
                return try await app.read(through: "\r\n\r\n")
            }
            #expect(reply.hasPrefix("HTTP/1.1 200"))
            let events = try await harness.log.wait { $0.contains(where: \.isTunnelOpened) }
            #expect(events.compactMap(\.requestHead).first?.method == "CONNECT")
        }
    }
}

// MARK: - Test support

/// A proxy that decrypts, and an HTTPS website with its own test root, started for one test.
struct DecryptingHarness {
    let proxy: ProxyServer
    let authority: CertificateAuthority
    let proxyPort: Int
    let origin: SecureOriginServer
    let reqlyRoot: RootIdentity
    let log: EventLog

    enum Inside { case http1, http2 }

    /// Connects through the proxy the way an app does for HTTPS: CONNECT, then TLS that trusts
    /// Reqly's root (or `root`), then HTTP inside. The tunnel goes to the website, or to `target`,
    /// such as `localhost:8443`.
    func withSecureConnection<Result: Sendable>(
        inside: Inside,
        trusting root: RootIdentity? = nil,
        to target: String? = nil,
        _ body: (inout HTTPConversation) async throws -> Result
    ) async throws -> Result {
        let channel = try await openTunnel(inside: inside, trusting: root ?? reqlyRoot, to: target).channel
        let wrapped = try await channel.eventLoop.submit {
            try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
        }.get()
        return try await wrapped.executeThenClose { inbound, outbound in
            var conversation = HTTPConversation(inbound: inbound.makeAsyncIterator(), outbound: outbound)
            return try await body(&conversation)
        }
    }

    func openSecureConnection(inside: Inside, to target: String? = nil) async throws
        -> NIOHTTP2Handler.StreamMultiplexer
    {
        guard let multiplexer = try await openTunnel(inside: inside, trusting: reqlyRoot, to: target).multiplexer
        else {
            throw TestError.connectionClosed
        }
        return multiplexer
    }

    private func openTunnel(
        inside: Inside,
        trusting root: RootIdentity,
        to target: String?
    ) async throws -> (channel: any Channel, multiplexer: NIOHTTP2Handler.StreamMultiplexer?) {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = .certificates([try NIOSSLCertificate(bytes: try root.certificateDER, format: .der)])
        configuration.applicationProtocols = inside == .http2 ? ["h2"] : ["http/1.1"]
        let tls = try NIOSSLContext(configuration: configuration)
        let target = target ?? origin.authority
        // The promise and the channel share an event loop, so the requester can fulfil it directly.
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let ready = loop.makePromise(of: NIOHTTP2Handler.StreamMultiplexer?.self)
        let channel: any Channel
        do {
            channel = try await ClientBootstrap(group: loop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            TunnelRequester(target: target, tls: tls, inside: inside, ready: ready))
                    }
                }
                .connect(host: "127.0.0.1", port: proxyPort)
                .get()
        } catch {
            ready.fail(error)
            throw error
        }
        return (channel, try await ready.futureResult.get())
    }
}

func withDecryptingHarness(
    trustTheWebsite: Bool = true,
    decrypt pattern: String = "127.0.0.1",
    http2Origin: Bool = false,
    clientCertificatesFrom clientRoot: RootIdentity? = nil,
    originCertificateHost: String = "127.0.0.1",
    originMaximumTLSVersion: TLSVersion? = nil,
    _ body: (DecryptingHarness) async throws -> Void
) async throws {
    let origin = try await SecureOriginServer.start(
        http2: http2Origin, clientCertificatesFrom: clientRoot, certificateHost: originCertificateHost,
        maximumTLSVersion: originMaximumTLSVersion)
    let proxy = ProxyServer(extraTrustedRoots: trustTheWebsite ? [try origin.root.certificateDER] : [])
    let log = EventLog(proxy.events)
    let reqlyRoot = try RootIdentity.create()
    let authority = try CertificateAuthority(root: reqlyRoot)
    proxy.setDecryption(authority: authority, hosts: [HostPattern(rawValue: pattern)!])
    let proxyPort = try await proxy.start(ProxyServer.Configuration(port: 0))
    do {
        try await body(
            DecryptingHarness(
                proxy: proxy, authority: authority, proxyPort: proxyPort, origin: origin, reqlyRoot: reqlyRoot, log: log
            ))
    } catch {
        await proxy.stop()
        await origin.stop()
        throw error
    }
    await proxy.stop()
    await origin.stop()
}

/// Sends one request on a new HTTP/2 stream.
func sendOverStream(
    _ multiplexer: NIOHTTP2Handler.StreamMultiplexer,
    _ method: HTTPMethod,
    _ path: String,
    authority: String,
    headers: HTTPHeaders = [:],
    body: String? = nil
) async throws -> TestResponse {
    let stream = try await multiplexer.createStreamChannel { stream in
        stream.eventLoop.makeCompletedFuture {
            try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
        }
    }.get()
    let wrapped = try await stream.eventLoop.submit {
        try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: stream)
    }.get()
    return try await wrapped.executeThenClose { inbound, outbound in
        var conversation = HTTPConversation(inbound: inbound.makeAsyncIterator(), outbound: outbound)
        var all: HTTPHeaders = ["Host": authority]
        all.add(contentsOf: headers)
        return try await conversation.send(method, path, headers: all, body: body)
    }
}

/// Asks the proxy for a tunnel, then starts TLS and HTTP inside it, the way an app does.
final class TunnelRequester: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let ready: EventLoopPromise<NIOHTTP2Handler.StreamMultiplexer?>
    private let target: String
    private let tls: NIOSSLContext
    private let inside: DecryptingHarness.Inside
    private var reply = ""
    private var done = false

    init(
        target: String,
        tls: NIOSSLContext,
        inside: DecryptingHarness.Inside,
        ready: EventLoopPromise<NIOHTTP2Handler.StreamMultiplexer?>
    ) {
        self.target = target
        self.tls = tls
        self.inside = inside
        self.ready = ready
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = ByteBuffer(string: "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")
        context.writeAndFlush(NIOAny(request), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        reply += String(buffer: unwrapInboundIn(data))
        guard reply.contains("\r\n\r\n"), !done else { return }
        done = true
        guard reply.hasPrefix("HTTP/1.1 200") else {
            ready.fail(TestError.connectionClosed)
            context.close(promise: nil)
            return
        }
        do {
            let pipeline = context.pipeline.syncOperations
            // To a name, the certificate Reqly makes has to be for it. Without one, for an
            // address, TLS checks the certificate against the address it connected to.
            let authority = Authority(target[...], defaultPort: 443)
            let name = authority.flatMap { $0.isIPAddress ? nil : $0.host }
            try pipeline.addHandler(NIOSSLClientHandler(context: tls, serverHostname: name))
            var multiplexer: NIOHTTP2Handler.StreamMultiplexer?
            switch inside {
            case .http1:
                try pipeline.addHTTPClientHandlers()
            case .http2:
                multiplexer = try pipeline.configureHTTP2Pipeline(
                    mode: .client, connectionConfiguration: .init(), streamConfiguration: .init()
                ) { $0.eventLoop.makeSucceededVoidFuture() }
            }
            pipeline.removeHandler(context: context, promise: nil)
            ready.succeed(multiplexer)
        } catch {
            ready.fail(error)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !done {
            done = true
            ready.fail(error)
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done {
            done = true
            ready.fail(TestError.connectionClosed)
        }
        context.fireChannelInactive()
    }
}

/// The test website over HTTPS, with a certificate for 127.0.0.1 from its own test root.
final class SecureOriginServer: Sendable {
    let port: Int
    let root: RootIdentity
    private let channel: any Channel
    private let accepted: Counter

    final class Counter: Sendable {
        let value = Atomic<Int>(0)
    }

    var authority: String { "127.0.0.1:\(port)" }

    /// How many connections the website accepted.
    var connectionCount: Int { accepted.value.load(ordering: .relaxed) }

    private init(channel: any Channel, root: RootIdentity, accepted: Counter) {
        self.channel = channel
        self.root = root
        self.accepted = accepted
        self.port = channel.localAddress!.port!
    }

    /// - Parameters:
    ///   - http2: Whether the website offers HTTP/2 as well as HTTP/1.1.
    ///   - clientRoot: Asks apps for a client certificate, which this root must have issued.
    ///   - certificateHost: The host its certificate is for. It listens on 127.0.0.1 whatever it is.
    ///   - maximumTLSVersion: The newest TLS version it speaks, such as 1.2 for an older server.
    static func start(
        http2: Bool = false, clientCertificatesFrom clientRoot: RootIdentity? = nil,
        certificateHost: String = "127.0.0.1", maximumTLSVersion: TLSVersion? = nil
    ) async throws -> SecureOriginServer {
        let root = try RootIdentity.create()
        let identity = try CertificateAuthority(root: root).identity(for: certificateHost)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try identity.certificateChain.map {
                .certificate(try NIOSSLCertificate(bytes: $0, format: .der))
            },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem))
        )
        configuration.applicationProtocols = http2 ? ["h2", "http/1.1"] : ["http/1.1"]
        configuration.maximumTLSVersion = maximumTLSVersion
        if let clientRoot {
            configuration.certificateVerification = .noHostnameVerification
            configuration.trustRoots = .certificates([
                try NIOSSLCertificate(bytes: try clientRoot.certificateDER, format: .der)
            ])
        }
        let tls = try NIOSSLContext(configuration: configuration)
        let accepted = Counter()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                accepted.value.add(1, ordering: .relaxed)
                return channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(NIOSSLServerHandler(context: tls))
                    guard http2 else {
                        try pipeline.configureHTTPServerPipeline()
                        try pipeline.addHandler(OriginHandler())
                        return
                    }
                    try pipeline.addHandler(
                        ApplicationProtocolNegotiationHandler { result, channel in
                            channel.eventLoop.makeCompletedFuture {
                                let pipeline = channel.pipeline.syncOperations
                                if case .negotiated("h2") = result {
                                    _ = try pipeline.configureHTTP2Pipeline(
                                        mode: .server, connectionConfiguration: .init(), streamConfiguration: .init()
                                    ) { stream in
                                        stream.eventLoop.makeCompletedFuture {
                                            try stream.pipeline.syncOperations.addHandlers([
                                                HTTP2FramePayloadToHTTP1ServerCodec(), OriginHandler(),
                                            ])
                                        }
                                    }
                                } else {
                                    try pipeline.configureHTTPServerPipeline()
                                    try pipeline.addHandler(OriginHandler())
                                }
                            }
                        })
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return SecureOriginServer(channel: channel, root: root, accepted: accepted)
    }

    func stop() async {
        try? await channel.close()
    }
}
