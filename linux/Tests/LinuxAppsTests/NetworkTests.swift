import Testing

@testable import LinuxApps

@Suite struct NetworkTests {
    /// /proc/net/arp as Linux writes it: complete entries, one still being looked up, and one
    /// that failed.
    private let arp = """
        IP address       HW type     Flags       HW address            Mask     Device
        192.168.1.1      0x1         0x2         a4:91:b1:0c:2d:3e     *        wlp2s0
        192.168.1.23     0x1         0x2         3A:5F:0B:9C:11:E2     *        wlp2s0
        192.168.1.40     0x1         0x0         00:00:00:00:00:00     *        wlp2s0
        192.168.1.41     0x1         0x0         5e:00:00:00:00:41     *        wlp2s0
        192.168.1.50     0x1         0x6         02:42:ac:11:00:02     *        enp3s0
        172.17.0.2       0x1         0x2         00:00:00:00:00:00     *        docker0
        10.0.0.9         0x1         0x2         incomplete            *        eth0
        """

    @Test func readsHardwareAddresses() {
        #expect(NetworkNeighbors.hardwareAddress(of: "192.168.1.1", inTable: arp) == "a4:91:b1:0c:2d:3e")
        // In lowercase, as the Mac and Windows give them.
        #expect(NetworkNeighbors.hardwareAddress(of: "192.168.1.23", inTable: arp) == "3a:5f:0b:9c:11:e2")
        // Complete and permanent.
        #expect(NetworkNeighbors.hardwareAddress(of: "192.168.1.50", inTable: arp) == "02:42:ac:11:00:02")
        // Still being looked up, or failed.
        #expect(NetworkNeighbors.hardwareAddress(of: "192.168.1.40", inTable: arp) == nil)
        #expect(NetworkNeighbors.hardwareAddress(of: "192.168.1.41", inTable: arp) == nil)
        #expect(NetworkNeighbors.hardwareAddress(of: "172.17.0.2", inTable: arp) == nil)
        #expect(NetworkNeighbors.hardwareAddress(of: "10.0.0.9", inTable: arp) == nil)
        // Not a prefix of another address.
        #expect(NetworkNeighbors.hardwareAddress(of: "192.168.1.2", inTable: arp) == nil)
        #expect(NetworkNeighbors.hardwareAddress(of: "192.168.1.1", inTable: "") == nil)
    }

    @Test func findsTheDefaultRoute() {
        let routes = """
            Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
            wlp2s0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0
            wlp2s0\t0001A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0
            docker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0
            wg0\t00000000\t00000000\t0000\t0\t0\t0\t00000000\t0\t0\t0
            """
        #expect(NetworkAddresses.defaultRoutes(inTable: routes) == ["wlp2s0"])
        #expect(NetworkAddresses.defaultRoutes(inTable: "").isEmpty)
    }

    @Test func putsTheLikeliestAddressesFirst() {
        func interface(
            _ name: String, _ address: String, wireless: Bool = false, hardware: Bool = true, route: Bool = false
        ) -> NetworkAddresses.Interface {
            NetworkAddresses.Interface(
                name: name, address: address, isWireless: wireless, isHardware: hardware, hasDefaultRoute: route)
        }
        let addresses = NetworkAddresses.ordered([
            interface("docker0", "172.17.0.1", hardware: false),
            interface("virbr0", "192.168.122.1", hardware: false),
            interface("veth1a2b3c", "169.254.3.4", hardware: false),
            interface("br-5f2e1c", "172.18.0.1", hardware: false),
            interface("wg0", "10.8.0.2", hardware: false, route: true),
            interface("enp3s0", "192.168.1.60"),
            interface("wwan0", "100.64.1.2"),
            interface("wlp2s0", "192.168.1.125", wireless: true, route: true),
            interface("enx00e04c680001", "10.0.0.5"),
        ])
        #expect(
            addresses.map(\.address) == [
                "192.168.1.125", "192.168.1.60", "10.0.0.5", "100.64.1.2", "10.8.0.2", "172.17.0.1", "192.168.122.1",
                "169.254.3.4", "172.18.0.1",
            ])
        #expect(
            addresses.map(\.interface) == [
                "Wi-Fi", "Ethernet (enp3s0)", "Ethernet (enx00e04c680001)", "Mobile broadband", "VPN",
                "Docker (docker0)",
                "Virtual machines", "veth1a2b3c", "Docker (br-5f2e1c)",
            ])
        // A wired connection with the way out comes before Wi-Fi without one.
        let wired = NetworkAddresses.ordered([
            interface("wlp2s0", "192.168.1.125", wireless: true), interface("eth0", "192.168.1.61", route: true),
        ])
        #expect(wired.map(\.interface) == ["Ethernet", "Wi-Fi"])
        // A name made in software, even with a device behind it.
        #expect(
            NetworkAddresses.ordered([interface("docker0", "172.17.0.1"), interface("eno1", "10.1.1.1")]).first?.address
                == "10.1.1.1")
    }

    /// This computer's own, in the test's container.
    @Test func listsThisComputersAddresses() {
        let addresses = NetworkAddresses.current()
        #expect(!addresses.contains { $0.address.hasPrefix("127.") })
        #expect(addresses.allSatisfy { !$0.interface.isEmpty && $0.address.split(separator: ".").count == 4 })
    }
}
