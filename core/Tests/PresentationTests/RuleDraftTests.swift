import Foundation
import Presentation
import ReqlyModel
import Testing

@Suite struct RuleDraftTests {
    /// A request to a port of its own, or an encrypted connection to one.
    static func local(_ kind: ExchangeKind = .http, id: UInt64 = 9, target: String = "/v2/forecast?days=3")
        -> ExchangeSummary
    {
        Exchange(
            id: ExchangeID(rawValue: id), connectionID: ConnectionID(rawValue: 1), kind: kind,
            request: RequestHead(
                method: kind == .tunnel ? "CONNECT" : "PUT", scheme: "http", host: "localhost", port: 9096,
                target: kind == .tunnel ? "localhost:9096" : target),
            started: Traffic.start
        ).summary
    }

    @Test func fillsANewRuleInFromARequest() {
        let draft = RuleDraft(kind: .mapRemote, from: Traffic.summary(4, target: "/v2/forecast?days=3", method: "POST"))
        #expect(draft.isNew && draft.exchange == ExchangeID(rawValue: 4))
        #expect(draft.host == "api.weatherly.dev" && draft.path == "/v2/forecast" && draft.method == "POST")
        #expect(draft.destination == "https://api.weatherly.dev")
        #expect(draft.defaultName == "api.weatherly.dev/v2/forecast")

        let local = RuleDraft(kind: .mapRemote, from: Self.local())
        #expect(local.host == "localhost:9096" && local.destination == "http://localhost:9096")
        // An encrypted connection shows no path or method, so its rule is for the whole host.
        let tunnel = RuleDraft(kind: .block, from: Self.local(.tunnel))
        #expect(tunnel.host == "localhost:9096" && tunnel.path.isEmpty && tunnel.method.isEmpty)
        #expect(tunnel.match == RequestMatch(host: "localhost:9096"))

        let blank = RuleDraft(kind: .rewrite, from: nil)
        #expect(blank.exchange == nil && blank.changes.count == 1)
        #expect(blank.problem == "Enter the header's name.")
        #expect(RuleDraft(kind: .script, from: nil).code == ScriptExamples.starter)
    }

    @Test func namesARuleAfterWhatItMatches() {
        var draft = RuleDraft(kind: .breakpoint, from: nil)
        #expect(draft.defaultName == "Any host")
        draft.path = " v2 "
        #expect(draft.defaultName == "Any host/v2")
        draft.host = "api.weatherly.dev"
        draft.path = "/v2/*"
        #expect(draft.defaultName == "api.weatherly.dev/v2/*")
        #expect(draft.rule?.name == "api.weatherly.dev/v2/*")
        draft.name = "  Hold the forecast  "
        #expect(draft.rule?.name == "Hold the forecast")
    }

    @Test func saysWhatToFixFirst() {
        var local = RuleDraft(kind: .mapLocal, from: nil)
        #expect(local.problem == "Choose a file to answer with.")
        local.file = "C:\\Responses\\forecast.json"
        local.status = 99
        #expect(local.problem == "Enter a status from 100 to 599.")
        local.status = 200
        #expect(local.problem == nil)

        var block = RuleDraft(kind: .block, from: nil)
        block.blockStatus = 700
        #expect(block.problem == "Enter a status from 100 to 599.")
        block.closesConnection = true
        #expect(block.problem == nil)

        var remote = RuleDraft(kind: .mapRemote, from: nil)
        for destination in ["", "staging.weatherly.dev", "ftp://staging.weatherly.dev", "https://"] {
            remote.destination = destination
            #expect(remote.problem == "Enter a URL that starts with http:// or https://.")
        }
        remote.destination = " HTTPS://staging.weatherly.dev "
        #expect(remote.problem == nil)

        var rewrite = RuleDraft(kind: .rewrite, from: nil)
        rewrite.changes = []
        #expect(rewrite.problem == "Add a change.")
        var change = RewriteDraft()
        change.change = .replaceBody
        rewrite.changes = [change]
        #expect(rewrite.problem == "Enter the body text to replace.")
        // Body text is replaced exactly as written, so a space is something to replace.
        rewrite.changes[0].name = " "
        #expect(rewrite.problem == nil)
        change.change = .setQueryParameter
        change.name = "  "
        rewrite.changes.append(change)
        #expect(rewrite.problem == "Enter the query parameter's name.")
        rewrite.changes[1].change = .setStatus
        rewrite.changes[1].status = 42
        #expect(rewrite.problem == "Enter a status from 100 to 599.")

        var script = RuleDraft(kind: .script, from: nil)
        script.code = "// Nothing to run yet."
        #expect(script.problem == "Write an onRequest or onResponse function.")
        #expect(RuleDraft(kind: .breakpoint, from: nil).problem == nil)
    }

