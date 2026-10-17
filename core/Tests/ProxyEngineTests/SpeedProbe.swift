import CertificateAuthority
import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import ProxyEngine
import ReqlyModel
import X509

/// The speed probe's measurements, which `SpeedProbeTests` runs. Each says how fast its traffic
/// went straight to the website, through the engine in this process, and, with
/// `REQLY_SPEED_APP=127.0.0.1:9091`, through a Reqly that's running.
///
/// It needs only `TestSupport.swift` besides, so a program can run it too: on Windows, where a
/// release build's tests aren't found, it runs as an executable built from these two files.
enum SpeedProbe {
    /// The measurements, by name, each returning its line.
    static let all: [(name: String, run: @Sendable () async throws -> String)] = [
        ("websitesRoot", { "the website's root is \(try websiteRoot().name)" }),
        ("smallRequestsOneAtATime", smallRequestsOneAtATime),
        ("smallRequestsSixteenAtATime", smallRequestsSixteenAtATime),
        ("plainDownload", plainDownload),
        ("httpsOneAtATime", httpsOneAtATime),
        ("httpsDownload", httpsDownload),
        ("ciphers", ciphers),
    ]

    static func smallRequestsOneAtATime() async throws -> String {
        try await withProbe { probe in
            var line = "small requests, one at a time: straight \(try await probe.oneAtATime(through: nil))"
            line += " · engine \(try await probe.oneAtATime(through: probe.enginePort))"
            if let app = probe.appPort {
                line += " · app \(try await probe.oneAtATime(through: app))"
            }
            return line
        }
    }

    static func smallRequestsSixteenAtATime() async throws -> String {
        try await withProbe { probe in
            var line = "small requests, 16 at a time: straight \(try await probe.sixteenAtATime(through: nil))"
            line += " · engine \(try await probe.sixteenAtATime(through: probe.enginePort))"
            if let app = probe.appPort {
                line += " · app \(try await probe.sixteenAtATime(through: app))"
            }
            return line
        }
    }

    static func plainDownload() async throws -> String {
        try await withProbe { probe in
            var line = "100 MB download, 3 times: straight \(try await probe.download(through: nil))"
            line += " · engine \(try await probe.download(through: probe.enginePort))"
            if let app = probe.appPort {
                line += " · app \(try await probe.download(through: app))"
            }
            return line
        }
    }

    static func httpsOneAtATime() async throws -> String {
        try await withProbe { probe in
            var line = "HTTPS small requests, one at a time: straight \(try await probe.secureOneAtATime(.straight))"
            line += " · engine, decrypted \(try await probe.secureOneAtATime(.engine))"
            if probe.appPort != nil {
                // A running Reqly either decrypts the website or doesn't.
                line +=
                    probe.appDecrypts
                    ? " · app, decrypted \(try await probe.secureOneAtATime(.appDecrypted))"
                    : " · app, not decrypted \(try await probe.secureOneAtATime(.appTunnel))"
            }
            return line
        }
    }

    static func httpsDownload() async throws -> String {
        try await withProbe { probe in
            var line = "50 MB HTTPS download, 3 times: straight \(try await probe.secureDownload(.straight))"
            line += " · engine, decrypted \(try await probe.secureDownload(.engine))"
            if probe.appPort != nil {
                line +=
                    probe.appDecrypts
                    ? " · app, decrypted \(try await probe.secureDownload(.appDecrypted))"
                    : " · app, not decrypted \(try await probe.secureDownload(.appTunnel))"
            }
            return line
        }
    }

    /// TLS alone, straight to the website: what each cipher costs on this computer.
    static func ciphers() async throws -> String {
        var runs: [String] = []
        for cipher in Cipher.allCases {
            let origin = try await BulkOrigin.start(tls: try websiteTLS(cipher))
            let tls = try appTLS(trusting: try websiteRoot(), cipher: cipher)
            let run = try await withSecureConnection(port: origin.port, tls: tls) { connection in
                try await downloads(on: &connection, path: "/bytes?n=\(50 << 20)", host: "127.0.0.1:\(origin.port)")
            }
            await origin.stop()
            runs.append("\(cipher.rawValue) \(run)")
        }
        return "TLS alone, a 50 MB download 3 times: " + runs.joined(separator: " · ")
    }

    enum Cipher: String, CaseIterable {
        case tls13 = "TLS 1.3 as the two sides choose"
        case aesGCM = "TLS 1.2 AES-128-GCM"
        case chacha = "TLS 1.2 ChaCha20-Poly1305"

        var suite: String? {
            switch self {
            case .tls13: nil
            case .aesGCM: "ECDHE-ECDSA-AES128-GCM-SHA256"
            case .chacha: "ECDHE-ECDSA-CHACHA20-POLY1305"
            }
        }
    }

