import Foundation

#if os(Windows)
    import WinSDK
#endif

/// This PC's addresses on the networks devices can reach, for setting up a phone or a tablet.
public enum NetworkAddresses {
    public struct Address: Hashable, Sendable {
        /// What Windows calls the connection, such as "Wi-Fi" or "Ethernet".
        public var interface: String
        /// Such as `192.168.1.125`.
        public var address: String
    }

    /// IPv4 addresses on connections that are up, other than loopback: the ones with a way out to
    /// the internet first, as a device's network has, then Wi-Fi and Ethernet, then the rest.
    public static func current() -> [Address] {
        #if os(Windows)
            var size: ULONG = 16 * 1024
            var buffer = [UInt8](repeating: 0, count: Int(size))
            let flags =
                ULONG(GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER)
                | ULONG(GAA_FLAG_INCLUDE_GATEWAYS)
            var result = ULONG(ERROR_BUFFER_OVERFLOW)
            // The list can grow between asking its size and reading it.
            for _ in 0..<3 where result == ULONG(ERROR_BUFFER_OVERFLOW) {
                buffer = [UInt8](repeating: 0, count: Int(size))
                result = buffer.withUnsafeMutableBytes { bytes in
                    GetAdaptersAddresses(
                        ULONG(AF_INET), flags, nil,
                        bytes.baseAddress?.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES.self),
                        &size)
                }
            }
            guard result == ULONG(NO_ERROR) else { return [] }
            var found: [(address: Address, rank: Int)] = []
            buffer.withUnsafeMutableBytes { bytes in
                var next = bytes.baseAddress?.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES.self)
                while let adapter = next {
                    next = adapter.pointee.Next
                    guard adapter.pointee.OperStatus == IfOperStatusUp,
                        adapter.pointee.IfType != ULONG(IF_TYPE_SOFTWARE_LOOPBACK)
                    else { continue }
                    let name = adapter.pointee.FriendlyName.map { String(decodingCString: $0, as: UTF16.self) } ?? ""
                    let isWirelessOrWired =
                        adapter.pointee.IfType == ULONG(IF_TYPE_IEEE80211)
                        || adapter.pointee.IfType == ULONG(IF_TYPE_ETHERNET_CSMACD)
                    let rank = (adapter.pointee.FirstGatewayAddress != nil ? 0 : 2) + (isWirelessOrWired ? 0 : 1)
                    var unicast = adapter.pointee.FirstUnicastAddress
                    while let entry = unicast {
                        unicast = entry.pointee.Next
                        guard let socket = entry.pointee.Address.lpSockaddr,
                            socket.pointee.sa_family == ADDRESS_FAMILY(AF_INET)
                        else { continue }
                        let ip = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                            Self.text($0.pointee.sin_addr)
                        }
                        found.append((Address(interface: name, address: ip), rank))
                    }
                }
            }
            return found.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
                .map(\.element.address)
        #else
            return []
        #endif
    }

    #if os(Windows)
        /// An IPv4 address as it's written, such as `192.168.1.125`.
        static func text(_ address: in_addr) -> String {
            withUnsafeBytes(of: address) { bytes in bytes.prefix(4).map(String.init).joined(separator: ".") }
        }
    #endif
}

/// The hardware addresses of devices on the local network, from Windows' table of neighbors.
public enum NetworkNeighbors {
    /// A device's hardware address, such as `aa:bb:cc:dd:ee:ff`, which stays the same when its IP
    /// address changes; `nil` when Windows doesn't know it.
    public static func hardwareAddress(of ip: String) -> String? {
        #if os(Windows)
            var table: PMIB_IPNET_TABLE2? = nil
            guard GetIpNetTable2(ADDRESS_FAMILY(AF_INET), &table) == NO_ERROR, let table else { return nil }
            defer { FreeMibTable(table) }
            let count = Int(table.pointee.NumEntries)
            return withUnsafeMutablePointer(to: &table.pointee.Table) { first in
                first.withMemoryRebound(to: MIB_IPNET_ROW2.self, capacity: count) { rows in
                    for index in 0..<count {
                        var row = rows[index]
                        guard NetworkAddresses.text(row.Address.Ipv4.sin_addr) == ip else { continue }
                        let length = Int(row.PhysicalAddressLength)
                        let bytes = withUnsafeBytes(of: &row.PhysicalAddress) { Array($0.prefix(length)) }
                        guard length == 6, bytes.contains(where: { $0 != 0 }) else { return nil }
                        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                    return nil
                }
            }
        #else
            return nil
        #endif
    }
}