    @Test func savesWhatYouWroteAsARule() throws {
        var draft = RuleDraft(kind: .mapLocal, from: nil)
        draft.host = " api.weatherly.dev "
        draft.file = " ~/Responses/forecast.json "
        draft.contentType = "  "
        let rule = try #require(draft.rule)
        #expect(rule.match == RequestMatch(host: "api.weatherly.dev", path: "*", method: nil))
        #expect(rule.action == .mapLocal(MapLocal(path: "~/Responses/forecast.json", status: 200, contentType: nil)))
        #expect(rule.id == draft.id && rule.isOn)

        let saved = [
            Rule(
                name: "Hold", match: RequestMatch(host: "*.weatherly.dev", method: "POST"),
                action: .breakpoint(.response)),
            Rule(
                name: "Local", isOn: false, match: RequestMatch(path: "/v2/*"),
                action: .mapLocal(MapLocal(path: "C:\\forecast.json", status: 503, contentType: "application/json"))),
            Rule(
                name: "Staging", match: RequestMatch(),
                action: .mapRemote(MapRemote(destination: "https://staging.dev"))),
            Rule(
                name: "Rewrite", match: RequestMatch(),
                action: .rewrite([
                    .setHeader(.response, name: "X-Debug", value: " 1 "), .removeHeader(.request, name: "Cookie"),
                    .setQueryParameter(name: "days", value: "3"), .removeQueryParameter(name: "debug"),
                    .replaceBody(.response, find: " light", replace: "strong"), .setStatus(418),
                ])),
            Rule(name: "Close", match: RequestMatch(host: "ads.example"), action: .block(.closeConnection)),
            Rule(name: "Forbid", match: RequestMatch(host: "ads.example"), action: .block(.status(451))),
            Rule(name: "Script", match: RequestMatch(), action: .script(Script(code: ScriptExamples.all[0].code))),
        ]
        for rule in saved {
            #expect(RuleDraft(rule: rule).rule == rule)
        }
    }

    @Test func countsTheRequestsARuleMatches() {
        let summaries = [
            Traffic.summary(1), Traffic.summary(2, target: "/v2/cities"), Traffic.summary(3),
            Self.local(.tunnel, id: 4), Self.local(id: 5),
        ]
        var draft = RuleDraft(kind: .mapLocal, from: nil)
        draft.path = "/v2/forecast"
        #expect(draft.matchCount(in: summaries) == 3)
        draft.host = "localhost:*"
        draft.path = ""
        #expect(draft.matchCount(in: summaries) == 1)
        // Only a Block rule for a whole host acts on an encrypted connection.
        let block = RuleDraft(kind: .block, from: Self.local(.tunnel))
        #expect(block.matchCount(in: summaries) == 2)

        var script = RuleDraft(kind: .script, from: nil)
        script.host = "api.weatherly.dev"
        #expect(script.matchingRequests(in: summaries).map(\.id.rawValue) == [3, 2, 1])
        #expect(script.matchingRequests(in: summaries, limit: 2).map(\.id.rawValue) == [3, 2])
        #expect(RuleDraft.describe(Traffic.summary(1, status: 404)) == "GET api.weatherly.dev/v2/forecast · 404")
        #expect(RuleDraft.describe(Self.local()) == "PUT localhost:9096/v2/forecast?days=3")
        let long = RuleDraft.describe(Traffic.summary(1, target: "/" + String(repeating: "a", count: 80), status: nil))
        #expect(long == "GET api.weatherly.dev/" + String(repeating: "a", count: 53) + "…")
    }

    @Test func tagsEachRuleWithWhatItDoes() {
        func tag(_ action: RuleAction) -> String {
            Rule(name: "", match: RequestMatch(), action: action).tag
        }
        #expect(tag(.breakpoint(.request)) == "Request" && tag(.breakpoint(.both)) == "Both")
        #expect(tag(.mapLocal(MapLocal(path: "~/Responses/forecast.json"))) == "forecast.json")
        #expect(tag(.mapLocal(MapLocal(path: "C:\\Users\\parsa\\cities.json"))) == "cities.json")
        #expect(tag(.mapRemote(MapRemote(destination: "https://staging.weatherly.dev/v2"))) == "staging.weatherly.dev")
        #expect(tag(.rewrite([.setStatus(500)])) == "1 change")
        #expect(tag(.rewrite([.setStatus(500), .removeQueryParameter(name: "a")])) == "2 changes")
        #expect(tag(.block(.status(403))) == "403" && tag(.block(.closeConnection)) == "Close")
        #expect(tag(.script(Script(code: "function onResponse(response) {}"))) == "Response")
        #expect(tag(.script(Script(code: ScriptExamples.starter))) == "Both")
        #expect(tag(.script(Script(code: "// nothing"))) == "Nothing")
    }
}
