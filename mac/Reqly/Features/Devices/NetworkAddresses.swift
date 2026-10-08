import Darwin
import Foundation
import SystemConfiguration

/// One of the Mac's addresses on a network, for devices to connect to.
struct NetworkAddress: Hashable, Identifiable {
    /// Such as `192.168.1.125`.
    var address: String
    /// Such as `en0`.
    var interface: String
    /// Such as "Wi-Fi".
    var name: String

    var id: String { "\(interface) \(address)" }

    /// The Mac's IPv4 addresses on the networks it's on, Wi-Fi and Ethernet first. Addresses
    /// only the Mac uses itself, such as VPN tunnels, are left out.
    static func current() -> [NetworkAddress] {
        var names: [String: String] = [:]
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                if let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                    let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                {
                    names[bsdName] = name
                }
            }
        }
        var addresses: [NetworkAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            let interface = String(cString: entry.pointee.ifa_name)
            // Only interfaces macOS shows in Network settings reach other devices.
            guard let name = names[interface] else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
            else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            addresses.append(NetworkAddress(address: text, interface: interface, name: name))
        }
        return addresses.sorted {
            ($0.interface.hasPrefix("en") ? 0 : 1, $0.interface) < ($1.interface.hasPrefix("en") ? 0 : 1, $1.interface)
        }
    }
}
