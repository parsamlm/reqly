import Foundation
import NIOHTTP1
import ProxyEngine
import ReqlyModel
import Testing

@Suite(.timeLimit(.minutes(1))) struct ForwardingTests {
    @Test func forwardsAGetAndReportsIt() async throws {
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello?lang=en")
            }
            #expect(response.status == 200)
            #expect(response.body == "hello")

            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            let request = try #require(events.compactMap(\.requestHead).first)
            #expect(request.method == "GET")
            #expect(request.scheme == "http")
            #expect(request.host == "127.0.0.1")
            #expect(request.port == harness.origin.port)
            #expect(request.target == "/hello?lang=en")
            #expect(events.compactMap(\.responseHead).first?.status == response.status)
            // An IP address needs no lookup.
            #expect(!events.contains { $0.name == "serverResolved" })
            #expect(events.compactMap(\.serverAddress) == ["127.0.0.1:\(harness.origin.port)"])
        }
    }

    @Test func timesEachStep() async throws {
        try await withHarness { harness in
            // A name, so there's a lookup to time.
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "http://localhost:\(harness.origin.port)/hello")
            }
            #expect(response.body == "hello")

            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            let steps = [
                "requestHead", "serverConnecting", "serverResolved", "serverConnected", "requestSent", "responseHead",
                "responseEnd",
            ]
            let timed = events.filter { steps.contains($0.name) }
            #expect(timed.map(\.name) == steps)
            let times = timed.compactMap(\.time)
            #expect(times == times.sorted())
            // localhost may try ::1 first, which the website doesn't listen on.
            #expect(events.compactMap(\.serverAddress) == ["127.0.0.1:\(harness.origin.port)"])
        }
    }

    @Test func relaysBodiesBothWays() async throws {
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.POST, "\(harness.originURL)/echo", body: "ping")
            }
            #expect(response.status == 200)
            #expect(response.body == "ping")
            #expect(response.headers["X-Method"] == ["POST"])

            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.requestData) == [Data("ping".utf8)])
            #expect(events.compactMap(\.responseData).reduce(Data(), +) == Data("ping".utf8))
        }
    }

    @Test func reusesTheServerConnection() async throws {
        try await withHarness { harness in
            let bodies = try await withProxyConnection(port: harness.proxyPort) { app in
                let first = try await app.send(.GET, "\(harness.originURL)/hello")
                let second = try await app.send(.POST, "\(harness.originURL)/echo", body: "again")
                return [first.body, second.body]
            }
            #expect(bodies == ["hello", "again"])

            let events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 2 }
            #expect(events.filter(\.isServerConnecting).count == 1)
            #expect(events.compactMap(\.reusedAddress) == ["127.0.0.1:\(harness.origin.port)"])
            #expect(events.filter { $0.name == "requestSent" }.count == 2)
        }
    }

    @Test func relaysChunkedResponses() async throws {
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/chunked")
            }
            #expect(response.body == "abc")
        }
    }

    @Test func answersHeadRequestsWithoutABody() async throws {
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.HEAD, "\(harness.originURL)/hello")
            }
            #expect(response.status == 200)
            #expect(response.headers["Content-Length"] == ["5"])
            #expect(response.body.isEmpty)
        }
    }

    @Test func finishesAChunkedResponseThatEndsWithTheConnection() async throws {
        try await withHarness { harness in
            try await withProxyConnection(port: harness.proxyPort) { app in
                let response = try await app.send(
                    .GET, "\(harness.originURL)/chunked-close", headers: ["Connection": "close"])
                #expect(response.body == "bye")
            }
            _ = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            // A failure reported after the end would mark the finished exchange as failed.
            try await Task.sleep(for: .milliseconds(200))
            let events = try await harness.log.wait { _ in true }
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test func closesTheAppConnectionWhenTheServerCloses() async throws {
        try await withHarness { harness in
            try await withProxyConnection(port: harness.proxyPort) { app in
                let response = try await app.send(.GET, "\(harness.originURL)/close")
                #expect(response.body == "bye")
                await #expect(throws: TestError.self) { try await app.readResponse() }
            }
            try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
        }
    }

    @Test func explainsWhenTheServerIsUnreachable() async throws {
        let port = refusingPort
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "http://127.0.0.1:\(port)/")
            }
            #expect(response.status == 502)
            #expect(response.body.contains("refused the connection"))

            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(events.compactMap(\.failure).first == .cannotConnect("127.0.0.1 refused the connection."))
        }
    }

    @Test func refusesToLoopIntoItself() async throws {
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.POST, "http://127.0.0.1:\(harness.proxyPort)/", body: "again")
            }
            #expect(response.status == 508)
            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(events.compactMap(\.failure) == [.loopDetected])
        }
    }

    @Test func answersDirectVisitsWithTheSetupPage() async throws {
        try await withHarness { harness in
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "/", headers: ["Host": "192.168.1.125:\(harness.proxyPort)"])
            }
            #expect(response.status == 200)
            #expect(response.headers["Content-Type"] == ["text/html; charset=utf-8"])
            #expect(response.body.contains("Set up this device"))
            #expect(response.body.contains("<code>192.168.1.125</code> and port <code>\(harness.proxyPort)</code>"))
            // Without HTTPS set up, there's no certificate to offer.
            #expect(response.body.contains("first set up HTTPS"))
            #expect(response.body.contains("Capture › Decrypt HTTPS"))
            // It's Reqly's own page, not traffic.
            #expect(!harness.log.events.contains { $0.requestHead != nil })
        }
    }

    @Test func stoppingClosesOpenConnections() async throws {
        try await withHarness { harness in
            try await withProxyConnection(port: harness.proxyPort) { app in
                _ = try await app.send(.GET, "\(harness.originURL)/hello")
                await harness.proxy.stop()
                await #expect(throws: TestError.self) { try await app.readResponse() }
            }
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct TunnelTests {
    @Test func relaysBytesUntouchedAndCountsThem() async throws {
        try await withHarness { harness in
            let origin = "127.0.0.1:\(harness.origin.port)"
            let (reply, response) = try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send("CONNECT \(origin) HTTP/1.1\r\nHost: \(origin)\r\n\r\n")
                let reply = try await app.read(through: "\r\n\r\n")
                // Inside the tunnel, speak HTTP to the website directly.
                try await app.send("GET /hello HTTP/1.1\r\nHost: \(origin)\r\nConnection: close\r\n\r\n")
                return (reply, try await app.readToEnd())
            }
            #expect(reply.hasPrefix("HTTP/1.1 200"))
            #expect(response.hasPrefix("HTTP/1.1 200 OK"))
            #expect(response.hasSuffix("hello"))

            let events = try await harness.log.wait { $0.contains { $0.tunnelBytes != nil } }
            #expect(events.contains { $0.isTunnelOpened })
            let request = try #require(events.compactMap(\.requestHead).first)
            #expect(request.method == "CONNECT")
            #expect(request.target == origin)
            let bytes = try #require(events.compactMap(\.tunnelBytes).first)
            #expect(bytes.sent > 0)
            #expect(bytes.received == Int64(response.utf8.count))
        }
    }

    @Test func explainsWhenTheServerIsUnreachable() async throws {
        let port = refusingPort
        try await withHarness { harness in
            let reply = try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send("CONNECT 127.0.0.1:\(port) HTTP/1.1\r\n\r\n")
                return try await app.readToEnd()
            }
            #expect(reply.hasPrefix("HTTP/1.1 502"))
            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(events.compactMap(\.failure).first == .cannotConnect("127.0.0.1 refused the connection."))
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ServerTests {
    @Test func reportsABusyPort() async throws {
        let first = ProxyServer()
        let port = try await first.start(ProxyServer.Configuration(port: 0))
        let second = ProxyServer()
        await #expect(throws: ProxyServer.ServerError.portInUse(port)) {
            try await second.start(ProxyServer.Configuration(port: port))
        }
        await first.stop()
    }

    @Test func startsAgainAfterStopping() async throws {
        let server = ProxyServer()
        // Not a port the system picked: while it's free, another test's connection could take that.
        let port = try await freePort()
        #expect(try await server.start(ProxyServer.Configuration(port: port)) == port)
        await server.stop()
        #expect(try await server.start(ProxyServer.Configuration(port: port)) == port)
        await server.stop()
    }
}
