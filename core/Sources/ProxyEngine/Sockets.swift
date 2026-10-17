import Foundation
import NIOCore
import NIOPosix

#if canImport(WinSDK)
    import WinSDK
#endif

/// Where sockets behave differently on Windows.
enum Sockets {
    /// Whether a listener failed because another program already listens on its port.
    static func isAddressInUse(_ error: IOError) -> Bool {
        #if os(Windows)
            error.number == WSAEADDRINUSE
        #else
            error.number == EADDRINUSE
        #endif
    }

    /// Whether a connection failed because nothing listens at its address.
    static func isConnectionRefused(_ error: IOError) -> Bool {
        #if os(Windows)
            error.number == WSAECONNREFUSED
        #else
            error.number == ECONNREFUSED
        #endif
    }

    /// Whether a reset drops what the other side sent that Reqly hadn't read yet. Windows drops
    /// it; the Mac and Linux keep it to read first.
    #if os(Windows)
        static let resetDropsUnreadData = true
    #else
        static let resetDropsUnreadData = false
    #endif

    /// Whether the other side reset an open connection.
    static func isConnectionReset(_ error: IOError) -> Bool {
        guard let number = error.number else { return false }
        #if os(Windows)
            return number == WSAECONNRESET || number == WSAECONNABORTED
        #else
            return number == ECONNRESET || number == ECONNABORTED || number == EPIPE
        #endif
    }
}

extension IOError {
    /// The error's number: errno on the Mac and Linux, and on Windows, mostly Winsock's.
    ///
    /// On Windows, NIO keeps Winsock's or Windows' number in a property it doesn't make public, and
    /// reading `errnoCode` there stops the program. So on Windows the number is read by reflection,
    /// and it's `nil` if NIO ever keeps it some other way.
    fileprivate var number: CInt? {
        #if os(Windows)
            guard let domain = Mirror(reflecting: self).children.first(where: { $0.label == "error" })?.value,
                let code = Mirror(reflecting: domain).children.first
            else { return nil }
            switch code.label {
            case "winsock", "errno": return code.value as? CInt
            case "windows": return (code.value as? DWORD).map { CInt(truncatingIfNeeded: $0) }
            default: return nil
            }
        #else
            errnoCode
        #endif
    }
}

extension ServerBootstrap {
    /// Keeps the port to this listener. On the Mac and Linux, SO_REUSEADDR lets Reqly listen again
    /// right after it stops, while its old connections wind down. On Windows it would also let another
    /// program listen on the same port, so there, SO_EXCLUSIVEADDRUSE keeps others off the port.
    func ownPort() -> Self {
        #if os(Windows)
            // SO_EXCLUSIVEADDRUSE is a macro Swift doesn't bring in: ~SO_REUSEADDR.
            serverChannelOption(.socketOption(NIOBSDSocket.Option(rawValue: ~SO_REUSEADDR)), value: 1)
        #else
            serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        #endif
    }
}
