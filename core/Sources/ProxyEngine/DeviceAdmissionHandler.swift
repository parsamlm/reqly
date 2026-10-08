import NIOCore
import ReqlyModel

/// Asks whether a device on the network may send its traffic through Reqly, once its
/// connection is active, then lets it in or closes it.
///
/// It doesn't ask any sooner. NIO sets a new connection up on one event loop and makes it
/// active from another, so on a busy Mac an answer that comes at once, as it does for a device
/// that's already allowed, could find the connection not yet active and turn the device away.
final class DeviceAdmissionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let client: ClientAddress
    private let admit: @Sendable (ClientAddress) async -> Bool
    /// Lets the device in: reports the connection, before anything is read from it.
    private let open: @Sendable () -> Void

    init(
        client: ClientAddress, admit: @escaping @Sendable (ClientAddress) async -> Bool,
        open: @escaping @Sendable () -> Void
    ) {
        self.client = client
        self.admit = admit
        self.open = open
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        let channel = context.channel
        let (client, admit, open) = (self.client, self.admit, self.open)
        Task {
            let isAllowed = await admit(client)
            channel.eventLoop.execute {
                // A connection that isn't active anymore is one the device closed while it waited.
                guard isAllowed, channel.isActive else {
                    channel.close(promise: nil)
                    return
                }
                open()
                channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in
                    channel.close(promise: nil)
                }
            }
        }
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}
