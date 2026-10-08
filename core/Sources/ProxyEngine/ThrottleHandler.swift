import Foundation
import NIOCore
import ReqlyModel

/// Slows a connection to a server down to a network profile, the way a slow network would.
///
/// Bytes wait half the profile's latency each way, so a round trip waits all of it, and go no
/// faster than the profile's speeds. Opening the connection takes a round trip too. On a lossy
/// network, each lost packet stalls the connection for a round trip while it's sent again.
///
/// It goes first, next to the socket, so the TLS handshake is slowed as well.
final class ThrottleHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// How often bytes go through while a speed limits them.
    static let tick = TimeAmount.milliseconds(10)
    /// For working out how many packets a lossy network loses.
    static let packetSize = 1460
    /// Past this much on its way to the app, Reqly reads no more from the server for now.
    static let inboundLimit = 256 << 10

    private struct Pending {
        var buffer: ByteBuffer
        var promise: EventLoopPromise<Void>?
        let ready: NIODeadline
    }

    private let profile: NetworkProfile
    private let roundTrip: TimeAmount
    private var outbound = CircularBuffer<Pending>()
    /// How many writes at the front of `outbound` were flushed, and so may go.
    private var flushed = 0
    private var inbound = CircularBuffer<Pending>()
    private var inboundBytes = 0
    private var uploadAllowance = 0.0
    private var downloadAllowance = 0.0
    private var lastRun: NIODeadline?
    /// Nothing reaches the server before the round trip that opens the connection.
    private var opened = NIODeadline.distantPast
    private var stalledUntil = NIODeadline.distantPast
    private var scheduled: Scheduled<Void>?
    /// The pipeline asked for a read while too much was on its way to the app.
    private var readIsPending = false
    /// The server closed its side. The connection closes once the bytes it sent before arrive.
    private var inputIsClosed = false
    private var isClosed = false

    init(profile: NetworkProfile) {
        self.profile = profile
        roundTrip = .milliseconds(Int64(max(profile.latency, 0)))
    }

    private var oneWay: TimeAmount { .nanoseconds(roundTrip.nanoseconds / 2) }

    func channelActive(context: ChannelHandlerContext) {
        opened = .now() + roundTrip
        context.fireChannelActive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        scheduled?.cancel()
        scheduled = nil
        failUnsent()
    }

    // MARK: To the server

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !isClosed else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        outbound.append(Pending(buffer: unwrapOutboundIn(data), promise: promise, ready: max(.now(), opened) + oneWay))
    }

    func flush(context: ChannelHandlerContext) {
        flushed = outbound.count
        schedule(context)
    }

    /// What's still on its way to the server goes out first, then the connection closes.
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if mode != .input, !outbound.isEmpty {
            let unsent = outbound
            outbound.removeAll()
            flushed = 0
            for pending in unsent {
                context.write(wrapOutboundOut(pending.buffer), promise: pending.promise)
            }
            context.flush()
        }
        context.close(mode: mode, promise: promise)
    }

    // MARK: From the server

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        inboundBytes += buffer.readableBytes
        inbound.append(Pending(buffer: buffer, promise: nil, ready: .now() + oneWay))
        schedule(context)
    }

    /// Each batch of bytes that reaches the app gets a read complete of its own.
    func channelReadComplete(context: ChannelHandlerContext) {}

    func read(context: ChannelHandlerContext) {
        if inboundBytes >= Self.inboundLimit {
            readIsPending = true
        } else {
            context.read()
        }
    }

    /// The channel has `allowRemoteHalfClosure` set, so the server closing arrives here, and
    /// can wait for the bytes before it.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .inputClosed = event as? ChannelEvent {
            inputIsClosed = true
            closeIfDone(context)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    /// The connection broke, or Reqly closed it. Bytes still on their way are lost, as they
    /// would be on a network.
    func channelInactive(context: ChannelHandlerContext) {
        isClosed = true
        scheduled?.cancel()
        scheduled = nil
        inbound.removeAll()
        inboundBytes = 0
        failUnsent()
        context.fireChannelInactive()
    }

    // MARK: Letting bytes through

    private func schedule(_ context: ChannelHandlerContext) {
        guard scheduled == nil, !isClosed, let next = nextRun() else { return }
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        scheduled = context.eventLoop.scheduleTask(deadline: next) {
            handler.value.scheduled = nil
            handler.value.run(boundContext.value)
        }
    }

    /// When the next bytes may go: once they've waited out the latency and any stall, and then
    /// a tick at a time while a speed limits them.
    private func nextRun() -> NIODeadline? {
        let now = NIODeadline.now()
        var next: NIODeadline?
        if flushed > 0, let first = outbound.first {
            next = first.ready > now ? first.ready : now + Self.tick
        }
        if let first = inbound.first {
            let ready = first.ready > now ? first.ready : now + Self.tick
            next = min(next ?? ready, ready)
        }
        return next.map { max($0, stalledUntil) }
    }

    private func run(_ context: ChannelHandlerContext) {
        guard !isClosed else { return }
        let now = NIODeadline.now()
        // Speed saved up while the connection was quiet is capped, so it doesn't come out as
        // a burst.
        let seconds = lastRun.map { Double(min((now - $0).nanoseconds, 1_000_000_000)) / 1e9 } ?? 0
        lastRun = now
        refill(&uploadAllowance, rate: profile.uploadBytesPerSecond, over: seconds)
        refill(&downloadAllowance, rate: profile.downloadBytesPerSecond, over: seconds)
        if now >= stalledUntil {
            let sent = take(
                from: &outbound, upTo: flushed, allowance: &uploadAllowance,
                limited: profile.uploadBytesPerSecond != nil, now: now)
            flushed -= sent.removed
            let arrived = take(
                from: &inbound, upTo: inbound.count, allowance: &downloadAllowance,
                limited: profile.downloadBytesPerSecond != nil, now: now)
            inboundBytes -= arrived.bytes
            stallIfLost(sent.bytes + arrived.bytes, now: now)

            for (buffer, promise) in sent.pieces {
                context.write(wrapOutboundOut(buffer), promise: promise)
            }
            if !sent.pieces.isEmpty {
                context.flush()
            }
            for (buffer, _) in arrived.pieces {
                // The app's side may close the connection on the way.
                guard !isClosed else { return }
                context.fireChannelRead(wrapInboundOut(buffer))
            }
            guard !isClosed else { return }
            if !arrived.pieces.isEmpty {
                context.fireChannelReadComplete()
            }
        }
        guard !isClosed else { return }
        if readIsPending, inboundBytes < Self.inboundLimit {
            readIsPending = false
            context.read()
        }
        closeIfDone(context)
        schedule(context)
    }

    private func refill(_ allowance: inout Double, rate: Int?, over seconds: Double) {
        guard let rate else { return }
        let most = max(Double(rate) / 10, Double(Self.packetSize))
        allowance = min(allowance + Double(rate) * seconds, most)
    }

    /// Takes what's ready from the front of a queue, as far as the allowance goes, splitting a
    /// buffer if it must. A buffer's promise goes with its last piece.
    private func take(
        from queue: inout CircularBuffer<Pending>, upTo limit: Int, allowance: inout Double, limited: Bool,
        now: NIODeadline
    ) -> (pieces: [(ByteBuffer, EventLoopPromise<Void>?)], removed: Int, bytes: Int) {
        var pieces: [(ByteBuffer, EventLoopPromise<Void>?)] = []
        var removed = 0
        var bytes = 0
        while removed < limit, var first = queue.first, first.ready <= now {
            let size = first.buffer.readableBytes
            if !limited || Double(size) <= allowance {
                queue.removeFirst()
                removed += 1
                bytes += size
                if limited {
                    allowance -= Double(size)
                }
                pieces.append((first.buffer, first.promise))
            } else {
                let length = Int(allowance)
                if length > 0, let piece = first.buffer.readSlice(length: length) {
                    queue[queue.startIndex] = first
                    allowance -= Double(length)
                    bytes += length
                    pieces.append((piece, nil))
                }
                break
            }
        }
        return (pieces, removed, bytes)
    }

    /// A lossy network loses some of the packets, and each loss holds everything up for a
    /// round trip while the packet is sent again.
    private func stallIfLost(_ bytes: Int, now: NIODeadline) {
        let loss = min(max(profile.packetLoss, 0), 1)
        guard loss > 0, bytes > 0 else { return }
        let packets = Double((bytes + Self.packetSize - 1) / Self.packetSize)
        if Double.random(in: 0..<1) < 1 - pow(1 - loss, packets) {
            stalledUntil = now + max(roundTrip, .milliseconds(100))
        }
    }

    private func closeIfDone(_ context: ChannelHandlerContext) {
        if inputIsClosed, inbound.isEmpty, !isClosed {
            context.close(promise: nil)
        }
    }

    /// Writes that never went out still owe their promises an answer.
    private func failUnsent() {
        let unsent = outbound
        outbound.removeAll()
        flushed = 0
        for pending in unsent {
            pending.promise?.fail(ChannelError.ioOnClosedChannel)
        }
    }
}

extension ThrottleHandler {
    /// Slows a new connection to a server down to `network`, if there is one. Call it while the
    /// channel is set up, before anything goes over it.
    static func slow(_ channel: any Channel, to network: NetworkProfile?) throws {
        guard let network else { return }
        try channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        try channel.pipeline.syncOperations.addHandler(ThrottleHandler(profile: network), position: .first)
    }
}

extension EventLoopFuture where Value == any Channel {
    /// The new connection, once it has also taken the round trip a slow network takes to open it.
    func afterOpening(over network: NetworkProfile?) -> EventLoopFuture<any Channel> {
        guard let network, network.latency > 0 else { return self }
        return flatMap { channel in
            channel.eventLoop.scheduleTask(in: .milliseconds(Int64(network.latency))) { channel }.futureResult
        }
    }
}
