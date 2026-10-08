#if os(macOS)
    import Darwin
    import Foundation

    /// The other devices on the Mac's networks, as its ARP table knows them.
    public enum NetworkNeighbors {
        /// The hardware address of the device at `ip` on the local network, such as
        /// `a4:83:e7:12:34:56`. The Mac learns it as soon as the device connects. It's `nil` for
        /// the Mac's own addresses, and for devices beyond a router.
        public static func hardwareAddress(of ip: String) -> String? {
            var target = in_addr()
            guard inet_pton(AF_INET, ip, &target) == 1 else { return nil }
            var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
            var size = 0
            guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            // Room for entries added meanwhile.
            size += 4096
            var table = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 6, &table, &size, nil, 0) == 0 else { return nil }
            return table.withUnsafeBytes { raw in
                var offset = 0
                let headerSize = MemoryLayout<rt_msghdr>.size
                while offset + headerSize <= size {
                    let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                    guard header.rtm_msglen > 0 else { return nil }
                    defer { offset += Int(header.rtm_msglen) }
                    // Each entry is its header, the IP address, then the link-level address.
                    let addressOffset = offset + headerSize
                    guard addressOffset + MemoryLayout<sockaddr_in>.size <= size else { return nil }
                    let address = raw.loadUnaligned(fromByteOffset: addressOffset, as: sockaddr_in.self)
                    guard address.sin_addr.s_addr == target.s_addr else { continue }
                    let linkOffset = addressOffset + rounded(Int(address.sin_len))
                    guard linkOffset + MemoryLayout<sockaddr_dl>.size <= size else { return nil }
                    let link = raw.loadUnaligned(fromByteOffset: linkOffset, as: sockaddr_dl.self)
                    guard link.sdl_alen == 6, let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else {
                        return nil
                    }
                    let start = linkOffset + dataOffset + Int(link.sdl_nlen)
                    guard start + 6 <= size else { return nil }
                    let bytes = (0..<6).map { raw[start + $0] }
                    // An incomplete entry has no address yet.
                    guard bytes.contains(where: { $0 != 0 }) else { return nil }
                    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
                return nil
            }
        }

        /// Socket addresses in the routing table take up a multiple of four bytes.
        private static func rounded(_ length: Int) -> Int {
            length > 0 ? 1 + ((length - 1) | 3) : 4
        }
    }
#endif
