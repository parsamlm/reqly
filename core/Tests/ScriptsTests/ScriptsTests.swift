import Foundation
import ReqlyModel
import Testing

@testable import Scripts

@Suite(.timeLimit(.minutes(1))) struct ScriptsTests {
    let runner = ScriptRunner()

    let request = ScriptRequest(
        method: "GET", url: "https://api.weatherly.dev/v1/forecast?city=amsterdam",
        headers: ["Accept": "application/json", "Cookie": "a=1", "Cookie": "b=2"], body: Data())

    let response = ScriptResponse(
        status: 200, reason: "OK", headers: ["Content-Type": "application/json"],
        body: Data(#"{"city":"Amsterdam","temperature":14.2}"#.utf8))

    @Test func changesARequest() async throws {
        let script = Script(
            code: """
                function onRequest(request) {
                  request.headers.set("Authorization", "Bearer 123");
                  request.headers.delete("cookie");
                  request.url = request.url.replace("amsterdam", "utrecht");
                  request.method = "post";
                  request.body = "hello";
                  console.log("sending", request.method, { to: request.url });
                }
                """)
        let run = await runner.run(script, on: request)
        #expect(run.error == nil)
        guard case .request(let changed) = run.outcome else {
            Issue.record("Expected a changed request, got \(run.outcome)")
            return
        }
        #expect(changed.method == "POST")
        #expect(changed.url == "https://api.weatherly.dev/v1/forecast?city=utrecht")
        #expect(
            changed.headers.fields == [
                HeaderField(name: "Accept", value: "application/json"),
                HeaderField(name: "Authorization", value: "Bearer 123"),
            ])
        #expect(changed.body == Data("hello".utf8))
        #expect(run.logs == ["sending post {\n  \"to\": \"https://api.weatherly.dev/v1/forecast?city=utrecht\"\n}"])
    }

    @Test func changesJSONInAResponse() async throws {
        let script = Script(
            code: """
                const onResponse = (response, request) => {
                  response.json.temperature = 30;
                  response.headers.set("X-From", request.method);
                  return response;
                };
                """)
        let run = await runner.run(script, on: response, to: request)
        guard case .response(let changed) = run.outcome else {
            Issue.record("Expected a changed response, got \(run.outcome)")
            return
        }
        #expect(String(decoding: changed.body, as: UTF8.self) == #"{"city":"Amsterdam","temperature":30}"#)
        #expect(changed.headers["X-From"] == "GET")
        #expect(changed.status == 200)
    }

    @Test func leavesWhatItDoesntChangeAlone() async throws {
        let looking = Script(code: "function onResponse(response) { console.log(response.status) }")
        let run = await runner.run(looking, on: response, to: request)
        #expect(run.outcome == .unchanged)
        #expect(run.logs == ["200"])
        // A script for the response has nothing to do with the request.
        let requestRun = await runner.run(looking, on: request)
        #expect(requestRun.outcome == .unchanged)
        #expect(requestRun.error == nil)
    }

    @Test func answersARequestItself() async throws {
        let script = Script(
            code: """
                function onRequest(request) {
                  if (request.url.includes("forecast")) {
                    return respond(503, JSON.stringify({ error: "down" }), { "Content-Type": "application/json" });
                  }
                }
                """)
        let run = await runner.run(script, on: request)
        guard case .answer(let answer) = run.outcome else {
            Issue.record("Expected an answer, got \(run.outcome)")
            return
        }
        #expect(answer.status == 503)
        #expect(answer.headers["Content-Type"] == "application/json")
        #expect(String(decoding: answer.body, as: UTF8.self) == #"{"error":"down"}"#)
    }

    @Test func keepsSharedStateBetweenRuns() async throws {
        let script = Script(
            code: """
                function onResponse(response) {
                  shared.count = (shared.count ?? 0) + 1;
                  response.headers.set("X-Count", String(shared.count));
                }
                """)
        let first = await runner.run(script, on: response, to: request)
        let second = await runner.run(script, on: response, to: request, shared: first.shared)
        guard case .response(let changed) = second.outcome else {
            Issue.record("Expected a changed response, got \(second.outcome)")
            return
        }
        #expect(changed.headers["X-Count"] == "2")
        #expect(second.shared == #"{"count":2}"#)
    }

    @Test func waitsForAsyncFunctions() async throws {
        let script = Script(
            code: """
                async function onRequest(request) {
                  const value = await Promise.resolve("later");
                  request.headers.set("X-When", value);
                }
                """)
        let run = await runner.run(script, on: request)
        guard case .request(let changed) = run.outcome else {
            Issue.record("Expected a changed request, got \(run.outcome) \(run.error ?? "")")
            return
        }
        #expect(changed.headers["X-When"] == "later")
    }

    @Test func saysWhereAScriptFailed() async throws {
        let failing = Script(
            code: """
                function onRequest(request) {
                  const forecast = request.json.days;
                }
                """)
        let run = await runner.run(failing, on: request)
        #expect(run.outcome == .unchanged)
        #expect(run.error?.hasPrefix("TypeError") == true)
        #expect(run.error?.hasSuffix(", on line 2.") == true)

        #expect(await runner.check("function onRequest(request) { request.") != nil)
        #expect(await runner.check("function onRequest(request) {}") == nil)
        let syntax = await runner.run(Script(code: "function onRequest( {"), on: request)
        #expect(syntax.error?.hasPrefix("SyntaxError") == true)
    }

    @Test func stopsScriptsThatRunTooLong() async throws {
        let endless = Script(code: "function onRequest(request) { while (true) {} }")
        let run = await runner.run(endless, on: request)
        #expect(run.error == "The script took longer than 1 second, so Reqly stopped it.")
        // The run's own time: on a busy machine, the test can wait much longer for its result.
        #expect(run.duration < .seconds(2))
        // The runner keeps working afterwards.
        let next = await runner.run(Script(code: "function onRequest(r) { r.method = 'PUT' }"), on: request)
        #expect(next.error == nil)
    }

    @Test func stopsDeepRecursionAndBigAllocations() async throws {
        let deep = Script(code: "function f(n) { return f(n + 1) + 1 }\nfunction onRequest() { f(0) }")
        let deepRun = await runner.run(deep, on: request)
        #expect(deepRun.error != nil)
        let greedy = Script(code: "function onRequest() { const a = []; while (true) a.push(new Array(1e6).fill(1)) }")
        let greedyRun = await runner.run(greedy, on: request)
        #expect(greedyRun.error != nil)
    }

    @Test func cantReachTheMac() async throws {
        // QuickJS's standard library isn't there, nor are the browser's network functions.
        let script = Script(
            code: """
                function onRequest(request) {
                  console.log(typeof std, typeof os, typeof fetch, typeof require, typeof XMLHttpRequest);
                }
                """)
        let run = await runner.run(script, on: request)
        #expect(run.logs == ["undefined undefined undefined undefined undefined"])
    }

    @Test func passesBinaryBodiesAsNull() async throws {
        let image = ScriptResponse(
            status: 200, reason: "OK", headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50, 0xFF, 0x00]))
        let script = Script(code: "function onResponse(response) { console.log(response.body === null) }")
        let run = await runner.run(script, on: image, to: request)
        #expect(run.logs == ["true"])
        #expect(run.outcome == .unchanged)
    }

    @Test func runsManyScriptsAtOnce() async throws {
        let script = Script(code: "function onRequest(r) { r.headers.set('X-N', String(1 + 1)) }")
        let runs = await withTaskGroup(of: ScriptRun.self) { group in
            for _ in 0..<50 {
                group.addTask { await runner.run(script, on: request) }
            }
            var runs: [ScriptRun] = []
            for await run in group {
                runs.append(run)
            }
            return runs
        }
        #expect(runs.count == 50)
        #expect(runs.allSatisfy { $0.error == nil })
    }
}
