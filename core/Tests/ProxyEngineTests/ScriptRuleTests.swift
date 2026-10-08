import Foundation
import NIOHTTP1
import ProxyEngine
import ReqlyModel
import Testing

/// Scripts acting on traffic as it passes through the proxy.
@Suite(.timeLimit(.minutes(1))) struct ScriptRuleTests {
    func script(_ code: String, name: String = "Script", path: String = "*") -> RuleSet {
        RuleSet(
            rules: [Rule(name: name, match: RequestMatch(path: path), action: .script(Script(code: code)))],
            kindsOn: [.script])
    }

    @Test func changesRequestsOnTheirWay() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                script(
                    """
                    function onRequest(request) {
                      request.headers.set("X-Rewritten", "by a script");
                      console.log("tagged", request.method, request.url);
                    }
                    """, name: "Tag"))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/request-header")
            }
            #expect(response.body == "by a script")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(
                events.compactMap(\.appliedRule) == [
                    AppliedRule(name: "Tag", kind: .script, detail: "Changed 1 header.")
                ])
            #expect(
                events.compactMap(\.scriptOutput) == [
                    ScriptOutput(rule: "Tag", part: .request, lines: ["tagged GET \(harness.originURL)/request-header"])
                ])
        }
    }

    @Test func changesResponsesOnTheirWay() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                script(
                    """
                    function onResponse(response, request) {
                      response.body = response.body.toUpperCase() + " from " + request.method;
                      response.status = 201;
                    }
                    """))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.status == 201)
            #expect(response.body == "HELLO from GET")
            #expect(response.headers["Content-Length"] == ["14"])
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.appliedRule).map(\.detail) == ["Changed the status to 201 and the body."])
            #expect(events.compactMap(\.responseHead).last?.reason == "Created")
        }
    }

    @Test func answersRequestsItself() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                script(
                    "function onRequest(request) { return respond(418, 'teapot', { 'Content-Type': 'text/plain' }) }"))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.status == 418)
            #expect(response.body == "teapot")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.appliedRule).map(\.detail) == ["Answered with 418."])
            // The server never saw it.
            #expect(!events.contains { $0.name == "serverConnecting" })
        }
    }

    @Test func sendsRequestsElsewhere() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                script(
                    """
                    function onRequest(request) {
                      request.url = request.url.replace("/hello", "/echo");
                      request.method = "POST";
                      request.body = JSON.stringify({ moved: true });
                    }
                    """, path: "/hello"))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.body == #"{"moved":true}"#)
            #expect(response.headers["X-Method"] == ["POST"])
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(
                events.compactMap(\.appliedRule).map(\.detail) == ["Changed the method to POST, the URL and the body."])
            // What the app asked for stays on record.
            #expect(events.compactMap(\.requestHead).first?.target == "/hello")
        }
    }

    @Test func letsRequestsGoOnWhenTheScriptFails() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                script(
                    """
                    function onRequest(request) {
                      request.headers.set("X-Rewritten", "never");
                      return request.json.days.length;
                    }
                    """))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/request-header")
            }
            // The request went on as it was.
            #expect(response.body == "missing")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            let detail = try #require(events.compactMap(\.appliedRule).first?.detail)
            #expect(detail.hasPrefix("Failed: TypeError"))
            #expect(detail.hasSuffix("on line 3. The request went on as it was."))
        }
    }

    @Test func stopsAScriptThatRunsTooLong() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(script("function onResponse(response) { while (true) {} }"))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.body == "hello")
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(
                events.compactMap(\.appliedRule).map(\.detail) == [
                    "Failed: The script took longer than 1 second, so Reqly stopped it. The response went on as it was."
                ])
        }
    }

    @Test func keepsSharedStateFromOneExchangeToTheNext() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                script(
                    """
                    function onResponse(response) {
                      shared.seen = (shared.seen ?? 0) + 1;
                      response.body = `seen ${shared.seen}`;
                    }
                    """))
            let bodies = try await withProxyConnection(port: harness.proxyPort) { app in
                [
                    try await app.send(.GET, "\(harness.originURL)/hello").body,
                    try await app.send(.GET, "\(harness.originURL)/hello").body,
                ]
            }
            #expect(bodies == ["seen 1", "seen 2"])
        }
    }

    @Test func runsInTheOrderTheyreListed() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                RuleSet(
                    rules: [
                        Rule(
                            name: "First", match: RequestMatch(),
                            action: .script(Script(code: "function onResponse(r) { r.body += ' one' }"))),
                        Rule(
                            name: "Off", isOn: false, match: RequestMatch(),
                            action: .script(Script(code: "function onResponse(r) { r.body += ' never' }"))),
                        Rule(
                            name: "Second", match: RequestMatch(),
                            action: .script(Script(code: "function onResponse(r) { r.body += ' two' }"))),
                    ], kindsOn: [.script]))
            let response = try await withProxyConnection(port: harness.proxyPort) { app in
                try await app.send(.GET, "\(harness.originURL)/hello")
            }
            #expect(response.body == "hello one two")
        }
    }

    @Test func runsOnDecryptedHTTP2() async throws {
        try await withDecryptingHarness(http2Origin: true) { harness in
            harness.proxy.setRules(
                script(
                    """
                    function onRequest(request) { request.headers.set("X-Rewritten", "over h2") }
                    function onResponse(response) { response.headers.set("X-Script", "yes") }
                    """))
            let multiplexer = try await harness.openSecureConnection(inside: .http2)
            let response = try await sendOverStream(
                multiplexer, .GET, "/request-header", authority: harness.origin.authority)
            #expect(response.body == "over h2")
            #expect(response.headers["X-Script"] == ["yes"])
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            #expect(events.compactMap(\.failure).isEmpty)
        }
    }

    @Test func runsOnRequestsReqlySends() async throws {
        try await withHarness { harness in
            harness.proxy.setRules(
                script(
                    """
                    function onRequest(request) { request.headers.set("X-Rewritten", "composed") }
                    function onResponse(response) { response.body = "[" + response.body + "]" }
                    """))
            _ = harness.proxy.send(
                OutgoingRequest(method: "GET", url: URL(string: "\(harness.originURL)/request-header")!))
            let events = try await harness.log.wait { $0.contains(where: \.isResponseEnd) }
            let body = events.compactMap(\.responseData).reduce(Data(), +)
            #expect(String(decoding: body, as: UTF8.self) == "[composed]")
        }
    }
}
