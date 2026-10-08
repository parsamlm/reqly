import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ReqlyModel
import Testing

@testable import ProxyEngine

/// Reverse proxies: a local port that sends every request on to one server, for apps that
/// can't use a proxy.
@Suite(.timeLimit(.minutes(1))) struct ReverseProxyTests {
    @Test func sendsEachRequestToItsServer() async throws {
        try await withHarness { harness in
            let port = try await freePort()
            let problems = await harness.proxy.setReverseProxies([
                ReverseProxy(localPort: port, serverURL: harness.originURL)
            ])
            #expect(problems.isEmpty)
            let response = try await withProxyConnection(port: port) { app in
                try await app.send(.GET, "/host", headers: ["Host": "localhost:\(port)"])
            }
            // The server hears its own name, not the reverse proxy's.
            #expect(response.body == "127.0.0.1:\(harness.origin.port)")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.reverseProxy) == ["localhost:\(port)"])
            let request = try #require(events.compactMap(\.requestHead).first)
            #expect(request.url?.absoluteString == "\(harness.originURL)/host")
            // The app is found by the port it connected to.
            let opened = events.compactMap { event -> ClientAddress? in
                if case .connectionOpened(_, let client, _) = event { client } else { nil }
            }
            #expect(opened.first?.localPort == port)
        }
    }

    @Test func pointsRedirectsBackAtItself() async throws {
        try await withHarness { harness in
            let port = try await freePort()
            await harness.proxy.setReverseProxies([ReverseProxy(localPort: port, serverURL: harness.originURL)])
            let response = try await withProxyConnection(port: port) { app in
                try await app.send(.GET, "/redirect", headers: ["Host": "localhost:\(port)"])
            }
            #expect(response.status == 302)
            #expect(response.headers["Location"] == ["http://localhost:\(port)/hello?from=redirect"])

            // Unless it's asked not to.
            await harness.proxy.setReverseProxies([
                ReverseProxy(localPort: port, serverURL: harness.originURL, rewritesRedirects: false)
            ])
            let untouched = try await withProxyConnection(port: port) { app in
                try await app.send(.GET, "/redirect", headers: ["Host": "localhost:\(port)"])
            }
            #expect(untouched.headers["Location"] == ["\(harness.originURL)/hello?from=redirect"])
        }
    }

    @Test func reachesHTTPSServers() async throws {
        try await withDecryptingHarness(http2Origin: true) { harness in
            let port = try await freePort()
            await harness.proxy.setReverseProxies([
                ReverseProxy(localPort: port, serverURL: "https://\(harness.origin.authority)")
            ])
            let response = try await withProxyConnection(port: port) { app in
                try await app.send(.GET, "/version", headers: ["Host": "localhost:\(port)"])
            }
            // Plain HTTP from the app, and HTTP/2 over TLS to the server.
            #expect(response.body == "HTTP/2.0")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.requestHead).first?.scheme == "https")
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test func saysWhyItCantListen() async throws {
        try await withHarness { harness in
            let taken = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .bind(host: "127.0.0.1", port: 0).get()
            defer { taken.close(promise: nil) }
            let takenPort = taken.localAddress!.port!
            let free = try await freePort()
            let busy = ReverseProxy(localPort: takenPort, serverURL: harness.originURL)
            let twice = ReverseProxy(localPort: free, serverURL: harness.originURL)
            let again = ReverseProxy(localPort: free, serverURL: harness.originURL)
            let ours = ReverseProxy(localPort: harness.proxyPort, serverURL: harness.originURL)
            let nowhere = ReverseProxy(localPort: try await freePort(), serverURL: "ftp://example.com")
            let off = ReverseProxy(isOn: false, localPort: takenPort, serverURL: harness.originURL)
            let problems = await harness.proxy.setReverseProxies([busy, twice, again, ours, nowhere, off])
            #expect(problems[busy.id] == .portInUse(takenPort))
            #expect(problems[twice.id] == nil)
            #expect(problems[again.id] == .portInUse(free))
            #expect(problems[ours.id] == .proxyPort(harness.proxyPort))
            #expect(problems[nowhere.id] == .invalidServer)
            #expect(problems[off.id] == nil)
        }
    }

    @Test func stopsListeningWithTheProxy() async throws {
        let port = try await freePort()
        try await withHarness { harness in
            await harness.proxy.setReverseProxies([ReverseProxy(localPort: port, serverURL: harness.originURL)])
            await harness.proxy.stop()
            await #expect(throws: (any Error).self) {
                try await withProxyConnection(port: port) { app in
                    try await app.send(.GET, "/hello")
                }
            }
            // And starts again with it.
            _ = try await harness.proxy.start(ProxyServer.Configuration(port: 0))
            let response = try await withProxyConnection(port: port) { app in
                try await app.send(.GET, "/hello", headers: ["Host": "localhost:\(port)"])
            }
            #expect(response.body == "hello")
        }
    }

    @Test func refusesToSendRequestsToItself() async throws {
        try await withHarness { harness in
            let port = try await freePort()
            await harness.proxy.setReverseProxies([ReverseProxy(localPort: port, serverURL: "http://localhost:\(port)")]
            )
            let response = try await withProxyConnection(port: port) { app in
                try await app.send(.GET, "/hello", headers: ["Host": "localhost:\(port)"])
            }
            #expect(response.status == 508)
        }
    }

    @Test func readsItsServer() {
        let server = ReverseProxy(localPort: 8080, serverURL: " https://API.weatherly.dev/v2 ").server
        #expect(server == ReverseProxy.Server("https://api.weatherly.dev"))
        #expect(server?.port == 443)
        #expect(server?.hostHeader == "api.weatherly.dev")
        #expect(ReverseProxy.Server("http://localhost:3000")?.hostHeader == "localhost:3000")
        #expect(ReverseProxy.Server("staging.weatherly.dev")?.url == "https://staging.weatherly.dev")
        #expect(ReverseProxy.Server("ftp://example.com") == nil)
        #expect(ReverseProxy(localPort: 8080, serverURL: "").server == nil)
    }
}
