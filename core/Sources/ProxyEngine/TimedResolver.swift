import Dispatch
import Foundation
import NIOCore
import NIOPosix

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if !os(Windows)

    /// Looks up a server's addresses and reports when the lookup finished, for the Timing tab.
    ///
    /// NIO's own resolver isn't public, so this one does what it does: a single `getaddrinfo` call,
    /// on a background queue, answers both the AAAA and the A query that Happy Eyeballs makes.
    /// Windows gets its own version in Phase 2; until then it uses NIO's resolver, without the time.
    final class TimedResolver: Resolver, Sendable {
        private let loop: any EventLoop
        private let v4: EventLoopPromise<[SocketAddress]>
        private let v6: EventLoopPromise<[SocketAddress]>
        /// Runs on the event loop with the time the lookup finished, before the addresses are used.
        private let resolved: @Sendable (Date) -> Void

        init(loop: any EventLoop, resolved: @escaping @Sendable (Date) -> Void) {
            self.loop = loop
            v4 = loop.makePromise()
            v6 = loop.makePromise()
            self.resolved = resolved
        }

        /// Happy Eyeballs asks for AAAA records first, so that query does the lookup.
        func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
            // `getaddrinfo` blocks, and one slow name mustn't hold up the others.
            DispatchQueue.global(qos: .userInitiated).async {
                self.resolve(host: host, port: port)
            }
            return v6.futureResult
        }

        func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
            v4.futureResult
        }

        /// A lookup that started can't be stopped.
        func cancelQueries() {}

        private func resolve(host: String, port: Int) {
            var hints = addrinfo()
            // Glibc imports the socket types as an enum; Darwin and musl, as numbers.
            #if canImport(Glibc)
                hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #else
                hints.ai_socktype = SOCK_STREAM
            #endif
            hints.ai_protocol = Int32(IPPROTO_TCP)
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, String(port), &hints, &list)
            let finished = Date()
            guard status == 0, let list else {
                let error = LookupFailed(host: host, reason: String(cString: gai_strerror(status)))
                loop.execute {
                    self.v6.fail(error)
                    self.v4.fail(error)
                }
                return
            }
            var v4Addresses: [SocketAddress] = []
            var v6Addresses: [SocketAddress] = []
            var entry: UnsafeMutablePointer<addrinfo>? = list
            while let current = entry {
                if let address = current.pointee.ai_addr {
                    switch current.pointee.ai_family {
                    case AF_INET:
                        v4Addresses.append(
                            SocketAddress(UnsafeRawPointer(address).load(as: sockaddr_in.self), host: host))
                    case AF_INET6:
                        v6Addresses.append(
                            SocketAddress(UnsafeRawPointer(address).load(as: sockaddr_in6.self), host: host))
                    default:
                        break
                    }
                }
                entry = current.pointee.ai_next
            }
            freeaddrinfo(list)
            loop.execute { [v4Addresses, v6Addresses] in
                self.resolved(finished)
                self.v6.succeed(v6Addresses)
                self.v4.succeed(v4Addresses)
            }
        }
    }

    /// The name didn't resolve, with `getaddrinfo`'s reason.
    struct LookupFailed: Error, CustomStringConvertible {
        var host: String
        var reason: String

        var description: String { "\(host) didn't resolve: \(reason)" }
    }
#endif
