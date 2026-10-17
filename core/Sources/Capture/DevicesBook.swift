import Foundation
import ReqlyModel

/// Phones and tablets on the network: the ones you let in, the ones waiting for you to decide, and
/// the names you give devices of every kind. The Mac and the Windows app decide alike, and keep
/// them in the same file.
public struct DevicesBook: Sendable {
    /// A device you let in.
    public struct Known: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        /// The address it last connected from.
        public var address: String

        public init(id: String, address: String) {
            self.id = id
            self.address = address
        }
    }

    /// A device that wants to connect, waiting for you to decide.
    public struct Request: Hashable, Identifiable, Sendable {
        public var id: String
        public var address: String

        public init(id: String, address: String) {
            self.id = id
            self.address = address
        }
    }

    /// What becomes of a device that connects.
    public enum Verdict: Equatable, Sendable {
        case allow
        case refuse
        /// It waits for you to decide. A new request is one you weren't asked about yet.
        case ask(isNewRequest: Bool)
    }

    public private(set) var known: [Known] = []
    /// Devices waiting for you to decide, in the order they asked.
    public private(set) var requests: [Request] = []
    /// The names you gave devices, by ID.
    public private(set) var names: [String: String] = [:]
    /// The devices you turned away since Reqly opened. They're asked about again next time.
    private var refused: Set<String> = []
    /// Which device connects from each address.
    private var deviceAtAddress: [String: String] = [:]

    public init(_ contents: DevicesFile.Contents = DevicesFile.Contents()) {
        known = contents.known
        names = contents.names
        for device in known {
            deviceAtAddress[device.address] = device.id
        }
    }

    public var contents: DevicesFile.Contents {
        DevicesFile.Contents(known: known, names: names)
    }

    /// Whether a device may send its traffic through Reqly: yes if you let it in before, no if you
    /// turned it away since Reqly opened or devices aren't allowed, and otherwise once you decide.
    /// A device you let in that comes from a new address is remembered there, which `contents` keeps.
    public mutating func admit(id: String, address: String, allowsNetworkDevices: Bool) -> Verdict {
        if let index = known.firstIndex(where: { $0.id == id }) {
            deviceAtAddress[address] = id
            known[index].address = address
            return .allow
        }
        guard allowsNetworkDevices, !refused.contains(id) else { return .refuse }
        if requests.contains(where: { $0.id == id }) {
            return .ask(isNewRequest: false)
        }
        requests.append(Request(id: id, address: address))
        return .ask(isNewRequest: true)
    }

    /// Lets a device in, with the name you gave it, or turns it away until Reqly quits.
    public mutating func decide(_ id: String, allow: Bool, name: String? = nil) {
        guard let request = requests.first(where: { $0.id == id }) else { return }
        requests.removeAll { $0.id == id }
        if allow {
            known.removeAll { $0.id == id }
            known.append(Known(id: id, address: request.address))
            deviceAtAddress[request.address] = id
            if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                names[id] = name
            }
        } else {
            refused.insert(id)
        }
    }

    /// Turns away every device waiting, as when devices stop being allowed. Says which.
    public mutating func refuseAll() -> [String] {
        let ids = requests.map(\.id)
        for id in ids {
            decide(id, allow: false)
        }
        return ids
    }

    /// Stops letting a device in. It's asked about again the next time it connects. Its name stays.
    public mutating func forget(_ id: String) {
        known.removeAll { $0.id == id }
        deviceAtAddress = deviceAtAddress.filter { $0.value != id }
    }

    /// Keeps the name you gave a device, for its traffic from now on. A blank name changes nothing.
    @discardableResult
    public mutating func rename(_ id: String, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        names[id] = name
        return true
    }

    /// The device a connection from the network came from, once it was let in.
    public func device(atAddress ip: String) -> Device? {
        guard let id = deviceAtAddress[ip] else { return nil }
        return Device(id: id, kind: .network, name: names[id] ?? ip, address: ip)
    }

    /// A device with the name you gave it, if you gave it one.
    public func named(_ device: Device) -> Device {
        var device = device
        if let name = names[device.id] {
            device.name = name
        }
        return device
    }
}

/// The devices you let in, and the names you gave devices, saved as JSON.
public enum DevicesFile {
    public struct Contents: Codable, Hashable, Sendable {
        public var version = 1
        public var known: [DevicesBook.Known] = []
        public var names: [String: String] = [:]

        public init(known: [DevicesBook.Known] = [], names: [String: String] = [:]) {
            self.known = known
            self.names = names
        }
    }

    /// The saved devices. A file that's missing, can't be read, or comes from a newer Reqly reads as none.
    public static func load(from url: URL) -> Contents {
        guard let data = try? Data(contentsOf: url),
            let contents = try? JSONDecoder().decode(Contents.self, from: data),
            contents.version <= 1
        else { return Contents() }
        return contents
    }

    public static func save(_ contents: Contents, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileReplacement.write(encoder.encode(contents), to: url)
    }

    public static func saveProblem(_ error: any Error) -> String {
        "Reqly couldn't save the devices you let in. \(error.localizedDescription)"
    }

    /// A device's ID: its hardware address, which stays the same when its IP address changes, or
    /// the IP address when that's all Reqly can see.
    public static func identity(ip: String, hardwareAddress: String?) -> String {
        hardwareAddress.map { "mac:\($0)" } ?? "ip:\(ip)"
    }

    /// What it means when devices can't connect.
    public static func listeningProblem(_ error: any Error) -> String {
        if case CaptureError.portInUse(let port) = error {
            return "Another app uses port \(port) on the network, so devices can't connect."
        }
        return "Devices can't connect. \(error.localizedDescription)"
    }
}
