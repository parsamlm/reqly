import Foundation

/// An Android device or emulator that adb can reach.
public struct AndroidDevice: Hashable, Sendable, Identifiable {
    /// adb's serial for it, such as `emulator-5554`.
    public var id: String
    /// adb's word for its state: `device` once it's ready, or `offline` or `unauthorized`.
    public var state: String
    /// Such as `sdk_gphone64_arm64`.
    public var model: String?

    public init(id: String, state: String, model: String? = nil) {
        self.id = id
        self.state = state
        self.model = model
    }

    public var isEmulator: Bool { id.hasPrefix("emulator-") }
    public var isReady: Bool { state == "device" }
}

/// Android's debug bridge, `adb`, which points emulators at Reqly and copies its certificate over.
public struct AndroidDebugBridge: Sendable, Hashable {
    /// The emulator's own address for the Mac it runs on.
    public static let macAddress = "10.0.2.2"

    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// adb where Android Studio, the Android SDK or Homebrew put it.
    public static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = .homeDirectory
    ) -> AndroidDebugBridge? {
        var candidates: [URL] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environment[key] {
                candidates.append(URL(filePath: sdk).appending(path: "platform-tools/adb"))
            }
        }
        candidates.append(home.appending(path: "Library/Android/sdk/platform-tools/adb"))
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"].map { URL(filePath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
            .map(AndroidDebugBridge.init)
    }

    /// The devices and emulators adb can reach.
    public func devices() async throws -> [AndroidDevice] {
        Self.parseDevices(try await adb(["devices", "-l"]))
    }

    /// The virtual device an emulator runs, such as `Pixel_10_Pro_XL`.
    public func emulatorName(_ serial: String) async throws -> String? {
        let output = try await adb(["-s", serial, "emu", "avd", "name"])
        let name = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return name.flatMap { $0.isEmpty || $0 == "OK" ? nil : $0 }
    }

    /// The proxy the device sends its traffic to, such as `10.0.2.2:9090`, or `nil` for none.
    public func proxy(of serial: String) async throws -> String? {
        let output = try await adb(["-s", serial, "shell", "settings", "get", "global", "http_proxy"])
        return Self.proxySetting(output)
    }

    /// Points the device's traffic at `proxy`, such as `10.0.2.2:9090`, or `nil` to go direct again.
    public func setProxy(_ proxy: String?, on serial: String) async throws {
        _ = try await adb(["-s", serial, "shell", "settings", "put", "global", "http_proxy", proxy ?? ":0"])
    }

    /// Copies Reqly's certificate into the device's Downloads, to install from its Settings.
    public func copyCertificate(der: [UInt8], to serial: String) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "Reqly CA \(UUID().uuidString).crt")
        try Data(der).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await adb(["-s", serial, "push", file.path(percentEncoded: false), "/sdcard/Download/Reqly CA.crt"])
    }

    /// Opens the device's security settings, where certificates are installed.
    public func openSecuritySettings(on serial: String) async throws {
        _ = try await adb(["-s", serial, "shell", "am", "start", "-a", "android.settings.SECURITY_SETTINGS"])
    }

    private func adb(_ arguments: [String]) async throws -> String {
        try await Tool.run(executable, arguments)
    }

    /// The devices in `adb devices -l`, such as
    /// `emulator-5554 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:1`.
    static func parseDevices(_ output: String) -> [AndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map {
                String($0.dropFirst("model:".count))
            }
            return AndroidDevice(id: fields[0], state: fields[1], model: model)
        }
    }

    /// What `settings get global http_proxy` says, with no proxy as `nil`.
    static func proxySetting(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "null" || value == ":0" ? nil : value
    }
}
