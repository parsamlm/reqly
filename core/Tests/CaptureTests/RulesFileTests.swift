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

@Suite struct RulesFileOpeningTests {
    let url = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)/Rules.json")
    var kept: URL { url.deletingLastPathComponent().appending(path: "Rules (unreadable).json") }

    @Test func opensNothingSavedAsNoRules() {
        let opened = RulesFile.open(url)
        #expect(opened.rules == RuleSet() && !opened.isReadOnly && opened.problem == nil)
    }

    @Test func movesAnUnreadableFileAsideAndStartsOver() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not the rules".utf8).write(to: url)
        let opened = RulesFile.open(url)
        #expect(opened.rules == RuleSet() && !opened.isReadOnly)
        #expect(
            opened.problem
                == "Reqly couldn't read its saved rules, so it moved them to “Rules (unreadable).json” "
                + "and started over.")
        #expect(String(decoding: try Data(contentsOf: kept), as: UTF8.self) == "not the rules")
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func leavesANewerReqlysRulesAsTheyAre() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"version": 3, "ruleSet": {"rules": []}}"#.utf8)
        try newer.write(to: url)
        let opened = RulesFile.open(url)
        #expect(opened.rules == RuleSet() && opened.isReadOnly)
        #expect(
            opened.problem
                == "A newer version of Reqly saved the rules, so this one can't use them. Changes you make here aren't saved."
        )
        #expect(try Data(contentsOf: url) == newer)
    }
}

@Suite struct ConnectionsFileTests {
    let url = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)/Connections.json")

    @Test func savesTheSettingsWithoutThePassword() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(ConnectionsFile.load(from: url).contents == ConnectionsFile.Contents())
        #expect(ConnectionsFile.load(from: url).problem == nil)
        let proxy = UpstreamProxy(
            host: "proxy.example.com", port: 8080, username: "parsa", password: "hunter2",
            bypass: [HostPattern(rawValue: "*.corp.example.com")!])
        let certificate = ClientCertificate(
            hosts: [HostPattern(rawValue: "api.bank.dev")!], name: "Bank", issuer: "Bank CA",
            expires: Date(timeIntervalSince1970: 2_000_000_000))
        let contents = ConnectionsFile.Contents(
            upstreamProxy: proxy, usesUpstreamProxy: true,
            reverseProxies: [ReverseProxy(localPort: 8080, serverURL: "https://api.weatherly.dev")],
            clientCertificates: [certificate])
        try ConnectionsFile.save(contents, to: url)
        let saved = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!saved.contains("hunter2") && saved.contains(#""version" : 1"#))
        var loaded = ConnectionsFile.load(from: url).contents
        #expect(loaded.upstreamProxy?.password == nil)
        loaded.upstreamProxy?.password = "hunter2"
        #expect(loaded == contents)
    }

    @Test func startsWithoutSettingsItCantRead() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 1, "reverseProxies": [{"oops": true}]}"#.utf8).write(to: url)
        let loaded = ConnectionsFile.load(from: url)
        #expect(loaded.contents == ConnectionsFile.Contents())
        #expect(loaded.problem == "Reqly couldn't read its connection settings, so it started without them.")
    }
}
