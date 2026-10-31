import Capture
import DeviceBridge
import Foundation
import ReqlyModel
import Synchronization

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

/// Phones and tablets on the network, as the Devices window shows them.
public struct DevicesState: Sendable, Equatable {
    /// A device you let in.
    public struct Known: Sendable, Equatable {
        public var id: String
        /// The name you gave it, if you gave it one.
        public var name: String?
        /// The address it last connected from.
        public var address: String
        /// Such as `aa:bb:cc:dd:ee:ff`, when its ID is that.
        public var hardwareAddress: String?

        public init(id: String, name: String? = nil, address: String, hardwareAddress: String? = nil) {
            self.id = id
            self.name = name
            self.address = address
            self.hardwareAddress = hardwareAddress
        }
    }

    public var allowsNetworkDevices: Bool
    public var known: [Known]
    /// Devices waiting for you to decide, in the order they asked.
    public var waiting: [DevicesBook.Request]
    /// This computer's addresses on the networks devices can reach, the likeliest first.
    public var addresses: [SystemParts.Address]
    public var problem: String?

    public init(
        allowsNetworkDevices: Bool, known: [Known], waiting: [DevicesBook.Request], addresses: [SystemParts.Address],
        problem: String? = nil
    ) {
        self.allowsNetworkDevices = allowsNetworkDevices
        self.known = known
        self.waiting = waiting
        self.addresses = addresses
        self.problem = problem
    }

    init(_ book: DevicesBook, allowsNetworkDevices: Bool, addresses: [SystemParts.Address], problem: String?) {
        self.allowsNetworkDevices = allowsNetworkDevices
        known = book.known.map {
            Known(
                id: $0.id, name: book.names[$0.id], address: $0.address,
                hardwareAddress: $0.id.hasPrefix("mac:") ? String($0.id.dropFirst(4)) : nil)
        }
        waiting = book.requests
        self.addresses = addresses
        self.problem = problem
    }
}

/// The Android emulators that run, as the Devices window shows them.
public struct Emulators: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var emulator: AndroidEmulator
        /// Its proxy is Reqly, on the port asked about.
        public var usesReqly: Bool

        public init(emulator: AndroidEmulator, usesReqly: Bool) {
            self.emulator = emulator
            self.usesReqly = usesReqly
        }
    }

    /// Whether Reqly found adb.
    public var hasAdb: Bool
    public var emulators: [Row]
    public var problem: String?

    public init(hasAdb: Bool, emulators: [Row], problem: String? = nil) {
        self.hasAdb = hasAdb
        self.emulators = emulators
        self.problem = problem
    }
}
