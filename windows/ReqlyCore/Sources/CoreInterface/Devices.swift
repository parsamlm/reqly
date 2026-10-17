import Capture
import Foundation
import ReqlyModel
import Synchronization
import WindowsSystem

/// The devices you let in, by the address each connects from, for naming each connection from the
/// network as it opens. The session reads it while the host changes it.
final class DeviceOrigins: Sendable {
    private let devices = Mutex<[String: Device]>([:])

    func device(atAddress ip: String) -> Device? {
        devices.withLock { $0[ip] }
    }

    func use(_ book: DevicesBook) {
        let known = book.known.compactMap { known in book.device(atAddress: known.address).map { (known.address, $0) } }
        devices.withLock { $0 = Dictionary(known, uniquingKeysWith: { $1 }) }
    }
}

/// The Android emulators that run, as the Devices window shows them.
struct WireEmulators: Encodable {
    struct Emulator: Encodable {
        /// adb's serial, such as `emulator-5554`.
        var id: String
        /// Such as "Pixel 10 Pro XL".
        var name: String
        /// The proxy it sends its traffic to, such as `10.0.2.2:9090`.
        var proxy: String?
        /// Still starting up, or not answering adb.
        var isReady: Bool
        /// Its proxy is Reqly, on the port asked about.
        var usesReqly: Bool
    }

    /// Whether Reqly found adb.
    var hasAdb: Bool
    var emulators: [Emulator]
    var problem: String?
}

/// Phones and tablets on the network, as the Devices window shows them.
struct WireDevices: Encodable {
    struct Known: Encodable {
        var id: String
        /// The name you gave it, if you gave it one.
        var name: String?
        /// The address it last connected from.
        var address: String
        /// Such as `aa:bb:cc:dd:ee:ff`, when its ID is that.
        var hardwareAddress: String?
    }

    struct Waiting: Encodable {
        var id: String
        var address: String
    }

    struct Address: Encodable {
        /// Such as "Wi-Fi".
        var interface: String
        var address: String
    }

    var allowsNetworkDevices: Bool
    var known: [Known]
    /// Devices waiting for you to decide, in the order they asked.
    var waiting: [Waiting]
    /// This computer's addresses on the networks devices can reach, the likeliest first.
    var addresses: [Address]
    var problem: String?

    init(_ book: DevicesBook, allowsNetworkDevices: Bool, addresses: [NetworkAddresses.Address], problem: String?) {
        self.allowsNetworkDevices = allowsNetworkDevices
        known = book.known.map {
            Known(
                id: $0.id, name: book.names[$0.id], address: $0.address,
                hardwareAddress: $0.id.hasPrefix("mac:") ? String($0.id.dropFirst(4)) : nil)
        }
        waiting = book.requests.map { Waiting(id: $0.id, address: $0.address) }
        self.addresses = addresses.map { Address(interface: $0.interface, address: $0.address) }
        self.problem = problem
    }
}
