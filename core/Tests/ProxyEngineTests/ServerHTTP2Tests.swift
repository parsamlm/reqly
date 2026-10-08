import CertificateAuthority
import Foundation
import NIOHTTP1
import NIOHTTP2
import ProxyEngine
import ReqlyModel
import Testing

/// HTTP/2 between Reqly and servers that speak it: one connection to each server, a stream for
/// each request, and HTTP/1.1 where HTTP/2 can't do what the request asks.
@Suite(.timeLimit(.minutes(1))) struct ServerHTTP2Tests {
    @Test func speaksHTTP2ToServersThatDo() async throws {
        try await withDecryptingHarness(http2Origin: true) { harness in
            let response = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/version", headers: ["Host": harness.origin.authority])
            }
            #expect(response.status == 200)
            #expect(response.body == "HTTP/2.0")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.serverProtocol) == ["HTTP/2"])
            #expect(events.compactMap(\.failure).isEmpty)
            #expect(events.compactMap(\.tlsVersion) == ["1.3"])
        }
    }

    @Test func sharesOneConnectionBetweenRequests() async throws {
        try await withDecryptingHarness(http2Origin: true) { harness in
            // Requests at once, from an app's HTTP/2 connection, wait for the first one's connection.
            let multiplexer = try await harness.openSecureConnection(inside: .http2)
            let origin = harness.origin.authority
            async let hello = sendOverStream(multiplexer, .GET, "/hello", authority: origin)
            async let echo = sendOverStream(multiplexer, .POST, "/echo", authority: origin, body: "ping")
            async let version = sendOverStream(multiplexer, .GET, "/version", authority: origin)
            let (first, second, third) = try await (hello, echo, version)
            #expect(first.body == "hello")
            #expect(second.body == "ping")
            #expect(third.body == "HTTP/2.0")
            // A request after them goes over the same connection.
            let later = try await sendOverStream(multiplexer, .GET, "/hello", authority: origin)
            #expect(later.body == "hello")

            #expect(harness.origin.connectionCount == 1)
            let events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 4 }
            #expect(events.filter { $0.name == "serverConnecting" }.count == 1)
            #expect(events.filter { $0.name == "serverReused" }.count == 3)
            #expect(events.compactMap(\.serverProtocol) == Array(repeating: "HTTP/2", count: 4))
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test func passesTrailersBackToTheApp() async throws {
        try await withDecryptingHarness(http2Origin: true) { harness in
            let multiplexer = try await harness.openSecureConnection(inside: .http2)
            let response = try await sendOverStream(
                multiplexer, .POST, "/trailers", authority: harness.origin.authority,
                headers: ["te": "trailers", "content-type": "application/grpc"], body: "x")
            #expect(response.body == "ok")
            #expect(response.trailers?["grpc-status"] == ["0"])
            #expect(response.trailers?["grpc-message"] == ["fine"])
            // And records them, since a gRPC call's status is in them.
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            let trailers = try #require(events.compactMap(\.responseTrailers).first)
            #expect(GRPCStatus(fields: trailers) == GRPCStatus(code: 0, message: "fine"))
        }
    }

    @Test func letsRulesChangeResponsesOverHTTP2() async throws {
        try await withDecryptingHarness(http2Origin: true) { harness in
            harness.proxy.setRules(
                RuleSet(
                    rules: [
                        Rule(
                            name: "Shout", match: RequestMatch(path: "/hello"),
                            action: .rewrite([
                                .setHeader(.response, name: "X-Rule", value: "yes"),
                                .replaceBody(.response, find: "hello", replace: "HELLO"),
                            ]))
                    ],
                    kindsOn: [.rewrite]))
            let response = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(.GET, "/hello", headers: ["Host": harness.origin.authority])
            }
            #expect(response.body == "HELLO")
            #expect(response.headers["X-Rule"] == ["yes"])
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.serverProtocol) == ["HTTP/2"])
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test func keepsHTTP1ForRequestsThatSwitchProtocols() async throws {
        try await withDecryptingHarness(http2Origin: true) { harness in
            let response = try await harness.withSecureConnection(inside: .http1) { app in
                try await app.send(
                    .GET, "/version",
                    headers: ["Host": harness.origin.authority, "Connection": "Upgrade", "Upgrade": "websocket"])
            }
            #expect(response.body == "HTTP/1.1")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.serverProtocol) == ["HTTP/1.1"])
        }
    }

    // localhost has an IPv6 address too, where the website doesn't listen, so a connection to it
    // tries that address first, and that try fails before the one to 127.0.0.1 opens.

    @Test(arguments: [false, true])
    func sharesTheConnectionThatOpensAfterAnAddressRefuses(presentingACertificate: Bool) async throws {
        let clientRoot = try RootIdentity.create()
        try await withDecryptingHarness(
            decrypt: "localhost", http2Origin: true, clientCertificatesFrom: presentingACertificate ? clientRoot : nil,
            originCertificateHost: "localhost"
        ) { harness in
            if presentingACertificate {
                let identity = try ClientIdentity(
                    pem: try clientCertificatePEM(from: clientRoot, name: "Weatherly App"), password: nil,
                    hosts: [HostPattern(rawValue: "localhost")!])
                harness.proxy.setClientIdentities([identity])
            }
            let origin = "localhost:\(harness.origin.port)"
            let multiplexer = try await harness.openSecureConnection(inside: .http2, to: origin)
            // Requests at once wait for the first one's connection, not just for its first try.
            let bodies = try await send(6, "/hello", to: origin, over: multiplexer).map(\.body)
            #expect(bodies == Array(repeating: "hello", count: 6))
            let later = try await sendOverStream(multiplexer, .GET, "/hello", authority: origin)
            #expect(later.body == "hello")

            #expect(harness.origin.connectionCount == 1)
            let events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 7 }
            #expect(events.compactMap(\.serverAddress) == ["127.0.0.1:\(harness.origin.port)"])
            #expect(events.filter(\.isServerConnecting).count == 1)
            #expect(events.filter { $0.name == "serverReused" }.count == 6)
            #expect(events.compactMap(\.serverProtocol) == Array(repeating: "HTTP/2", count: 7))
            #expect(events.compactMap(\.failure).isEmpty)
            // Each exchange on the connection names the certificate it presented, once.
            for id in Set(events.filter(\.isResponseEnd).compactMap(\.exchange)) {
                let named = events.filter { $0.exchange == id }.compactMap(\.clientCertificate)
                #expect(named == (presentingACertificate ? ["Weatherly App"] : []))
            }
        }
    }

    @Test func waitsForAServerThatChoosesHTTP1AfterAnAddressRefuses() async throws {
        try await withDecryptingHarness(decrypt: "localhost", originCertificateHost: "localhost") { harness in
            let origin = "localhost:\(harness.origin.port)"
            let multiplexer = try await harness.openSecureConnection(inside: .http2, to: origin)
            let versions = try await send(4, "/version", to: origin, over: multiplexer).map(\.body)
            #expect(versions == Array(repeating: "HTTP/1.1", count: 4))
            // HTTP/1.1 carries one exchange at a time, so each request has a connection of its own.
            #expect(harness.origin.connectionCount == 4)
            var events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 4 }
            #expect(events.compactMap(\.failure).isEmpty)
            // The others waited until the first one's connection was up, since until the server
            // chose, it might have been HTTP/2 to share.
            let first = try #require(events.first(where: \.isServerConnecting)?.exchange)
            let connected = try #require(events.firstIndex { $0.exchange == first && $0.serverAddress != nil })
            let others = events.indices.filter { events[$0].isServerConnecting && events[$0].exchange != first }
            #expect(others.count == 3)
            #expect(others.allSatisfy { $0 > connected })

            // An app's HTTP/1.1 connection reuses the one its first request opened.
            let again = try await harness.withSecureConnection(inside: .http1, to: origin) { app in
                [
                    try await app.send(.GET, "/version", headers: ["Host": origin]),
                    try await app.send(.GET, "/version", headers: ["Host": origin]),
                ]
            }
            #expect(again.map(\.body) == ["HTTP/1.1", "HTTP/1.1"])
            #expect(harness.origin.connectionCount == 5)
            events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 6 }
            #expect(events.filter { $0.name == "serverReused" }.count == 1)
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func tellsEachWaitingRequestOnceWhenTheConnectionFails(afterConnecting: Bool) async throws {
        // Every address refuses, or the one that takes the connection has a certificate Reqly
        // doesn't trust.
        try await withDecryptingHarness(
            trustTheWebsite: false, decrypt: "localhost", http2Origin: true, originCertificateHost: "localhost"
        ) { harness in
            let origin = "localhost:\(afterConnecting ? harness.origin.port : refusingPort)"
            let multiplexer = try await harness.openSecureConnection(inside: .http2, to: origin)
            let statuses = try await send(4, "/hello", to: origin, over: multiplexer).map(\.status)
            #expect(statuses == [502, 502, 502, 502])
            let events = try await harness.log.wait { $0.compactMap(\.failure).count >= 4 }
            let exchanges = Set(events.compactMap(\.exchange))
            #expect(exchanges.count == 4)
            for id in exchanges {
                let own = events.filter { $0.exchange == id }
                // The first one tried, and each of the others tried on its own once it heard.
                #expect(own.filter(\.isServerConnecting).count == 1)
                let failures = own.compactMap(\.failure)
                #expect(failures.count == 1)
                for failure in failures {
                    switch (failure, afterConnecting) {
                    case (.cannotConnect, false), (.serverCertificateInvalid, true):
                        break
                    default:
                        Issue.record("Expected the connection's own failure, got \(failure)")
                    }
                }
            }
        }
    }

    @Test func remembersServersThatChooseHTTP1() async throws {
        try await withDecryptingHarness { harness in
            for _ in 0..<2 {
                let response = try await harness.withSecureConnection(inside: .http1) { app in
                    try await app.send(.GET, "/version", headers: ["Host": harness.origin.authority])
                }
                #expect(response.body == "HTTP/1.1")
            }
            let events = try await harness.log.wait { $0.filter(\.isResponseEnd).count == 2 }
            #expect(events.compactMap(\.serverProtocol) == ["HTTP/1.1", "HTTP/1.1"])
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }
}

/// Sends `count` requests at once, each on a stream of its own.
private func send(
    _ count: Int, _ path: String, to authority: String, over multiplexer: NIOHTTP2Handler.StreamMultiplexer
) async throws -> [TestResponse] {
    try await withThrowingTaskGroup(of: TestResponse.self) { group in
        for _ in 0..<count {
            group.addTask { try await sendOverStream(multiplexer, .GET, path, authority: authority) }
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
}
