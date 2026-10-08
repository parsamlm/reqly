import Capture
import Foundation
import ReqlyModel
import Testing

@Suite struct RulesFileTests {
    let url = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)/Rules.json")

    @Test func savesAndLoadsTheRules() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try RulesFile.load(from: url) == RuleSet())
        let rules = RuleSet(
            rules: [Rule(name: "No ads", match: RequestMatch(host: "*.ads.example"), action: .block(.status(403)))],
            kindsOn: [.block])
        try RulesFile.save(rules, to: url)
        #expect(try RulesFile.load(from: url) == rules)
    }

    @Test func refusesRulesFromANewerReqly() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 3, "ruleSet": {"rules": [], "future": true}}"#.utf8).write(to: url)
        #expect(throws: RulesFile.Problem.newerVersion(3)) {
            try RulesFile.load(from: url)
        }
    }

    @Test func savesScriptsAsPlainJSON() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let code = "function onRequest(request) {\n  request.headers.set(\"X-Debug\", \"1\");\n}\n"
        let rules = RuleSet(
            rules: [
                Rule(name: "Debug", match: RequestMatch(host: "api.weatherly.dev"), action: .script(Script(code: code)))
            ],
            kindsOn: [.script])
        try RulesFile.save(rules, to: url)
        #expect(try RulesFile.load(from: url) == rules)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(saved["version"] as? Int == 2)
        let rule = try #require(((saved["ruleSet"] as? [String: Any])?["rules"] as? [[String: Any]])?.first)
        #expect((rule["action"] as? [String: String]) == ["type": "script", "code": code])
    }

    @Test func readsRulesThatAnEarlierReqlySaved() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rules = RuleSet(
            rules: [Rule(name: "No ads", match: RequestMatch(host: "*.ads.example"), action: .block(.status(403)))],
            kindsOn: [.block])
        try RulesFile.save(rules, to: url)
        // As version 1 wrote it: the same, before scripts.
        let saved = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        try Data(saved.replacingOccurrences(of: #""version" : 2"#, with: #""version" : 1"#).utf8).write(to: url)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(#""version" : 1"#))
        #expect(try RulesFile.load(from: url) == rules)
    }
}
