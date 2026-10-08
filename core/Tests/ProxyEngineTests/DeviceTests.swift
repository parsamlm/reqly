import CertificateAuthority
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ReqlyModel
import Synchronization
import Testing

@testable import ProxyEngine

/// Phones and tablets on the network: let in only once they're allowed, and offered Reqly's
/// setup page. The tests count connections from this Mac as a device's, so nothing listens on
/// the network.
@Suite(.timeLimit(.minutes(1))) struct DeviceTests {
    @Test func turnsDevicesAwayWhenNothingCanAllowThem() async throws {
        try await withHarness { harness in
            harness.proxy.treatLoopbackAsDevices(true)
            await #expect(throws: (any Error).self) {
                try await withProxyConnection(port: harness.proxyPort) { app in
                    try await app.send(.GET, "\(harness.originURL)/hello")
                }
            }
            // A device that isn't let in leaves no trace in the traffic.
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.log.events.isEmpty)
        }
    }

    @Test func waitsForTheDecision() async throws {
        try await withHarness { harness in
            harness.proxy.treatLoopbackAsDevices(true)
            let (decisions, decide) = AsyncStream.makeStream(of: Bool.self)
            let asked = Mutex<[ClientAddress]>([])
            harness.proxy.setDeviceAdmission { client in
                asked.withLock { $0.append(client) }
                for await decision in decisions {
                    return decision
                }
                return false
            }
            async let response = withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            // Nothing is read while the decision waits. How soon it's asked depends on how busy
            // the machine is, so the test waits for that rather than for a set time.
            try await waitUntil { asked.withLock { !$0.isEmpty } }
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.log.events.isEmpty)
            #expect(asked.withLock { $0.map(\.ip) } == ["127.0.0.1"])
            decide.yield(true)
            #expect(try await response.body == "hello")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.first?.name == "connectionOpened")
        }
    }

    /// A device that's let in at once gets in, even though NIO sets its connection up on one
    /// event loop and makes it active from another, and busy loops hold that up. Asked any
    /// sooner, the answer would find the connection not yet active.
    @Test func letsInADeviceAllowedAtOnce() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let isBusy = Mutex(true)
        // Busy for 2 ms at a time. A scheduled task, unlike an immediate one, lets the loop
        // handle its connections in between.
        @Sendable func keepBusy(_ loop: any EventLoop) {
            loop.scheduleTask(in: .microseconds(100)) {
                let end = ContinuousClock.now + .milliseconds(2)
                while ContinuousClock.now < end {}
                if isBusy.withLock({ $0 }) {
                    keepBusy(loop)
                }
            }
        }
        for loop in group.makeIterator() {
            keepBusy(loop)
        }
        do {
            try await withHarness(group: group) { harness in
                harness.proxy.treatLoopbackAsDevices(true)
                harness.proxy.setDeviceAdmission { _ in true }
                // Connections take turns between the two loops, so half of them are set up on
                // the loop that didn't accept them.
                for _ in 0..<10 {
                    let response = try await withProxyConnection(port: harness.proxyPort) { app in
                        try await app.send(.GET, "\(harness.originURL)/hello")
                    }
                    #expect(response.body == "hello")
                }
            }
        } catch {
            isBusy.withLock { $0 = false }
            try await group.shutdownGracefully()
            throw error
        }
        isBusy.withLock { $0 = false }
        try await group.shutdownGracefully()
    }

    @Test func closesTheConnectionsOfDevicesThatArentAllowed() async throws {
        try await withHarness { harness in
            harness.proxy.treatLoopbackAsDevices(true)
            harness.proxy.setDeviceAdmission { _ in false }
            await #expect(throws: (any Error).self) {
                try await withProxyConnection(port: harness.proxyPort) { app in
                    try await app.send(.GET, "\(harness.originURL)/hello")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.log.events.isEmpty)
        }
    }

    @Test func offersReqlysCertificate() async throws {
        try await withDecryptingHarness { harness in
            let (page, certificate) = try await withProxyConnection(port: harness.proxyPort) { app in
                let page = try await app.send(
                    .GET, "/", headers: ["Host": "192.168.1.125:9090", "User-Agent": "Mozilla/5.0 (Linux; Android 16)"])
                let certificate = try await app.send(.GET, "/reqly-ca.crt", headers: ["Host": "192.168.1.125:9090"])
                return (page, certificate)
            }
            #expect(page.body.contains(#"href="/reqly-ca.crt""#))
            #expect(page.body.contains(harness.reqlyRoot.name))
            // An Android device gets its own steps first.
            let android = try #require(page.body.range(of: "<h2>Android</h2>"))
            let iPhone = try #require(page.body.range(of: "<h2>iPhone and iPad</h2>"))
            #expect(android.lowerBound < iPhone.lowerBound)

            #expect(certificate.status == 200)
            #expect(certificate.headers["Content-Type"] == ["application/x-x509-ca-cert"])
            #expect(certificate.data == Data(try harness.reqlyRoot.certificateDER))
        }
    }

    @Test func servesTheSetupPageThroughTheProxyToo() async throws {
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "http://127.0.0.1:\(harness.proxyPort)/")
            }
            #expect(response.status == 200)
            #expect(response.body.contains("Set up this device"))
            #expect(!harness.log.events.contains { $0.requestHead != nil })
        }
    }

    @Test func keepsWhatTheHostHeaderSaysOutOfThePage() async throws {
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "/", headers: ["Host": "<script>alert(1)</script>"])
            }
            #expect(!response.body.contains("<script>"))
            #expect(response.body.contains("this Mac's address"))
        }
    }

    @Test func knowsTheMacsOwnAddresses() throws {
        let engine = EngineContext(continuation: AsyncStream.makeStream(of: ProxyEvent.self).continuation)
        engine.listenPort = 9090
        #expect(engine.isLoop(Authority(host: "127.0.0.1", port: 9090)))
        #expect(!engine.isLoop(Authority(host: "127.0.0.1", port: 9091)))
        #expect(!engine.isLoop(Authority(host: "203.0.113.24", port: 9090)))
        // A request to the Mac's address on a network, on Reqly's port, would come back to Reqly.
        let networkAddresses = try System.enumerateDevices().compactMap { $0.address?.ipAddress }
            .filter { !ClientAddress(ip: $0, port: 0).isLoopback }
        for address in networkAddresses {
            #expect(engine.isLoop(Authority(host: address, port: 9090)))
        }
    }
}
