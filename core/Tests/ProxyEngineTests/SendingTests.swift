import Foundation
import ProxyEngine
import ReqlyModel
import Testing

/// Requests Reqly sends itself, such as ones you compose. They go straight to the server and
/// are reported like an app's.
@Suite(.timeLimit(.minutes(1))) struct SendingTests {
    func closed(_ connection: ConnectionID) -> ([ProxyEvent]) -> Bool {
        { events in
            events.contains { if case .connectionClosed(connection, _) = $0 { true } else { false } }
        }
    }

    @Test func sendsARequestAndReportsIt() async throws {
        try await withHarness { harness in
            let url = try #require(URL(string: "http://localhost:\(harness.origin.port)/echo?from=composer"))
            // A Content-Length left over from an edit no longer fits the body.
            let request = OutgoingRequest(
                method: "POST", url: url,
                headers: ["Content-Length": "999", "Proxy-Connection": "Keep-Alive", "X-Test": "yes"],
                body: Data("ping".utf8))
            let ids = harness.proxy.send(request)

            let events = try await harness.log.wait(until: closed(ids.connection))
            let steps = [
                "connectionOpened", "requestHead", "requestBody", "requestEnd", "serverConnecting", "serverResolved",
                "serverConnected", "requestSent", "responseHead",
            ]
            #expect(events.map(\.name).filter(steps.contains) == steps)
            let head = try #require(events.compactMap(\.requestHead).first)
            #expect(head.target == "/echo?from=composer")
            #expect(head.headers["Host"] == "localhost:\(harness.origin.port)")
            #expect(head.headers["Content-Length"] == "4")
            #expect(head.headers["X-Test"] == "yes")
            // It goes straight to the server, so what was meant for a proxy stays out.
            #expect(head.headers["Proxy-Connection"] == nil)
            #expect(events.compactMap(\.responseHead).first?.headers["X-Method"] == "POST")
            #expect(events.compactMap(\.responseData).reduce(Data(), +) == Data("ping".utf8))
            #expect(events.contains { $0.isResponseEnd })
            // Marked as Reqly's own, right after its head.
            let marked = try #require(events.firstIndex { $0.isSentByReqly })
            #expect(events[marked - 1].requestHead != nil)
        }
    }

    @Test func explainsWhenTheServerIsUnreachable() async throws {
        try await withHarness { harness in
            let url = try #require(URL(string: "http://127.0.0.1:\(refusingPort)/"))
            let ids = harness.proxy.send(OutgoingRequest(method: "GET", url: url))
            let events = try await harness.log.wait(until: closed(ids.connection))
            guard case .cannotConnect = events.compactMap(\.failure).first else {
                Issue.record("Expected a failure to connect, got \(events.compactMap(\.failure))")
                return
            }
        }
    }

    @Test func refusesURLsItCannotSend() async throws {
        try await withHarness { harness in
            let ids = harness.proxy.send(OutgoingRequest(method: "GET", url: URL(string: "ftp://example.com/file")!))
            let events = try await harness.log.wait(until: closed(ids.connection))
            #expect(events.compactMap(\.failure) == [.invalidRequest("Reqly can send only http and https URLs.")])
            #expect(events.contains { $0.isSentByReqly })
        }
    }

    @Test func letsTheRulesActOnIt() async throws {
        try await withHarness { harness in
            let unreachable = "http://127.0.0.1:\(try await freePort())"
            harness.proxy.setRules(
                RuleSet(
                    rules: [
                        Rule(name: "No hello", match: RequestMatch(path: "/hello"), action: .block(.status(403))),
                        Rule(
                            name: "Local", match: RequestMatch(host: "127.0.0.1", path: "/echo"),
                            action: .mapRemote(MapRemote(destination: harness.originURL))),
                        Rule(
                            name: "Tag", match: RequestMatch(path: "/echo"),
                            action: .rewrite([
                                .setHeader(.response, name: "X-Tag", value: "sent"),
                                .replaceBody(.response, find: "ping", replace: "pong"),
                            ])),
                    ],
                    kindsOn: [.block, .mapRemote, .rewrite]))

            let blocked = harness.proxy.send(
                OutgoingRequest(method: "GET", url: try #require(URL(string: "\(harness.originURL)/hello"))))
            let first = try await harness.log.wait(until: closed(blocked.connection))
            #expect(first.compactMap(\.responseHead).first?.status == 403)
            #expect(first.compactMap(\.appliedRule).map(\.detail) == ["Answered with 403."])
            #expect(!first.contains { $0.isServerConnecting })

            let mapped = harness.proxy.send(
                OutgoingRequest(
                    method: "POST", url: try #require(URL(string: "\(unreachable)/echo")), body: Data("ping".utf8)))
            let events = try await harness.log.wait(until: closed(mapped.connection))
                .filter { $0.exchange == mapped.exchange }
            let response = try #require(events.compactMap(\.responseHead).last)
            #expect(response.headers["X-Tag"] == "sent")
            #expect(response.headers["Content-Length"] == "4")
            #expect(events.compactMap(\.responseData).reduce(Data(), +) == Data("pong".utf8))
            #expect(events.compactMap(\.failure).isEmpty)
            #expect(
                events.compactMap(\.appliedRule).map(\.detail) == [
                    "Sent to \(harness.originURL)/echo", "Set the X-Tag header.",
                    "Replaced “ping” in the response body once.",
                ])
        }
    }

    @Test func pausesAtABreakpoint() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                RuleSet(
                    rules: [Rule(name: "Hold", match: RequestMatch(path: "/echo"), action: .breakpoint(.both))],
                    kindsOn: [.breakpoint]))
            let ids = harness.proxy.send(
                OutgoingRequest(
                    method: "POST", url: try #require(URL(string: "\(harness.originURL)/echo")), body: Data("ping".utf8)
                ))

            let held = try await harness.log.wait { $0.contains { $0.paused != nil } }
            guard case .request(let request, let body) = try #require(held.compactMap(\.paused).first?.1) else {
                Issue.record("Expected a paused request")
                return
            }
            #expect(body == Data("ping".utf8))
            harness.proxy.decide(ids.exchange, .resume(.request(request, body: Data("edited".utf8))))

            let response = try await harness.log.wait { $0.compactMap(\.paused).count == 2 }
            guard case .response(var head, let echoed) = try #require(response.compactMap(\.paused).last?.1) else {
                Issue.record("Expected a paused response")
                return
            }
            #expect(echoed == Data("edited".utf8))
            head.status = 202
            harness.proxy.decide(ids.exchange, .resume(.response(head, body: echoed)))

            let events = try await harness.log.wait(until: closed(ids.connection))
            #expect(events.compactMap(\.responseHead).last?.status == 202)
            #expect(events.compactMap(\.failure).isEmpty)
            #expect(
                events.compactMap(\.appliedRule).map(\.detail) == [
                    "Paused the request.", "You changed the body.", "Paused the response.", "You changed the status.",
                ])
        }
    }

    @Test func cancelsAResponseAtABreakpoint() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                RuleSet(
                    rules: [Rule(name: "Hold", match: RequestMatch(path: "/hello"), action: .breakpoint(.response))],
                    kindsOn: [.breakpoint]))
            let ids = harness.proxy.send(
                OutgoingRequest(method: "GET", url: try #require(URL(string: "\(harness.originURL)/hello"))))

            let held = try await harness.log.wait { $0.contains { $0.paused != nil } }
            guard case .response = try #require(held.compactMap(\.paused).first?.1) else {
                Issue.record("Expected a paused response")
                return
            }
            harness.proxy.decide(ids.exchange, .cancel)

            let events = try await harness.log.wait { $0.contains { $0.failure != nil } }
            #expect(events.compactMap(\.failure) == [.cancelledAtBreakpoint(part: .response)])
        }
    }

    @Test func sendsOverHTTPS() async throws {
        try await withDecryptingHarness { harness in
            let url = try #require(URL(string: "https://\(harness.origin.authority)/hello"))
            let ids = harness.proxy.send(OutgoingRequest(method: "GET", url: url))
            let events = try await harness.log.wait(until: closed(ids.connection))
            #expect(events.compactMap(\.tlsVersion) == ["1.3"])
            #expect(events.compactMap(\.responseHead).first?.status == 200)
            #expect(events.compactMap(\.responseData).reduce(Data(), +) == Data("hello".utf8))
        }
    }
}
