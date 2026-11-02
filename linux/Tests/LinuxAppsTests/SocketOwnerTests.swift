import Foundation
import LinuxApps
import Testing

@Suite struct SocketOwnerTests {
    /// A connection this process opens to itself is this user's. The kernel finds it at once at
    /// 127.0.0.1 and ::1, and by going through its table elsewhere on loopback.
    @Test(arguments: [Loopback.Kind.ipv4, .ipv6, .ipv4ThroughIPv6, .otherIPv4])
    func asksTheKernelWhoOwnsAConnection(kind: Loopback.Kind) throws {
        let (server, client, accepted, proxyPort, clientPort) = try Loopback.connect(kind)
        defer { [server, client, accepted].forEach { close($0) } }

        let owner = try #require(SocketOwner.ofConnection(clientPort: clientPort, proxyPort: proxyPort))
        #expect(owner.uid == getuid())
        #expect(owner.inode != 0)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(client)")
        #expect(link == "socket:[\(owner.inode)]")
        // The cgroup's ID is the inode of its folder: this process's, which cgroup2 names on the
        // one line of /proc/self/cgroup, `0::/path`.
        let line = try String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8)
        let path = String(line.trimmingCharacters(in: .newlines).dropFirst("0::".count))
        var folder = stat()
        #expect(stat("/sys/fs/cgroup" + path, &folder) == 0)
        #expect(owner.cgroupID == UInt64(folder.st_ino))
        // Reqly's side of it is another socket, the other way round.
        let reqlySide = try #require(SocketOwner.ofConnection(clientPort: proxyPort, proxyPort: clientPort))
        #expect(reqlySide.inode != owner.inode)
        let acceptedLink = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(accepted)")
        #expect(acceptedLink == "socket:[\(reqlySide.inode)]")
        #expect(SocketOwner.ofConnection(clientPort: clientPort, proxyPort: clientPort) == nil)
    }

    /// Once the connection has closed, there's no owner to find.
    @Test func findsNoOwnerOnceClosed() throws {
        let (server, client, accepted, proxyPort, clientPort) = try Loopback.connect(.ipv4)
        defer { close(server) }
        close(client)
        close(accepted)
        #expect(SocketOwner.ofConnection(clientPort: clientPort, proxyPort: proxyPort) == nil)
        #expect(SocketOwner.ofConnection(clientPort: 70_000, proxyPort: proxyPort) == nil)
    }
}

/// Connections this process opens to itself on loopback.
enum Loopback {
    enum Kind: CustomStringConvertible, Sendable {
        /// 127.0.0.1 to 127.0.0.1.
        case ipv4
        /// ::1 to ::1.
        case ipv6
        /// An IPv6 socket to ::ffff:127.0.0.1, which reaches an IPv4 listener.
        case ipv4ThroughIPv6
        /// 127.0.0.2 to 127.0.0.2, as Debian's 127.0.1.1 for the computer's own name is.
        case otherIPv4

        var description: String {
            switch self {
            case .ipv4: "IPv4"
            case .ipv6: "IPv6"
            case .ipv4ThroughIPv6: "IPv4 through IPv6"
            case .otherIPv4: "127.0.0.2"
            }
        }
    }

    struct Failed: Error {
        var step: String
    }

    /// Listens, connects and accepts.
    /// - Returns: The listener, the client's socket, Reqly's side of it, and the two ports.
    static func connect(
        _ kind: Kind
    ) throws -> (server: Int32, client: Int32, accepted: Int32, proxyPort: Int, clientPort: Int) {
        let serverFamily = kind == .ipv6 ? AF_INET6 : AF_INET
        let clientFamily = kind == .ipv6 || kind == .ipv4ThroughIPv6 ? AF_INET6 : AF_INET
        let host = kind == .otherIPv4 ? "127.0.0.2" : "127.0.0.1"
        let server = socket(serverFamily, Int32(SOCK_STREAM.rawValue), 0)
        let client = socket(clientFamily, Int32(SOCK_STREAM.rawValue), 0)
        guard server >= 0, client >= 0 else { throw Failed(step: "socket") }
        var listening = address(family: serverFamily, port: 0, host: host, mapped: false)
        guard bind(server, &listening) == 0, listen(server, 4) == 0 else { throw Failed(step: "listen") }
        let proxyPort = port(of: server)
        var target = address(family: clientFamily, port: proxyPort, host: host, mapped: kind == .ipv4ThroughIPv6)
        // The client's own end on the same address, as the kernel picks it for loopback.
        var own = address(family: clientFamily, port: 0, host: host, mapped: kind == .ipv4ThroughIPv6)
        guard kind != .otherIPv4 || bind(client, &own) == 0 else { throw Failed(step: "bind") }
        guard connectSocket(client, &target) == 0 else { throw Failed(step: "connect") }
        let accepted = accept(server, nil, nil)
        guard accepted >= 0 else { throw Failed(step: "accept") }
        return (server, client, accepted, proxyPort, port(of: client))
    }

    /// A loopback address: `host` for IPv4, ::1 for IPv6, or `host` through IPv6 when `mapped`.
    private static func address(family: Int32, port: Int, host: String, mapped: Bool) -> sockaddr_storage {
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { bytes in
            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(port).bigEndian
                address.sin_addr.s_addr = inet_addr(host)
                withUnsafeBytes(of: address) { bytes.copyMemory(from: $0) }
            } else {
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = in_port_t(port).bigEndian
                _ = inet_pton(AF_INET6, mapped ? "::ffff:" + host : "::1", &address.sin6_addr)
                withUnsafeBytes(of: address) { bytes.copyMemory(from: $0) }
            }
        }
        return storage
    }

    private static func length(of storage: sockaddr_storage) -> socklen_t {
        socklen_t(
            Int32(storage.ss_family) == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
    }

    private static func bind(_ socket: Int32, _ storage: inout sockaddr_storage) -> Int32 {
        let length = length(of: storage)
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.bind(socket, $0, length) }
        }
    }

    private static func connectSocket(_ socket: Int32, _ storage: inout sockaddr_storage) -> Int32 {
        let length = length(of: storage)
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(socket, $0, length) }
        }
    }

    private static func port(of socket: Int32) -> Int {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        // Both families keep the port in network byte order right after the family.
        let raw = withUnsafeBytes(of: storage) { $0.load(fromByteOffset: 2, as: UInt16.self) }
        return Int(UInt16(bigEndian: raw))
    }
}
