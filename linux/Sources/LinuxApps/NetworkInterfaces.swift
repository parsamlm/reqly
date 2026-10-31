import Glibc

/// This computer's addresses on the networks devices can reach, for setting up a phone or a tablet.
public enum NetworkAddresses {
    public struct Address: Hashable, Sendable {
        /// What the connection is, such as "Wi-Fi" or "Ethernet", with Linux's name for it, such
        /// as "Ethernet (enp3s0)", when two are alike.
        public var interface: String
        /// Such as `192.168.1.125`.
        public var address: String

        public init(interface: String, address: String) {
            self.interface = interface
            self.address = address
        }
    }

    /// An IPv4 address on a network interface that's up, as Linux describes it.
    public struct Interface: Hashable, Sendable {
        /// Linux's name for it, such as `wlp2s0`, `enp3s0` or `docker0`.
        public var name: String
        public var address: String
        /// Whether it's Wi-Fi.
        public var isWireless: Bool
        /// Whether it's hardware, such as a network card or a USB adapter, rather than one made
        /// in software, such as Docker's bridges or a VPN's tunnel.
        public var isHardware: Bool
        /// Whether the computer's default route, its way out to the internet, goes through it.
        public var hasDefaultRoute: Bool

        public init(name: String, address: String, isWireless: Bool, isHardware: Bool, hasDefaultRoute: Bool) {
            self.name = name
            self.address = address
            self.isWireless = isWireless
            self.isHardware = isHardware
            self.hasDefaultRoute = hasDefaultRoute
        }
    }

    /// IPv4 addresses on interfaces that are up, other than loopback, the likeliest first.
    public static func current() -> [Address] {
        let routes = defaultRoutes(inTable: LinuxFile.text("/proc/net/route") ?? "")
        return ordered(
            interfaces().map { name, address in
                Interface(
                    name: name, address: address,
                    isWireless: LinuxFile.isFolder("/sys/class/net/\(name)/wireless")
                        || LinuxFile.isFolder("/sys/class/net/\(name)/phy80211"),
                    // Hardware has a device behind it; bridges, tunnels and veths have none.
                    isHardware: LinuxFile.link("/sys/class/net/\(name)/device") != nil,
                    hasDefaultRoute: routes.contains(name))
            })
    }

    /// The likeliest first: the ones with a way out to the internet, as a device's network has,
    /// then Wi-Fi and Ethernet, then the rest; interfaces made in software, such as `docker0`,
    /// `virbr0`, `veth…` and `br-…`, last. Otherwise in the order given.
    public static func ordered(_ interfaces: [Interface]) -> [Address] {
        let ranked = interfaces.enumerated().map { offset, interface in
            let isVirtual = !interface.isHardware || isVirtual(interface.name)
            let isUsual = ["Wi-Fi", "Ethernet"].contains(label(for: interface))
            let rank = (isVirtual ? 4 : 0) + (interface.hasDefaultRoute ? 0 : 2) + (isUsual ? 0 : 1)
            return (interface: interface, rank: rank, offset: offset)
        }
        .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
        let labels = ranked.map { label(for: $0.interface) }
        return zip(ranked, labels).map { item, label in
            let isShared = labels.filter { $0 == label }.count > 1 && label != item.interface.name
            return Address(
                interface: isShared ? "\(label) (\(item.interface.name))" : label, address: item.interface.address)
        }
    }

    /// What to call an interface: "Wi-Fi", "Ethernet", "Mobile broadband", "Docker", "Virtual
    /// machines" or "VPN", or Linux's name for it when it's none of those.
    static func label(for interface: Interface) -> String {
        let name = interface.name
        if interface.isWireless { return "Wi-Fi" }
        if name.hasPrefix("docker") || name.hasPrefix("br-") { return "Docker" }
        if ["virbr", "vnet", "vmnet", "vboxnet"].contains(where: name.hasPrefix) { return "Virtual machines" }
        if ["tun", "tap", "wg", "tailscale", "zt", "ppp"].contains(where: name.hasPrefix) { return "VPN" }
        guard interface.isHardware, !isVirtual(name) else { return name }
        return name.hasPrefix("ww") ? "Mobile broadband" : "Ethernet"
    }

    /// Whether the name is one Linux gives interfaces made in software.
    static func isVirtual(_ name: String) -> Bool {
        let prefixes = [
            "docker", "br-", "virbr", "veth", "vnet", "vmnet", "vboxnet", "lxcbr", "lxdbr", "incusbr", "podman",
            "cni", "flannel", "cali", "kube", "tun", "tap", "wg", "tailscale", "zt", "dummy",
        ]
        return prefixes.contains(where: name.hasPrefix)
    }

    /// The interfaces the default route goes through, from `/proc/net/route`, whose lines name
    /// the interface, then the destination and the gateway in hexadecimal, then the flags, and
    /// whose default route's destination and mask are 0.
    static func defaultRoutes(inTable table: String) -> Set<String> {
        var interfaces: Set<String> = []
        for line in table.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 8, fields[1] == "00000000", fields[7] == "00000000",
                let flags = Int(fields[3], radix: 16), flags & 0x1 != 0
            else { continue }
            interfaces.insert(String(fields[0]))
        }
        return interfaces
    }

    /// Each IPv4 address on an interface that's up, other than loopback, by interface name.
    private static func interfaces() -> [(name: String, address: String)] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var found: [(name: String, address: String)] = []
        var next = first
        while let current = next {
            next = current.pointee.ifa_next
            let flags = Int32(bitPattern: current.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                let socket = current.pointee.ifa_addr, socket.pointee.sa_family == sa_family_t(AF_INET),
                let name = current.pointee.ifa_name
            else { continue }
            let address = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            found.append((String(cString: name), text(address)))
        }
        return found
    }

    /// An IPv4 address as it's written, such as `192.168.1.125`.
    static func text(_ address: in_addr) -> String {
        withUnsafeBytes(of: address) { bytes in bytes.prefix(4).map(String.init).joined(separator: ".") }
    }
}

/// The hardware addresses of devices on the local network, from the kernel's ARP table, which
/// anyone may read.
public enum NetworkNeighbors {
    /// A device's hardware address, such as `aa:bb:cc:dd:ee:ff`, which stays the same when its IP
    /// address changes; `nil` when the kernel doesn't know it.
    public static func hardwareAddress(of ip: String) -> String? {
        hardwareAddress(of: ip, inTable: LinuxFile.text("/proc/net/arp") ?? "")
    }

    /// A device's hardware address from the text of `/proc/net/arp`, whose lines give the IP
    /// address, the hardware type, the flags, the hardware address, the mask and the interface.
    /// Entries still being looked up, without the complete flag (0x2), are left out.
    public static func hardwareAddress(of ip: String, inTable table: String) -> String? {
        for line in table.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 4, fields[0] == ip else { continue }
            let flags = Int(fields[2].dropFirst(fields[2].hasPrefix("0x") ? 2 : 0), radix: 16) ?? 0
            let address = fields[3].lowercased()
            let octets = address.split(separator: ":", omittingEmptySubsequences: false)
            guard flags & 0x2 != 0, octets.count == 6, octets.allSatisfy({ $0.count == 2 }),
                address != "00:00:00:00:00:00"
            else { continue }
            return address
        }
        return nil
    }
}
