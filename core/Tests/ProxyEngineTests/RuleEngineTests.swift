import Foundation
import NIOHTTP1
import ProxyEngine
import ReqlyModel
import Testing

/// Rules acting on traffic as it passes through the proxy.
@Suite(.timeLimit(.minutes(1))) struct RuleEngineTests {
    func rules(_ rules: Rule..., kinds: Set<RuleKind>? = nil) -> RuleSet {
        RuleSet(rules: rules, kindsOn: kinds ?? Set(rules.map(\.kind)))
    }

    @Test func blocksWithAStatus() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(Rule(name: "No hello", match: RequestMatch(path: "/hello"), action: .block(.status(403)))))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.status == 403)
            #expect(response.body.contains("No hello"))
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.appliedRule).map(\.detail) == ["Answered with 403."])
            // The server never saw it.
            #expect(!events.contains { $0.name == "serverConnecting" })
        }
    }

    @Test func blocksBeforeMapLocal() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(
                    Rule(name: "Sunny", match: RequestMatch(), action: .mapLocal(MapLocal(path: "/nonexistent.json"))),
                    Rule(name: "No hello", match: RequestMatch(path: "/hello"), action: .block(.status(403)))))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.status == 403)
        }
    }

    @Test func blocksByClosingTheConnection() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(Rule(name: "Offline", match: RequestMatch(), action: .block(.closeConnection))))
            await #expect(throws: (any Error).self) {
                try await withProxyConnection(port: harness.proxyPort) { app in
                    try await app.send(.GET, "\(harness.originURL)/hello")
                }
            }
            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(events.compactMap(\.failure) == [.blocked(rule: "Offline")])
        }
    }

    @Test func blocksTunnelsToAHost() async throws {
        try await withHarness { harness in
            let origin = "127.0.0.1:\(harness.origin.port)"
            harness.proxy.setRules(
                rules(
                    // Paths can't be seen in a tunnel that isn't decrypted, so this one passes.
                    Rule(
                        name: "No ads", match: RequestMatch(host: "127.0.0.1", path: "/ads/*"),
                        action: .block(.status(404))),
                    Rule(name: "No local", match: RequestMatch(host: "127.0.0.1"), action: .block(.status(403)))))
            let reply = try await withRawConnection(port: harness.proxyPort) { app in
                try await app.send("CONNECT \(origin) HTTP/1.1\r\nHost: \(origin)\r\n\r\n")
                return try await app.readToEnd()
            }
            #expect(reply.hasPrefix("HTTP/1.1 403"))
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.appliedRule).map(\.name) == ["No local"])
            #expect(!events.contains { $0.isServerConnecting })
        }
    }

    @Test func answersWithALocalFile() async throws {
        let file = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString).json")
        try Data(#"{"forecast":"sunny"}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(
                    Rule(
                        name: "Sunny", match: RequestMatch(path: "/v2/forecast"),
                        action: .mapLocal(MapLocal(path: file.path(percentEncoded: false))))))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/v2/forecast?city=amsterdam")
            }
            #expect(response.status == 200)
            #expect(response.body == #"{"forecast":"sunny"}"#)
            #expect(response.headers["Content-Type"] == ["application/json"])
        }
    }

    @Test func sendsRequestsToAnotherServer() async throws {
        try await withHarness { harness in
            let unreachable = "http://127.0.0.1:\(try await freePort())"
            harness.proxy.setRules(
                rules(
                    Rule(
                        name: "Local", match: RequestMatch(host: "127.0.0.1"),
                        action: .mapRemote(MapRemote(destination: harness.originURL)))))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(unreachable)/hello")
            }
            #expect(response.body == "hello")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.appliedRule).map(\.detail) == ["Sent to \(harness.originURL)/hello"])
            // What the app asked for stays on record.
            #expect(events.compactMap(\.requestHead).first?.port != harness.origin.port)
        }
    }

    @Test func rewritesRequestsAndResponses() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(
                    Rule(
                        name: "Tag", match: RequestMatch(path: "/request-header"),
                        action: .rewrite([.setHeader(.request, name: "X-Rewritten", value: "yes")])),
                    Rule(
                        name: "Howdy", match: RequestMatch(path: "/hello"),
                        action: .rewrite([
                            .setStatus(203), .setHeader(.response, name: "Cache-Control", value: "no-store"),
                            .replaceBody(.response, find: "hello", replace: "howdy"),
                        ]))))
            let (tagged, howdy) = try await withProxyConnection(port: harness.proxyPort) { app in
                (
                    try await app.send(.GET, "\(harness.originURL)/request-header"),
                    try await app.send(.GET, "\(harness.originURL)/hello")
                )
            }
            #expect(tagged.body == "yes")
            #expect(howdy.status == 203)
            #expect(howdy.headers["Cache-Control"] == ["no-store"])
            #expect(howdy.body == "howdy")
            #expect(howdy.headers["Content-Length"] == ["5"])
        }
    }

    @Test func pausesARequestForYouToEdit() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(Rule(name: "Hold", match: RequestMatch(path: "/hello"), action: .breakpoint(.request))))
            async let response = withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            let events = try await harness.log.wait { $0.contains { $0.paused != nil } }
            let (exchange, message) = try #require(events.compactMap(\.paused).first)
            guard case .request(var request, _) = message else {
                Issue.record("Expected a paused request")
                return
            }
            request.target = "/echo"
            request.method = "POST"
            harness.proxy.decide(exchange, .resume(.request(request, body: Data("edited".utf8))))
            #expect(try await response.body == "edited")
            #expect(try await response.headers["X-Method"] == ["POST"])
            let later = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(
                later.compactMap(\.appliedRule).map(\.detail) == [
                    "Paused the request.", "You changed the method, the URL and the body.",
                ])
        }
    }

    @Test func pausesAResponseForYouToEdit() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(Rule(name: "Hold", match: RequestMatch(path: "/hello"), action: .breakpoint(.response))))
            async let response = withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            let events = try await harness.log.wait { $0.contains { $0.paused != nil } }
            let (exchange, message) = try #require(events.compactMap(\.paused).first)
            guard case .response(var head, let body) = message else {
                Issue.record("Expected a paused response")
                return
            }
            #expect(body == Data("hello".utf8))
            head.status = 202
            head.reason = "Accepted"
            harness.proxy.decide(exchange, .resume(.response(head, body: Data("changed at a breakpoint".utf8))))
            #expect(try await response.status == 202)
            #expect(try await response.body == "changed at a breakpoint")
            let later = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(
                later.compactMap(\.appliedRule).map(\.detail) == [
                    "Paused the response.", "You changed the status and the body.",
                ])
        }
    }

    @Test func cancelsARequestAtABreakpoint() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(Rule(name: "Hold", match: RequestMatch(), action: .breakpoint(.request))))
            async let response = withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            let events = try await harness.log.wait { $0.contains { $0.paused != nil } }
            let (exchange, _) = try #require(events.compactMap(\.paused).first)
            harness.proxy.decide(exchange, .cancel)
            #expect(try await response.status == 502)
            #expect(try await response.body == "You cancelled this request at a breakpoint.\n")
            let later = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(later.compactMap(\.failure) == [.cancelledAtBreakpoint(part: .request)])
        }
    }

    @Test func cancelsAResponseAtABreakpoint() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(Rule(name: "Hold", match: RequestMatch(), action: .breakpoint(.response))))
            async let response = withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            let events = try await harness.log.wait { $0.contains { $0.paused != nil } }
            let (exchange, _) = try #require(events.compactMap(\.paused).first)
            harness.proxy.decide(exchange, .cancel)
            #expect(try await response.status == 502)
            #expect(try await response.body == "You cancelled this response at a breakpoint.\n")
            let later = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(later.compactMap(\.failure) == [.cancelledAtBreakpoint(part: .response)])
        }
    }

    @Test func leavesTrafficAloneWhenTheKindIsOff() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                rules(Rule(name: "No hello", match: RequestMatch(), action: .block(.status(403))), kinds: []))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.body == "hello")
        }
    }
}