    enum Route { case straight, engine, appTunnel, appDecrypted }

    static let environment = ProcessInfo.processInfo.environment

    /// The website's root: kept in `REQLY_SPEED_ROOT`, if that names a folder, so a running Reqly
    /// can trust it.
    static func websiteRoot() throws -> RootIdentity {
        guard let folder = environment["REQLY_SPEED_ROOT"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            return try sharedRoot.get()
        }
        let certificateFile = folder.appendingPathComponent("root.pem")
        let keyFile = folder.appendingPathComponent("root-key.pem")
        if let certificate = try? String(contentsOf: certificateFile, encoding: .utf8),
            let key = try? String(contentsOf: keyFile, encoding: .utf8)
        {
            return RootIdentity(
                certificate: try Certificate(pemEncoded: certificate),
                key: try P256.Signing.PrivateKey(pemRepresentation: key))
        }
        let root = try RootIdentity.create()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try root.certificate.serializeAsPEM().pemString.write(to: certificateFile, atomically: true, encoding: .utf8)
        try root.key.pemRepresentation.write(to: keyFile, atomically: true, encoding: .utf8)
        return root
    }

    private static let sharedRoot = Result { try RootIdentity.create() }

    /// The website's TLS: TLS 1.3, or TLS 1.2 with one cipher.
    static func websiteTLS(_ cipher: Cipher = .tls13) throws -> NIOSSLContext {
        let identity = try CertificateAuthority(root: try websiteRoot()).identity(for: "127.0.0.1")
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try identity.certificateChain.map {
                .certificate(try NIOSSLCertificate(bytes: $0, format: .der))
            },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem)))
        configuration.applicationProtocols = ["http/1.1"]
        if let suite = cipher.suite {
            configuration.maximumTLSVersion = .tlsv12
            configuration.cipherSuites = suite
        }
        return try NIOSSLContext(configuration: configuration)
    }

    /// An app's TLS, trusting `root`, or anything.
    static func appTLS(trusting root: RootIdentity?, cipher: Cipher = .tls13) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        if let root {
            configuration.trustRoots = .certificates([
                try NIOSSLCertificate(bytes: try root.certificateDER, format: .der)
            ])
        } else {
            configuration.certificateVerification = .none
        }
        configuration.applicationProtocols = ["http/1.1"]
        if let suite = cipher.suite {
            configuration.maximumTLSVersion = .tlsv12
            configuration.cipherSuites = suite
        }
        return try NIOSSLContext(configuration: configuration)
    }

    /// The websites, plain and HTTPS, and the engine, which decrypts the HTTPS one.
    struct Probe: Sendable {
        let plain: BulkOrigin
        let secure: BulkOrigin
        let enginePort: Int
        let reqlyRoot: RootIdentity
        let appPort: Int?
        let appDecrypts: Bool

        func oneAtATime(through proxy: Int?) async throws -> SpeedRun {
            let (port, uri) = target(through: proxy, path: "/small")
            _ = try await SpeedProbe.requests(port: port, uri: uri, count: 50)
            return try await SpeedProbe.requests(port: port, uri: uri, count: 2000)
        }

        func sixteenAtATime(through proxy: Int?) async throws -> SpeedRun {
            let (port, uri) = target(through: proxy, path: "/small")
            _ = try await SpeedProbe.requests(port: port, uri: uri, count: 50)
            let clock = ContinuousClock()
            let start = clock.now
            let times = try await withThrowingTaskGroup(of: [Duration].self) { group in
                for _ in 0..<16 {
                    group.addTask { try await SpeedProbe.requests(port: port, uri: uri, count: 250).times }
                }
                return try await group.reduce(into: []) { $0 += $1 }
            }
            return SpeedRun(times: times, total: clock.now - start, bytes: 0)
        }

        func download(through proxy: Int?) async throws -> SpeedRun {
            let (port, uri) = target(through: proxy, path: "/bytes?n=\(100 << 20)")
            let host = "127.0.0.1:\(plain.port)"
            return try await withProxyConnection(port: port) { connection in
                try await SpeedProbe.downloads(on: &connection, path: uri, host: host)
            }
        }

        func secureOneAtATime(_ route: Route) async throws -> SpeedRun {
            let host = "127.0.0.1:\(secure.port)"
            return try await connect(route) { connection in
                for _ in 0..<50 {
                    _ = try await connection.send(.GET, "/small", headers: ["Host": host])
                }
                var times: [Duration] = []
                let clock = ContinuousClock()
                let start = clock.now
                for _ in 0..<1000 {
                    let sent = clock.now
                    _ = try await connection.send(.GET, "/small", headers: ["Host": host])
                    times.append(clock.now - sent)
                }
                return SpeedRun(times: times, total: clock.now - start, bytes: 0)
            }
        }

        func secureDownload(_ route: Route) async throws -> SpeedRun {
            let host = "127.0.0.1:\(secure.port)"
            return try await connect(route) { connection in
                try await SpeedProbe.downloads(on: &connection, path: "/bytes?n=\(50 << 20)", host: host)
            }
        }

        private func connect<Result: Sendable>(
            _ route: Route, _ body: (inout HTTPConversation) async throws -> Result
        ) async throws -> Result {
            let website = try SpeedProbe.websiteRoot()
            let tunnel = "127.0.0.1:\(secure.port)"
            switch route {
            case .straight:
                return try await SpeedProbe.withSecureConnection(
                    port: secure.port, tls: try SpeedProbe.appTLS(trusting: website), body)
            case .engine:
                return try await SpeedProbe.withSecureConnection(
                    port: enginePort, tunnelTo: tunnel, tls: try SpeedProbe.appTLS(trusting: reqlyRoot), body)
            case .appTunnel:
                return try await SpeedProbe.withSecureConnection(
                    port: appPort!, tunnelTo: tunnel, tls: try SpeedProbe.appTLS(trusting: website), body)
            case .appDecrypted:
                // The app's root is its own, so the app's certificate isn't checked here.
                return try await SpeedProbe.withSecureConnection(
                    port: appPort!, tunnelTo: tunnel, tls: try SpeedProbe.appTLS(trusting: nil), body)
            }
        }

        private func target(through proxy: Int?, path: String) -> (port: Int, uri: String) {
            guard let proxy else { return (plain.port, path) }
            return (proxy, "http://127.0.0.1:\(plain.port)\(path)")
        }
    }

    static func withProbe<Result: Sendable>(_ body: (Probe) async throws -> Result) async throws -> Result {
        let plain = try await BulkOrigin.start(tls: nil)
        let secure = try await BulkOrigin.start(tls: try websiteTLS())
        let proxy = ProxyServer(extraTrustedRoots: [try websiteRoot().certificateDER])
        // What the engine reports goes nowhere: the engine alone is what's timed.
        let events = proxy.events
        let drain = Task {
            for await _ in events {}
        }
        let reqlyRoot = try RootIdentity.create()
        proxy.setDecryption(
            authority: try CertificateAuthority(root: reqlyRoot), hosts: [HostPattern(rawValue: "127.0.0.1")!])
        let enginePort = try await proxy.start(ProxyServer.Configuration(port: 0))
        let appPort = environment["REQLY_SPEED_APP"].flatMap { $0.split(separator: ":").last }.flatMap { Int($0) }
        let probe = Probe(
            plain: plain, secure: secure, enginePort: enginePort, reqlyRoot: reqlyRoot, appPort: appPort,
            appDecrypts: environment["REQLY_SPEED_APP_DECRYPTS"] != nil)
        func stop() async {
            await proxy.stop()
            drain.cancel()
            await plain.stop()
            await secure.stop()
        }
        do {
            let result = try await body(probe)
            await stop()
            return result
        } catch {
            await stop()
            throw error
        }
    }

    /// `count` requests, one after another on one connection.
    static func requests(port: Int, uri: String, count: Int) async throws -> SpeedRun {
        try await withProxyConnection(port: port) { connection in
            var times: [Duration] = []
            times.reserveCapacity(count)
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<count {
                let sent = clock.now
                let response = try await connection.send(.GET, uri, headers: ["Host": "127.0.0.1"])
                guard response.status == 200 else { throw TestError.connectionClosed }
                times.append(clock.now - sent)
            }
            return SpeedRun(times: times, total: clock.now - start, bytes: 0)
        }
    }

    /// Three downloads of `path`, one after another on the connection.
    static func downloads(on connection: inout HTTPConversation, path: String, host: String) async throws -> SpeedRun {
        let clock = ContinuousClock()
        let start = clock.now
        var bytes = 0
        for _ in 0..<3 {
            bytes += try await connection.download(path, host: host)
        }
        return SpeedRun(times: [], total: clock.now - start, bytes: bytes)
    }

    /// HTTPS on one connection: straight to `port`, or through the proxy on `port` with a tunnel to `target`.
    static func withSecureConnection<Result: Sendable>(
        port: Int, tunnelTo target: String? = nil, tls: NIOSSLContext,
        _ body: (inout HTTPConversation) async throws -> Result
    ) async throws -> Result {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let ready = loop.makePromise(of: Void.self)
        let channel = try await ClientBootstrap(group: loop)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let target {
                        try channel.pipeline.syncOperations.addHandler(
                            ProbeTunnel(target: target, tls: tls, ready: ready))
                    } else {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: tls, serverHostname: nil))
                        try channel.pipeline.syncOperations.addHTTPClientHandlers()
                        ready.succeed()
                    }
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        try await ready.futureResult.get()
        let wrapped = try await channel.eventLoop.submit {
            try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
        }.get()
        return try await wrapped.executeThenClose { inbound, outbound in
            var conversation = HTTPConversation(inbound: inbound.makeAsyncIterator(), outbound: outbound)
            return try await body(&conversation)
        }
    }
}

