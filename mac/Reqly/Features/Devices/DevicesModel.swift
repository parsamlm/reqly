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
    typealias Known = DevicesBook.Known
    typealias Request = DevicesBook.Request

    /// Whether phones and tablets on the network may connect, once you let each one in.
    private(set) var allowsNetworkDevices: Bool
    /// The devices you let in, the ones waiting, and the names you gave devices.
    private(set) var book = DevicesBook()
    /// Why devices can't connect, or why the devices you let in can't be saved.
    private(set) var problem: String?

    var known: [Known] { book.known }
    /// Devices waiting for you to decide, in the order they asked.
    var requests: [Request] { book.requests }
    /// The names you gave devices, by ID.
    var names: [String: String] { book.names }

    private let session: CaptureSession
    private let url: URL
    /// The connections waiting on each request's decision.
    private var waiting: [String: [CheckedContinuation<Bool, Never>]] = [:]

    init(session: CaptureSession) {
        self.session = session
        url = Self.fileURL
        allowsNetworkDevices = UserDefaults.standard.bool(forKey: DefaultsKey.allowsNetworkDevices)
        book = DevicesBook(DevicesFile.load(from: url))
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
            } catch {
                problem = DevicesFile.listeningProblem(error)
            }
        }
    }

    /// Whether a device may send its traffic through Reqly: yes if you let it in before, no if
    /// you turned it away since Reqly opened, and otherwise once you decide.
    func admit(_ client: ClientAddress) async -> Bool {
        let id = DevicesFile.identity(ip: client.ip, hardwareAddress: NetworkNeighbors.hardwareAddress(of: client.ip))
        let saved = book.contents
        let verdict = book.admit(
            id: id, address: client.ip, allowsNetworkDevices: allowsNetworkDevices || isDebugRequest(client))
        if book.contents != saved {
            save()
        }
        switch verdict {
        case .allow:
            return true
        case .refuse:
            return false
        case .ask(let isNewRequest):
            if isNewRequest {
                showWaiting()
                NSApp.requestUserAttention(.criticalRequest)
            }
            return await withCheckedContinuation { continuation in
                waiting[id, default: []].append(continuation)
            }
        }
    }

    /// Lets a device in, with the name you gave it, or turns it away.
    func decide(_ request: Request, allow: Bool, name: String? = nil) {
        book.decide(request.id, allow: allow, name: name)
        showWaiting()
        if allow {
            save()
        }
        for continuation in waiting.removeValue(forKey: request.id) ?? [] {
            continuation.resume(returning: allow)
        }
    }

    /// Stops letting a device in. It's asked about again the next time it connects.
    func forget(_ id: String) {
        book.forget(id)
        save()
    }

    /// The device a connection from the network came from, once it was let in.
    func origin(ofAddress ip: String) -> Origin? {
        book.device(atAddress: ip).map { Origin(device: $0) }
    }

    /// A device with the name you gave it, if you gave it one.
    func named(_ device: Device) -> Device {
        book.named(device)
    }

    /// The name a device shows with: yours, or its address or the name it came with.
    func name(of device: Device) -> String {
        names[device.id] ?? device.name
    }

    /// Keeps the name you gave a device, for its traffic from now on.
    func rename(_ id: String, to name: String) {
        if book.rename(id, to: name) {
            save()
        }
    }

    /// The Dock shows how many devices are waiting.
    private func showWaiting() {
        NSApp.dockTile.badgeLabel = requests.isEmpty ? nil : String(requests.count)
    }

    private func save() {
        do {
            try DevicesFile.save(book.contents, to: url)
        } catch {
            problem = DevicesFile.saveProblem(error)
        }
    }

    private func isDebugRequest(_ client: ClientAddress) -> Bool {
        #if DEBUG
            client.port == 0 && UserDefaults.standard.string(forKey: DefaultsKey.askAboutDevice) == client.ip
        #else
            false
        #endif
    }
}
