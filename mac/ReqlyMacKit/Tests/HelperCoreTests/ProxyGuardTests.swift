import Foundation
import HelperProtocol
import Testing

@testable import HelperCore

/// Network settings kept in memory, so tests never touch the Mac's real settings.
final class FakeNetworkSettings: NetworkSettings, @unchecked Sendable {
    private let lock = NSLock()
    private var services: [String: [String: Any]]
    var failNextApply = false

    init(_ services: [String: [String: Any]]) {
        self.services = services
    }

    var current: [String: [String: Any]] {
        lock.withLock { services }
    }

    func enabledServices() throws -> [NetworkService] {
        lock.withLock { services.map { NetworkService(id: $0.key, proxies: $0.value) } }
    }

    func apply(_ proxies: [String: [String: Any]]) throws {
        try lock.withLock {
            if failNextApply {
                failNextApply = false
                throw HelperError.cannotChangeSettings
            }
            for (id, settings) in proxies where services[id] != nil {
                services[id] = settings
            }
        }
    }
}

struct FakeProcessLookup: ProcessLookup {
    var running: [Int32: String]

    func executablePath(of pid: Int32) -> String? {
        running[pid]
    }
}

func same(_ a: [String: [String: Any]], _ b: [String: [String: Any]]) -> Bool {
    NSDictionary(dictionary: a).isEqual(to: b)
}

@Suite(.timeLimit(.minutes(1))) struct ProxyGuardTests {
    let originals: [String: [String: Any]] = [
        "wifi": ["ExceptionsList": ["*.local", "169.254/16"], "HTTPEnable": 0, "SOCKSEnable": 1],
        "ethernet": [:],
    ]
    let me = getpid()
    let reqlyPath = "/Applications/Reqly.app/Contents/MacOS/Reqly"
    let stateFile = StateFile(
        url: FileManager.default.temporaryDirectory
            .appending(path: "ReqlyHelperTests-\(UUID().uuidString)/saved-proxy-settings.plist")
    )

    func makeGuard(_ settings: FakeNetworkSettings, processes: (any ProcessLookup)? = nil) -> ProxyGuard {
        ProxyGuard(
            settings: settings,
            stateFile: stateFile,
            processes: processes ?? FakeProcessLookup(running: [me: reqlyPath])
        )
    }

    @Test func pointsOnlyTheHTTPAndHTTPSProxiesAtReqly() {
        let settings = ProxySettings.capturing(originals["wifi"]!, port: 9090)
        #expect(settings["HTTPEnable"] as? Int == 1)
        #expect(settings["HTTPProxy"] as? String == "127.0.0.1")
        #expect(settings["HTTPPort"] as? Int == 9090)
        #expect(settings["HTTPSEnable"] as? Int == 1)
        #expect(settings["HTTPSProxy"] as? String == "127.0.0.1")
        #expect(settings["HTTPSPort"] as? Int == 9090)
        #expect(settings["ExceptionsList"] as? [String] == ["*.local", "169.254/16"])
        #expect(settings["SOCKSEnable"] as? Int == 1)
    }

    @Test func setsAndRestoresEveryService() throws {
        let network = FakeNetworkSettings(originals)
        let proxyGuard = makeGuard(network)

        try proxyGuard.set(port: 9090, for: me)
        #expect(network.current["wifi"]?["HTTPPort"] as? Int == 9090)
        #expect(network.current["ethernet"]?["HTTPSPort"] as? Int == 9090)
        let saved = try #require(try stateFile.load())
        #expect(same(saved.originals, originals))
        #expect(saved.appPath == reqlyPath)

        try proxyGuard.restore()
        #expect(same(network.current, originals))
        #expect(try stateFile.load() == nil)
    }

    @Test func keepsTheFirstSavedSettingsAcrossRequests() throws {
        let network = FakeNetworkSettings(originals)
        let proxyGuard = makeGuard(network)

        try proxyGuard.set(port: 9090, for: me)
        try proxyGuard.set(port: 9091, for: me)
        #expect(network.current["wifi"]?["HTTPPort"] as? Int == 9091)
        #expect(same(try #require(try stateFile.load()).originals, originals))

        try proxyGuard.restore()
        #expect(same(network.current, originals))
    }

    @Test func refusesPrivilegedPorts() throws {
        let network = FakeNetworkSettings(originals)
        #expect(throws: HelperError.invalidPort) {
            try makeGuard(network).set(port: 80, for: me)
        }
        #expect(same(network.current, originals))
        #expect(try stateFile.load() == nil)
    }

    @Test func undoesAChangeThatFailedHalfway() throws {
        let network = FakeNetworkSettings(originals)
        network.failNextApply = true
        #expect(throws: HelperError.cannotChangeSettings) {
            try makeGuard(network).set(port: 9090, for: me)
        }
        #expect(same(network.current, originals))
        #expect(try stateFile.load() == nil)
    }

    @Test func restoresALeftoverCaptureAtLaunch() throws {
        let network = FakeNetworkSettings(originals.mapValues { ProxySettings.capturing($0, port: 9090) })
        try stateFile.save(SavedState(port: 9090, appPID: 999_999, appPath: reqlyPath, originals: originals))

        makeGuard(network).recoverAtLaunch()
        #expect(same(network.current, originals))
        #expect(try stateFile.load() == nil)
    }

    @Test func keepsGuardingWhileReqlyStillRuns() throws {
        let capturing = originals.mapValues { ProxySettings.capturing($0, port: 9090) }
        let network = FakeNetworkSettings(capturing)
        try stateFile.save(SavedState(port: 9090, appPID: me, appPath: reqlyPath, originals: originals))

        let proxyGuard = makeGuard(network)
        proxyGuard.recoverAtLaunch()
        #expect(same(network.current, capturing))
        #expect(!proxyGuard.isIdle(for: 0))
        try proxyGuard.restore()
    }

    @Test func restoresWhenReqlyExits() async throws {
        let app = Process()
        app.executableURL = URL(filePath: "/bin/sleep")
        app.arguments = ["0.3"]
        try app.run()

        let network = FakeNetworkSettings(originals)
        let proxyGuard = makeGuard(network, processes: SystemProcessLookup())
        try proxyGuard.set(port: 9090, for: app.processIdentifier)
        #expect(network.current["wifi"]?["HTTPPort"] as? Int == 9090)

        let deadline = ContinuousClock.now + .seconds(10)
        while !same(network.current, originals), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(same(network.current, originals))
        #expect(try stateFile.load() == nil)
        #expect(proxyGuard.isIdle(for: -1))
    }
}
