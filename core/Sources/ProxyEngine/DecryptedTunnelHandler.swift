import Foundation
import NIOCore
import NIOHTTP2
import NIOSSL
import NIOTLS
import ReqlyModel

/// A `CONNECT` to a host Reqly decrypts, waiting for its TLS handshake.
struct PendingConnect {
    let authority: Authority
    let request: RequestHead
    let started: Date
}

/// Sits behind the TLS handler of a decrypted tunnel. When the app accepts Reqly's certificate,
/// it sets up HTTP/2 or HTTP/1.1, whichever the app chose, and steps aside. When the app refuses
/// the certificate, it records the `CONNECT` as a failed exchange that says why.
final class DecryptedTunnelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    private let engine: EngineContext
    private let connectionID: ConnectionID
    private let pending: PendingConnect
    private var finished = false

    init(engine: EngineContext, connectionID: ConnectionID, pending: PendingConnect) {
        self.engine = engine
        self.connectionID = connectionID
        self.pending = pending
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted(let negotiated) = tlsEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        finished = true
        do {
            let engine = self.engine
            let connectionID = self.connectionID
            let authority = pending.authority
            if negotiated == "h2" {
                _ = try context.pipeline.syncOperations.configureHTTP2Pipeline(
                    mode: .server,
                    connectionConfiguration: .init(),
                    streamConfiguration: .init()
                ) { stream in
                    stream.eventLoop.makeCompletedFuture {
                        try ClientConnectionHandler.configureDecryptedStream(
                            stream, engine: engine, connectionID: connectionID, authority: authority)
                    }
                }
            } else {
                try ClientConnectionHandler.configureDecrypted(
                    context.channel, engine: engine, connectionID: connectionID, authority: authority)
            }
            context.fireUserInboundEventTriggered(event)
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        report(Self.failure(for: error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The app hung up during the handshake: it didn't accept the certificate.
        report(.certificateRejected)
        context.fireChannelInactive()
    }

    private func report(_ failure: ExchangeFailure) {
        guard !finished else { return }
        finished = true
        let exchange = engine.makeExchangeID()
        engine.emit(.requestHead(exchange, connectionID, pending.request, at: pending.started))
        engine.emit(.failed(exchange, engine.isStopping ? .captureStopped : failure, at: Date()))
    }

    /// Alerts an app sends when it doesn't accept the server's certificate.
    private static let rejections = [
        "ALERT_UNKNOWN_CA", "ALERT_CERTIFICATE_UNKNOWN", "ALERT_BAD_CERTIFICATE", "ALERT_CERTIFICATE_EXPIRED",
        "ALERT_UNSUPPORTED_CERTIFICATE", "ALERT_ACCESS_DENIED", "uncleanShutdown",
    ]

    static func failure(for error: any Error) -> ExchangeFailure {
        let text = String(describing: error)
        if rejections.contains(where: text.contains) {
            return .certificateRejected
        }
        let reason = tlsReason(in: text).map { " (\($0))" } ?? ""
        return .secureConnectionFailed(
            "The app's secure handshake with Reqly failed\(reason). Its Mac or device may not trust Reqly's current certificate, or the app may accept only its own."
        )
    }

    /// What BoringSSL called the problem, in words, such as "handshake failure" for
    /// `error:10000410:SSL routines:OPENSSL_internal:SSLV3_ALERT_HANDSHAKE_FAILURE`.
    static func tlsReason(in text: String) -> String? {
        guard let range = text.range(of: #"OPENSSL_internal:[A-Z0-9_]+"#, options: .regularExpression) else {
            return nil
        }
        var code = String(text[range].dropFirst("OPENSSL_internal:".count))
        for prefix in ["SSLV3_", "TLSV1_"] where code.hasPrefix(prefix) {
            code.removeFirst(prefix.count)
        }
        if code.hasPrefix("ALERT_") {
            code.removeFirst("ALERT_".count)
        }
        return code.lowercased().replacingOccurrences(of: "_", with: " ")
    }
}
