import Foundation
import NIOCore
import ReqlyModel

/// Counts a tunnel's bytes and reports the tunnel once, when either side closes. On a
/// connection that switched to WebSocket, it reads each message from copies of the bytes too.
final class TunnelRecord {
    let exchange: ExchangeID
    let engine: EngineContext
    var bytesFromApp: Int64 = 0
    var bytesFromServer: Int64 = 0
    private var reported = false
    private let sent: WebSocketReader?
    private let received: WebSocketReader?

    init(exchange: ExchangeID, engine: EngineContext, webSocket: WebSocketSettings? = nil) {
        self.exchange = exchange
        self.engine = engine
        sent = webSocket.map { WebSocketReader(direction: .sent, settings: $0) }
        received = webSocket.map { WebSocketReader(direction: .received, settings: $0) }
    }

    func fromApp(_ bytes: ByteBuffer) {
        bytesFromApp += Int64(bytes.readableBytes)
        report(sent?.read(bytes, at: Date()))
    }

    func fromServer(_ bytes: ByteBuffer) {
        bytesFromServer += Int64(bytes.readableBytes)
        report(received?.read(bytes, at: Date()))
    }

    private func report(_ messages: [WebSocketMessage]?) {
        for message in messages ?? [] {
            engine.emit(.webSocketMessage(exchange, message))
        }
    }

    func close() {
        guard !reported else { return }
        reported = true
        engine.emit(.tunnelClosed(exchange, bytesSent: bytesFromApp, bytesReceived: bytesFromServer, at: Date()))
    }
}

/// Relays bytes between two channels on the same event loop. While one side can't keep up,
/// the other side stops reading.
final class GlueHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Side {
        case app, server
    }

    private let side: Side
    private let record: TunnelRecord
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init(side: Side, record: TunnelRecord) {
        self.side = side
        self.record = record
    }

    static func matchedPair(record: TunnelRecord) -> (app: GlueHandler, server: GlueHandler) {
        let app = GlueHandler(side: .app, record: record)
        let server = GlueHandler(side: .server, record: record)
        app.partner = server
        server.partner = app
        return (app, server)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        switch side {
        case .app: record.fromApp(buffer)
        case .server: record.fromServer(buffer)
        }
        partner?.context?.write(wrapOutboundOut(buffer), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        record.close()
        partner?.context?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, let partner, partner.pendingRead {
            partner.pendingRead = false
            partner.context?.read()
        }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if let partnerContext = partner?.context, !partnerContext.channel.isWritable {
            pendingRead = true
        } else {
            context.read()
        }
    }
}
