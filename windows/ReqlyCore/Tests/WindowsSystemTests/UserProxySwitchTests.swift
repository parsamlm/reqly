import Foundation
import Synchronization
import Testing
import WindowsSystem

/// Proxy settings kept in memory, so the tests never touch the computer's own.
final class StandInSettings: ProxySettingsStore {
    private let state: Mutex<(settings: ProxySettings, failsWrites: Bool)>

    init(_ settings: ProxySettings) {
        state = Mutex((settings, false))
    }

    var settings: ProxySettings {
        get { state.withLock { $0.settings } }
        set { state.withLock { $0.settings = newValue } }
    }

    var failsWrites: Bool {
        get { state.withLock { $0.failsWrites } }
        set { state.withLock { $0.failsWrites = newValue } }
    }

    struct Refused: Error {}

    func read() throws -> ProxySettings {
        settings
    }

    func write(_ settings: ProxySettings) throws {
        try state.withLock { state in
            if state.failsWrites {
                throw Refused()
            }
            state.settings = settings
        }
    }
}

@Suite struct UserProxySwitchTests {
    /// Settings someone might have: a company proxy, its bypass list, and automatic detection.
    static let yours = ProxySettings(
        flags: ProxySettings.direct | ProxySettings.usesProxy | ProxySettings.detectsAutomatically,
        server: "proxy.corp:8080", bypass: "<local>;*.corp", setupScript: "http://wpad/old.pac")

    static func restoreFile() -> URL {
        URL.temporaryDirectory.appending(path: "ReqlyProxyTests-\(UUID().uuidString)/ProxyRestore.json")
    }

    @Test func sendsHTTPAndHTTPSThroughReqlyAndKeepsTheRest() {
        let capturing = Self.yours.capturing(port: 9090)
        #expect(capturing.server == "http=127.0.0.1:9090;https=127.0.0.1:9090")
        #expect(capturing.flags == Self.yours.flags)
        #expect(capturing.bypass == "<local>;*.corp")
        #expect(capturing.setupScript == "http://wpad/old.pac")
        #expect(capturing.pointsAtReqly(port: 9090))
        #expect(!capturing.pointsAtReqly(port: 9091))
        #expect(!Self.yours.pointsAtReqly(port: 9090))
        // Direct only, as Windows starts: the proxy goes on.
        #expect(ProxySettings().capturing(port: 1).flags == ProxySettings.direct | ProxySettings.usesProxy)
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
        let changed = ProxySettings(flags: ProxySettings.direct)
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

    @Test func changesNothingWhenWindowsRefuses() async throws {
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
}
