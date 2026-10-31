import Foundation
import ReqlyModel
import Synchronization
import Testing

/// Made-up proxy settings: a proxy, or none, and the addresses that go around it.
struct MadeUpProxySettings: UserProxySettings, Equatable {
    var proxy: String?
    var bypass: String?

    static let noProxy = MadeUpProxySettings()

    func capturing(port: Int) -> MadeUpProxySettings {
        MadeUpProxySettings(proxy: "127.0.0.1:\(port)", bypass: bypass)
    }

    func pointsAtReqly(port: Int) -> Bool {
        proxy == "127.0.0.1:\(port)"
    }
}

/// Proxy settings kept in memory, so the tests never touch the computer's own.
final class StandInSettings: ProxySettingsStore {
    private let state: Mutex<(settings: MadeUpProxySettings, failsWrites: Bool)>

    init(_ settings: MadeUpProxySettings) {
        state = Mutex((settings, false))
    }

    var settings: MadeUpProxySettings {
        get { state.withLock { $0.settings } }
        set { state.withLock { $0.settings = newValue } }
    }

    var failsWrites: Bool {
        get { state.withLock { $0.failsWrites } }
        set { state.withLock { $0.failsWrites = newValue } }
    }

    struct Refused: Error {}

    func read() throws -> MadeUpProxySettings {
        settings
    }

    func write(_ settings: MadeUpProxySettings) throws {
        try state.withLock { state in
            if state.failsWrites {
                throw Refused()
            }
            state.settings = settings
        }
    }
}

@Suite struct UserProxySwitchTests {
    /// Settings someone might have: a company proxy and its bypass list.
    static let yours = MadeUpProxySettings(proxy: "proxy.corp:8080", bypass: "<local>;*.corp")

    static func restoreFile() -> URL {
        URL.temporaryDirectory.appending(path: "ReqlyProxyTests-\(UUID().uuidString)/ProxyRestore.json")
    }

    @Test func putsYourSettingsBackAfterCapturing() async throws {
        let settings = StandInSettings(Self.yours)
        let file = Self.restoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let proxy = UserProxySwitch(settings: settings, restoreFile: file)
        try await proxy.enable(port: 9090)
        #expect(settings.settings.pointsAtReqly(port: 9090))
        #expect(FileManager.default.fileExists(atPath: file.path))

        try await proxy.disable()
        #expect(settings.settings == Self.yours)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Nothing to put back the second time.
        try await proxy.disable()
        #expect(settings.settings == Self.yours)
    }

    @Test func switchesOnAndOffAgainAndAgain() async throws {
        let settings = StandInSettings(Self.yours)
        let file = Self.restoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let proxy = UserProxySwitch(settings: settings, restoreFile: file)
        for _ in 0..<3 {
            try await proxy.enable(port: 9090)
            #expect(settings.settings.pointsAtReqly(port: 9090))
            try await proxy.disable()
            #expect(settings.settings == Self.yours)
        }
    }

    @Test func leavesSettingsYouChangedMeanwhile() async throws {
        let settings = StandInSettings(Self.yours)
        let file = Self.restoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let proxy = UserProxySwitch(settings: settings, restoreFile: file)
        try await proxy.enable(port: 9090)
        let changed = MadeUpProxySettings.noProxy
        settings.settings = changed
        try await proxy.disable()
        #expect(settings.settings == changed)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func putsThemBackAfterACrash() async throws {
        let settings = StandInSettings(Self.yours)
        let file = Self.restoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // A Reqly that quit without switching back.
        try await UserProxySwitch(settings: settings, restoreFile: file).enable(port: 9090)

        #expect(try UserProxySwitch.restoreLeftBehind(settings: settings, restoreFile: file))
        #expect(settings.settings == Self.yours)
        #expect(try !UserProxySwitch.restoreLeftBehind(settings: settings, restoreFile: file))
    }

    @Test func keepsYourSettingsWhenCapturingStartsAgain() async throws {
        let settings = StandInSettings(Self.yours)
        let file = Self.restoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // An earlier Reqly left its settings, then a new one starts on another port.
        try await UserProxySwitch(settings: settings, restoreFile: file).enable(port: 9090)
        let proxy = UserProxySwitch(settings: settings, restoreFile: file)
        try await proxy.enable(port: 9091)
        #expect(settings.settings.pointsAtReqly(port: 9091))
        try await proxy.disable()
        #expect(settings.settings == Self.yours)
    }

    @Test func changesNothingWhenTheSystemRefuses() async throws {
        let settings = StandInSettings(Self.yours)
        settings.failsWrites = true
        let file = Self.restoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await #expect(throws: StandInSettings.Refused.self) {
            try await UserProxySwitch(settings: settings, restoreFile: file).enable(port: 9090)
        }
        #expect(settings.settings == Self.yours)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Your settings and the port, which Reqly for Windows' betas wrote too.
    @Test func keepsYourSettingsAndThePortInTheRestoreFile() async throws {
        let settings = StandInSettings(Self.yours)
        let file = Self.restoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await UserProxySwitch(settings: settings, restoreFile: file).enable(port: 9090)
        let kept = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(kept.keys) == ["yours", "port"])
        #expect(kept["port"] as? Int == 9090)
        let yours = try #require(kept["yours"] as? [String: Any])
        #expect(yours["proxy"] as? String == "proxy.corp:8080")
    }

    @Test func keepsStandInSettingsInAFile() throws {
        let file = Self.restoreFile().deletingLastPathComponent().appending(path: "Settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let settings = FileProxySettings<MadeUpProxySettings>(file: file)
        // No file yet: no proxy, as a computer starts.
        #expect(try settings.read() == .noProxy)
        try settings.write(Self.yours)
        #expect(try settings.read() == Self.yours)
    }
}