struct SpeedRun: Sendable, CustomStringConvertible {
    let times: [Duration]
    let total: Duration
    let bytes: Int

    var description: String {
        let seconds = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
        if bytes > 0 {
            return "\(Int(Double(bytes) / seconds / 1_048_576)) MB/s"
        }
        let sorted = times.sorted()
        func milliseconds(_ share: Double) -> String {
            let time = sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
            let value = Double(time.components.seconds) * 1000 + Double(time.components.attoseconds) / 1e15
            return String(format: "%.2f", value)
        }
        return "\(Int(Double(times.count) / seconds))/s, \(milliseconds(0.5)) ms each, "
            + "\(milliseconds(0.95)) ms at 95%, \(milliseconds(0.99)) ms at 99%, \(milliseconds(1)) ms the slowest"
    }
}

extension HTTPConversation {
    /// Asks for `uri` and counts the body's bytes, keeping none of them.
    mutating func download(_ uri: String, host: String) async throws -> Int {
        try await outbound.write(contentsOf: [
            .head(HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: ["Host": host])), .end(nil),
        ])
        var bytes = 0
        while let part = try await inbound.next() {
            switch part {
            case .head(let head):
                guard head.status == .ok else { throw TestError.connectionClosed }
            case .body(let buffer):
                bytes += buffer.readableBytes
            case .end:
                return bytes
            }
        }
        throw TestError.connectionClosed
    }
}

