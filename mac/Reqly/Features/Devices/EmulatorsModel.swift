import DeviceTools
import Foundation
import Observation

/// The Android emulators that are running, and pointing them at Reqly with adb.
@Observable
final class EmulatorsModel {
    struct Emulator: Hashable, Identifiable {
        /// adb's serial, such as `emulator-5554`.
        var id: String
        /// Such as "Pixel 10 Pro XL".
        var name: String
        /// The proxy it sends its traffic to, such as `10.0.2.2:9090`.
        var proxy: String?
        /// Still starting up, or not answering adb.
        var isReady: Bool
    }

    private(set) var emulators: [Emulator] = []
    /// Why the emulators can't be reached.
    private(set) var problem: String?
    private(set) var isRefreshing = false
    /// The emulators that are being changed right now.
    private(set) var busy: Set<String> = []
    /// What happened last with each emulator, such as a failure.
    private(set) var notes: [String: String] = [:]
    /// adb, from Android Studio or the Android SDK.
    let adb: AndroidDebugBridge?

    init() {
        adb = AndroidDebugBridge.find()
    }

    /// The proxy that points an emulator at Reqly on `port`.
    static func proxy(port: Int) -> String {
        "\(AndroidDebugBridge.macAddress):\(port)"
    }

    func refresh() async {
        guard let adb else {
            problem = "Reqly can't find adb. It comes with Android Studio, or with the Android SDK Platform Tools."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var found: [Emulator] = []
            for device in try await adb.devices() where device.isEmulator {
                var emulator = Emulator(id: device.id, name: device.model ?? device.id, isReady: device.isReady)
                if device.isReady {
                    if let name = try? await adb.emulatorName(device.id) {
                        emulator.name = name.replacingOccurrences(of: "_", with: " ")
                    }
                    emulator.proxy = try? await adb.proxy(of: device.id)
                }
                found.append(emulator)
            }
            emulators = found
            problem = nil
        } catch {
            emulators = []
            problem = "Reqly couldn't ask adb about emulators. \(error.localizedDescription)"
        }
    }

    /// Points the emulator's traffic at Reqly on `port`, or back to a direct connection.
    func setUsesReqly(_ uses: Bool, emulator: Emulator, port: Int) async {
        await change(emulator) { adb in
            try await adb.setProxy(uses ? Self.proxy(port: port) : nil, on: emulator.id)
        }
    }

    /// Copies Reqly's certificate into the emulator's Downloads, and opens its security
    /// settings, where you install it.
    func copyCertificate(to emulator: Emulator, certificate: [UInt8]) async {
        await change(emulator) { adb in
            try await adb.copyCertificate(der: certificate, to: emulator.id)
            try await adb.openSecuritySettings(on: emulator.id)
        }
        if notes[emulator.id] == nil {
            notes[emulator.id] = "Copied “Reqly CA.crt” to Downloads."
        }
    }

    private func change(_ emulator: Emulator, _ body: (AndroidDebugBridge) async throws -> Void) async {
        guard let adb else { return }
        busy.insert(emulator.id)
        defer { busy.remove(emulator.id) }
        notes[emulator.id] = nil
        do {
            try await body(adb)
        } catch {
            notes[emulator.id] = error.localizedDescription
        }
        await refresh()
    }
}
