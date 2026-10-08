import NIOCore
import NIOSSL
import Synchronization

/// The TLS setup for one connection to a server, and the client certificate Reqly has for the
/// server's host, if any.
struct ServerTLS: Sendable {
    let context: NIOSSLContext
    /// The setup that presents the host's client certificate, which the connection holds until
    /// it closes.
    let certificate: ClientCertificateTLS?

    /// Before the handshake: Reqly has no certificate for the host, or has one to present if
    /// the server asks.
    var certificateUse: ClientCertificateUse {
        certificate.map { .ready($0.name) } ?? .noCertificate
    }

    /// Adds TLS to a new connection's pipeline.
    func addHandler(to channel: any Channel, serverHostname: String?) throws {
        try channel.pipeline.syncOperations.addHandler(
            NIOSSLClientHandler(context: context, serverHostname: serverHostname))
    }

    /// Lets the connection that `connecting` opens hold the setup until it closes. When the
    /// server asks for the client certificate, Reqly presents it and calls `presented` with its
    /// name, on the connection's event loop. Call it on that loop, as the connection starts
    /// opening.
    func hold(until connecting: EventLoopFuture<any Channel>, presented: @escaping (String) -> Void) {
        certificate?.hold(until: connecting, presented: presented)
    }
}

/// Whether Reqly has a client certificate for a server, and whether the server got it.
enum ClientCertificateUse: Hashable, Sendable {
    /// Reqly has no client certificate for the server's host.
    case noCertificate
    /// Reqly has this one for the host, and presents it if the server asks for a certificate.
    case ready(String)
    /// The server asked for a certificate, and Reqly presented this one.
    case presented(String)

    /// The certificate's name, once Reqly has presented it.
    var presentedName: String? {
        if case .presented(let name) = self { name } else { nil }
    }
}

/// A TLS setup that presents a client certificate, and tells the connection that holds it when
/// the server asks for the certificate.
///
/// The TLS layer only says that a server asked, not on which of the setup's connections, so one
/// connection holds the setup at a time, until it closes. Then it's free for the next.
final class ClientCertificateTLS: Sendable {
    let context: NIOSSLContext
    /// The certificate's name.
    let name: String
    private let listener: Listener
    /// Takes the setup back once its connection has closed.
    private let release: @Sendable (ClientCertificateTLS) -> Void

    /// Hears from the TLS layer when a server asks for the certificate.
    final class Listener: Sendable {
        private let action = Mutex<(@Sendable () -> Void)?>(nil)

        func set(_ action: (@Sendable () -> Void)?) {
            self.action.withLock { $0 = action }
        }

        func serverAsked() {
            action.withLock { $0 }?()
        }
    }

    /// Makes the setup, presenting the certificate in `configuration`. It's slow, so the setups
    /// are kept to use again.
    init(
        configuration: TLSConfiguration, name: String, release: @escaping @Sendable (ClientCertificateTLS) -> Void
    ) throws {
        let listener = Listener()
        var configuration = configuration
        // The TLS layer calls this when the server asks for a certificate, before it presents the
        // one the setup has.
        configuration.sslContextCallback = { _, promise in
            listener.serverAsked()
            promise.succeed(.noChanges)
        }
        context = try NIOSSLContext(configuration: configuration)
        self.name = name
        self.listener = listener
        self.release = release
    }

    /// Lets the connection that `connecting` opens hold the setup until it closes, and calls
    /// `presented` on its event loop when the server asks for the certificate.
    ///
    /// The setup is held by the connection, not by each channel it tries: to a name with several
    /// addresses, such as an IPv6 and an IPv4 one, a connection may try more than one, and the
    /// tries that fail close before the one that opens is done with the setup.
    fileprivate func hold(until connecting: EventLoopFuture<any Channel>, presented: @escaping (String) -> Void) {
        let presented = NIOLoopBound(presented, eventLoop: connecting.eventLoop)
        let name = name
        listener.set { presented.value(name) }
        connecting.whenComplete { [self] result in
            guard case .success(let channel) = result else {
                free()
                return
            }
            channel.closeFuture.whenComplete { [self] _ in free() }
        }
    }

    private func free() {
        listener.set(nil)
        release(self)
    }
}
