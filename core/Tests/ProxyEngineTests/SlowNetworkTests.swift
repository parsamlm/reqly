import Foundation
import NIOHTTP1
import ProxyEngine
import ReqlyModel
import Testing

/// Slow network holding traffic back on its way to servers and back.
@Suite(.timeLimit(.minutes(1))) struct SlowNetworkTests {
    func slow(_ profile: NetworkProfile, hosts: [String] = []) -> RuleSet {
        RuleSet(kindsOn: [.slowNetwork], network: NetworkConditions(profile: profile, hosts: hosts))
    }

    func far(_ latency: Int) -> NetworkProfile {
        NetworkProfile(name: "Far", downloadBytesPerSecond: nil, uploadBytesPerSecond: nil, latency: latency)
    }

    func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Duration) {
        let start = ContinuousClock.now
        let result = try await body()
        return (result, ContinuousClock.now - start)
    }

    @Test func waitsOutTheLatency() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(slow(far(300)))
            try await withProxyConnection(port: harness.proxyPort) { app in
                // Opening the connection takes a round trip, and so does the request.
                let (first, opening) = try await timed { try await app.send(.GET, "\(harness.originURL)/hello") }
                #expect(first.body == "hello")
                #expect(opening >= .milliseconds(580))
                let (second, reusing) = try await timed { try await app.send(.GET, "\(harness.originURL)/hello") }
                #expect(second.body == "hello")
                #expect(reusing >= .milliseconds(280))
                #expect(reusing < opening)
            }
        }
    }

    @Test func limitsTheSpeed() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                slow(
                    NetworkProfile(
                        name: "Narrow", downloadBytesPerSecond: 100_000, uploadBytesPerSecond: nil, latency: 0))
            )
            let (response, elapsed) = try await timed {
                try await withProxyConnection(port: harness.proxyPort) { app in
                    try await app.send(.GET, "\(harness.originURL)/bytes?n=60000")
                }
            }
            #expect(response.body.utf8.count == 60_000)
            #expect(elapsed >= .milliseconds(450))
        }
    }

    @Test func deliversEverythingBeforeTheServerCloses() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                slow(
                    NetworkProfile(
                        name: "Narrow", downloadBytesPerSecond: 200_000, uploadBytesPerSecond: nil, latency: 50))
            )
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/bytes?n=50000&close=1")
            }
            #expect(response.body.utf8.count == 50_000)
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test func leavesOtherHostsAlone() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(slow(far(10_000), hosts: ["*.weatherly.dev"]))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.body == "hello")
            // Slowed, it would take two round trips. The engine's own times, from the request to
            // the end of the response, since a busy machine can hold the test up for seconds.
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            let started = try #require(events.first { $0.requestHead != nil }?.time)
            let ended = try #require(events.first(where: \.isResponseEnd)?.time)
            #expect(ended.timeIntervalSince(started) < 10)
        }
    }

    @Test func opensANewConnectionWhenTheNetworkChanges() async throws {
        try await withHarness { harness in
            try await withProxyConnection(port: harness.proxyPort) { app in
                _ = try await app.send(.GET, "\(harness.originURL)/hello")
                harness.proxy.setRules(slow(far(300)))
                let (_, elapsed) = try await timed { try await app.send(.GET, "\(harness.originURL)/hello") }
                #expect(elapsed >= .milliseconds(580))
            }
            let events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 2 }
            #expect(events.filter { $0.name == "serverConnecting" }.count == 2)
            #expect(!events.contains { $0.name == "serverReused" })
        }
    }

    @Test func slowsTunnels() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(slow(far(300)))
            let origin = "127.0.0.1:\(harness.origin.port)"
            try await withRawConnection(port: harness.proxyPort) { app in
                let (_, opening) = try await timed {
                    try await app.send("CONNECT \(origin) HTTP/1.1\r\nHost: \(origin)\r\n\r\n")
                    return try await app.read(through: "\r\n\r\n")
                }
                #expect(opening >= .milliseconds(290))
                let (response, asking) = try await timed {
                    try await app.send("GET /hello HTTP/1.1\r\nHost: \(origin)\r\n\r\n")
                    return try await app.read(through: "hello")
                }
                #expect(response.hasPrefix("HTTP/1.1 200"))
                #expect(asking >= .milliseconds(280))
            }
        }
    }

    @Test func closesTunnelsThatTheChangeSlowsDown() async throws {
        try await withHarness { harness in
            let origin = "127.0.0.1:\(harness.origin.port)"
            let rest = try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send("CONNECT \(origin) HTTP/1.1\r\nHost: \(origin)\r\n\r\n")
                _ = try await app.read(through: "\r\n\r\n")
                _ = try await harness.log.wait { $0.contains(where: \.isTunnelOpened) }
                // Turning slow network on for another host leaves the tunnel open.
                harness.proxy.setRules(slow(far(300), hosts: ["*.weatherly.dev"]))
                try await app.send("GET /hello HTTP/1.1\r\nHost: \(origin)\r\n\r\n")
                _ = try await app.read(through: "hello")
                harness.proxy.setRules(slow(far(300)))
                return try await app.readToEnd()
            }
            #expect(rest.isEmpty)
        }
    }
}
