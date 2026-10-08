import Foundation

/// A phone, tablet, simulator or emulator whose traffic comes through Reqly. Traffic from the
/// Mac's own apps has no device.
public struct Device: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// A phone or tablet on the same network as the Mac.
        case network
        /// An iOS, iPadOS, watchOS, tvOS or visionOS Simulator on this Mac.
        case simulator
        /// An Android emulator on this Mac.
        case emulator
    }

    /// What tells the device apart across connections and launches: a simulator's UDID, an
    /// emulator's name, or a network device's hardware address, or its IP address when that's
    /// all Reqly can see.
    public var id: String
    public var kind: Kind
    /// The name to show, such as "Parsa's iPhone", "iPhone 17 Pro" or "192.168.1.23".
    public var name: String
    /// The IP address a network device connects from.
    public var address: String?

    public init(id: String, kind: Kind, name: String, address: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.address = address
    }
}

/// Where a connection came from: the app or tool that opened it, and the device it runs on.
public struct Origin: Hashable, Sendable {
    public var source: Source?
    public var device: Device?

    public init(source: Source? = nil, device: Device? = nil) {
        self.source = source
        self.device = device
    }
}

/// Traffic by where it came from: the Mac's own apps, or one device.
public enum DeviceChoice: Hashable, Sendable {
    case thisMac
    /// The device with this ID.
    case device(String)

    public func matches(_ device: Device?) -> Bool {
        switch self {
        case .thisMac: device == nil
        case .device(let id): device?.id == id
        }
    }
}
