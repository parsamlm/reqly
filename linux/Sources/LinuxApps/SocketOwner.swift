import CLinux

/// Who owns a TCP socket on this computer, as the kernel tells anyone who asks: the user, the
/// socket's inode and the cgroup it was made in.
public struct SocketOwner: Hashable, Sendable {
    /// The user that made the socket.
    public var uid: UInt32
    /// The socket's inode: each process that has it open has a file that links to
    /// `socket:[inode]` in `/proc/<pid>/fd`.
    public var inode: UInt64
    /// The cgroup the socket was made in, which is the inode of its folder under `/sys/fs/cgroup`,
    /// or `nil` when the kernel didn't say.
    public var cgroupID: UInt64?

    public init(uid: UInt32, inode: UInt64, cgroupID: UInt64?) {
        self.uid = uid
        self.inode = inode
        self.cgroupID = cgroupID
    }

    /// The owner of the connection from `clientPort` to `proxyPort` on this computer's loopback,
    /// over IPv4 or IPv6, or `nil` when there's none open, or the kernel didn't answer within
    /// 200 milliseconds. One question to the kernel, which needs no privileges.
    public static func ofConnection(clientPort: Int, proxyPort: Int) -> SocketOwner? {
        guard let client = UInt16(exactly: clientPort), let proxy = UInt16(exactly: proxyPort) else { return nil }
        var owner = reqly_socket_owner()
        guard reqly_tcp_owner(client, proxy, &owner) == 0 else { return nil }
        return SocketOwner(uid: owner.uid, inode: owner.inode, cgroupID: owner.cgroup_id == 0 ? nil : owner.cgroup_id)
    }
}