/// Asks the proxy for a tunnel to `target`, then starts TLS and HTTP inside it, as an app does.
final class ProbeTunnel: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let target: String
    private let tls: NIOSSLContext
    private let ready: EventLoopPromise<Void>
    private var reply = ""
    private var done = false

    init(target: String, tls: NIOSSLContext, ready: EventLoopPromise<Void>) {
        self.target = target
        self.tls = tls
        self.ready = ready
    }

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(
            NIOAny(ByteBuffer(string: "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")), promise: nil)
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
            // For an address, TLS checks the certificate against the address it connected to.
            try context.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: nil))
            try context.pipeline.syncOperations.addHTTPClientHandlers()
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            ready.succeed()
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

// MARK: - The website

/// A website for the probe, plain or HTTPS: `/small` answers with a little JSON, and
/// `/bytes?n=N` with N bytes, as fast as the connection takes them. Connections stay open.
final class BulkOrigin: Sendable {
    let port: Int
    private let channel: any Channel

    private init(channel: any Channel) {
        self.channel = channel
        port = channel.localAddress!.port!
    }

    static func start(tls: NIOSSLContext?) async throws -> BulkOrigin {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                    }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(BulkOriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return BulkOrigin(channel: channel)
    }

    func stop() async {
        try? await channel.close()
    }
}

final class BulkOriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let chunk = ByteBuffer(repeating: UInt8(ascii: "x"), count: 1 << 20)
    private static let small = ByteBuffer(
        string:
            #"{"city":"Lisbon","sky":"clear","wind":"light","temperature":21,"days":[{"sky":"clear"},{"sky":"rain"}]}"#)
    private var uri = "/"
    private var left = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            uri = head.uri
        case .body:
            break
        case .end:
            respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        let isBytes = uri.contains("/bytes")
        let count = isBytes ? Int(uri.split(separator: "=").last ?? "") ?? 0 : Self.small.readableBytes
        var headers: HTTPHeaders = ["Content-Length": String(count)]
        headers.add(name: "Content-Type", value: isBytes ? "application/octet-stream" : "application/json")
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        guard isBytes else {
            context.write(wrapOutboundOut(.body(.byteBuffer(Self.small))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            return
        }
        left = count
        sendMore(context: context)
    }

    /// As much as the connection takes now; the rest once it's writable again.
    private func sendMore(context: ChannelHandlerContext) {
        while left > 0, context.channel.isWritable {
            let size = min(left, Self.chunk.readableBytes)
            context.write(wrapOutboundOut(.body(.byteBuffer(Self.chunk.getSlice(at: 0, length: size)!))), promise: nil)
            left -= size
        }
        if left == 0 {
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        } else {
            context.flush()
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, left > 0 {
            sendMore(context: context)
        }
        context.fireChannelWritabilityChanged()
    }
}
