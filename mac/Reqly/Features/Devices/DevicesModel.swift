import AppKit
import Capture
import Foundation
import Observation
import ProxyEngine
import ReqlyModel
import SourceResolver

/// Phones and tablets on the network: whether they may connect at all, the ones you let in, and
/// the ones waiting for you to decide. It also keeps the names you give devices of every kind.
@Observable
final class DevicesModel {
    /// A device you let in.
    struct Known: Codable, Hashable, Identifiable {
        var id: String
        /// The address it last connected from.
        var address: String
    }

    /// A device that wants to connect, waiting for you to decide.
    struct Request: Hashable, Identifiable {
        var id: String
        var address: String
    }

    /// Whether phones and tablets on the network may connect, once you let each one in.
    private(set) var allowsNetworkDevices: Bool
    private(set) var known: [Known] = []
    /// Devices waiting for you to decide, in the order they asked.
    private(set) var requests: [Request] = []
    /// The names you gave devices, by ID.
    private(set) var names: [String: String] = [:]
    /// Why devices can't connect, or why the devices you let in can't be saved.
    private(set) var problem: String?

    private let session: CaptureSession
    private let url: URL
    /// The devices you turned away since Reqly opened. They're asked about again next time.
    private var refused: Set<String> = []
    /// The connections waiting on each request's decision.
    private var waiting: [String: [CheckedContinuation<Bool, Never>]] = [:]
    /// Which device connects from each address.
    private var deviceAtAddress: [String: String] = [:]

    private struct Saved: Codable {
        var version = 1
        var known: [Known]
        var names: [String: String]
    }

    init(session: CaptureSession) {
        self.session = session
        url = Self.fileURL
        allowsNetworkDevices = UserDefaults.standard.bool(forKey: DefaultsKey.allowsNetworkDevices)
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data),
            saved.version <= 1
        {
            known = saved.known
            names = saved.names
            for device in known {
                deviceAtAddress[device.address] = device.id
            }
        }
        session.setDeviceAdmission { [weak self] client in
            await self?.admit(client) ?? false
        }
        let listens = allowsNetworkDevices
        Task {
            try? await session.setListensOnNetwork(listens)
        }
        #if DEBUG
            if let address = UserDefaults.standard.string(forKey: DefaultsKey.askAboutDevice) {
                // As if a device at that address had just connected.
                Task { _ = await admit(ClientAddress(ip: address, port: 0)) }
            }
        #endif
    }

    /// Where the devices you let in are saved. A debug build takes another file from
    /// `-devicesFile path`, so trying things out leaves yours alone.
    private static var fileURL: URL {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: DefaultsKey.devicesFile) {
                return URL(filePath: path)
            }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Reqly/Devices.json")
    }

    /// Lets devices on the network connect, or only this Mac. Turning it off closes their
    /// connections and turns away the ones waiting.
    func setAllowsNetworkDevices(_ allows: Bool) {
        allowsNetworkDevices = allows
        UserDefaults.standard.set(allows, forKey: DefaultsKey.allowsNetworkDevices)
        if !allows {
            for request in requests {
                decide(request, allow: false)
            }
        }
        Task {
            do {
                try await session.setListensOnNetwork(allows)
                problem = nil
            } catch CaptureError.portInUse(let port) {
                problem = "Another app uses port \(port) on the network, so devices can't connect."
            } catch {
                problem = "Devices can't connect. \(error.localizedDescription)"
            }
        }
    }

    /// Whether a device may send its traffic through Reqly: yes if you let it in before, no if
    /// you turned it away since Reqly opened, and otherwise once you decide.
    func admit(_ client: ClientAddress) async -> Bool {
        let id = Self.identity(of: client.ip)
        if let index = known.firstIndex(where: { $0.id == id }) {
            deviceAtAddress[client.ip] = id
            if known[index].address != client.ip {
                known[index].address = client.ip
                save()
            }
            return true
        }
        guard allowsNetworkDevices || isDebugRequest(client), !refused.contains(id) else { return false }
        if !requests.contains(where: { $0.id == id }) {
            requests.append(Request(id: id, address: client.ip))
            showWaiting()
            NSApp.requestUserAttention(.criticalRequest)
        }
        return await withCheckedContinuation { continuation in
            waiting[id, default: []].append(continuation)
        }
    }

    /// Lets a device in, with the name you gave it, or turns it away.
    func decide(_ request: Request, allow: Bool, name: String? = nil) {
        requests.removeAll { $0.id == request.id }
        showWaiting()
        if allow {
            known.removeAll { $0.id == request.id }
            known.append(Known(id: request.id, address: request.address))
            deviceAtAddress[request.address] = request.id
            if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                names[request.id] = name
            }
            save()
        } else {
            refused.insert(request.id)
        }
        for continuation in waiting.removeValue(forKey: request.id) ?? [] {
            continuation.resume(returning: allow)
        }
    }

    /// Stops letting a device in. It's asked about again the next time it connects.
    func forget(_ id: String) {
        known.removeAll { $0.id == id }
        deviceAtAddress = deviceAtAddress.filter { $0.value != id }
        save()
    }

    /// The device a connection from the network came from, once it was let in.
    func origin(ofAddress ip: String) -> Origin? {
        guard let id = deviceAtAddress[ip] else { return nil }
        return Origin(device: Device(id: id, kind: .network, name: names[id] ?? ip, address: ip))
    }

    /// A device with the name you gave it, if you gave it one.
    func named(_ device: Device) -> Device {
        var device = device
        if let name = names[device.id] {
            device.name = name
        }
        return device
    }

    /// The name a device shows with: yours, or its address or the name it came with.
    func name(of device: Device) -> String {
        names[device.id] ?? device.name
    }

    /// Keeps the name you gave a device, for its traffic from now on.
    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        names[id] = name
        save()
    }

    /// The Dock shows how many devices are waiting.
    private func showWaiting() {
        NSApp.dockTile.badgeLabel = requests.isEmpty ? nil : String(requests.count)
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(Saved(known: known, names: names)).write(to: url, options: .atomic)
        } catch {
            problem = "Reqly couldn't save the devices you let in. \(error.localizedDescription)"
        }
    }

    /// A device's hardware address, which stays the same when its IP address changes, or the IP
    /// address when that's all Reqly can see.
    private static func identity(of ip: String) -> String {
        NetworkNeighbors.hardwareAddress(of: ip).map { "mac:\($0)" } ?? "ip:\(ip)"
    }

    private func isDebugRequest(_ client: ClientAddress) -> Bool {
        #if DEBUG
            client.port == 0 && UserDefaults.standard.string(forKey: DefaultsKey.askAboutDevice) == client.ip
        #else
            false
        #endif
    }
}
