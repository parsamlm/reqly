import AppKit
import DeviceTools
import Foundation
import Observation

/// The simulators that are running, and putting Reqly's certificate in them.
///
/// Simulators use the Mac's network settings, so their traffic reaches Reqly while it captures.
/// To read their HTTPS, each needs Reqly's certificate in its own keychain.
@Observable
final class SimulatorsModel {
    enum Installation: Equatable {
        case installing
        case installed
        case failed(String)
    }

    private(set) var simulators: [Simulator] = []
    /// How putting a certificate in each simulator went, and which certificate it was.
    private var installations: [String: (certificate: [UInt8], state: Installation)] = [:]
    /// Why the simulators can't be listed.
    private(set) var problem: String?
    private(set) var isRefreshing = false
    /// Simulators come with Xcode.
    let hasXcode: Bool
    private let tools: Simulators

    init() {
        let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
        hasXcode = xcode != nil
        tools = Simulators(developerDirectory: xcode?.appending(path: "Contents/Developer"))
    }

    func refresh() async {
        guard hasXcode else {
            problem = "Simulators come with Xcode. Install Xcode to use them with Reqly."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            simulators = try await tools.booted()
            problem = nil
        } catch {
            simulators = []
            problem = "Reqly couldn't list the simulators. \(error.localizedDescription)"
        }
    }

    /// How putting `certificate` in the simulator went, or `nil` if Reqly hasn't yet. A simulator
    /// that has an earlier certificate needs this one too, so it counts as not yet.
    func installation(on simulator: Simulator, of certificate: [UInt8]?) -> Installation? {
        guard let installation = installations[simulator.id], installation.certificate == certificate else {
            return nil
        }
        return installation.state
    }

    /// Adds Reqly's certificate to the simulator's keychain, trusted for HTTPS.
    func installCertificate(on simulator: Simulator, certificate: [UInt8]) async {
        installations[simulator.id] = (certificate, .installing)
        do {
            try await tools.installCertificate(der: certificate, on: simulator.id)
            installations[simulator.id] = (certificate, .installed)
        } catch {
            installations[simulator.id] = (certificate, .failed(error.localizedDescription))
        }
    }
}
